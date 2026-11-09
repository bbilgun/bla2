// GroupDetailController: paging the expenses, refresh ordering, members and invites.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:netzero/app/strings.dart';
import 'package:netzero/controllers/group_detail_controller.dart';
import 'package:netzero/models/models.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeGroups groups;
  late FakeExpenses expenses;
  late GroupDetailController controller;

  setUp(() {
    Get.testMode = true;
    recordNotifications();
    groups = FakeGroups();
    // Seven expenses served two to a page.
    expenses = FakeExpenses([for (var i = 1; i <= 7; i++) expenseOf('e$i')]);
    controller = GroupDetailController('g1', groups, expenses, myUserId: () => 'a');
  });

  List<String> ids() => controller.expenses.map((expense) => expense.id).toList();

  group('paging', () {
    test('loads the first page, then the next pages in order, then stops', () async {
      await controller.load();

      expect(ids(), ['e1', 'e2']);
      expect(controller.hasMore, isTrue);
      expect(controller.shouldAutoLoad, isTrue);

      await controller.loadMore();
      await controller.loadMore();
      await controller.loadMore();

      expect(ids(), ['e1', 'e2', 'e3', 'e4', 'e5', 'e6', 'e7']);
      expect(controller.hasMore, isFalse);
      expect(controller.shouldAutoLoad, isFalse);
      expect(expenses.listCalls, [null, 'e2', 'e4', 'e6']);
    });

    test('stops auto-loading after a failed page until "load more" is tapped', () async {
      await controller.load();
      expenses.failNextPage = networkError();

      await controller.loadMore();

      expect(ids(), ['e1', 'e2']);
      expect(controller.loadMoreFailed, isTrue);
      // The button stays, but the list doesn't fetch on its own.
      expect(controller.hasMore, isTrue);
      expect(controller.shouldAutoLoad, isFalse);
      expect(shown.single, startsWith(S.couldNotLoadMore));

      // The user taps the button.
      await controller.loadMore();

      expect(ids(), ['e1', 'e2', 'e3', 'e4']);
      expect(controller.loadMoreFailed, isFalse);
      expect(controller.shouldAutoLoad, isTrue);
    });

    test('ignores "load more" while one is in flight', () async {
      await controller.load();
      expenses.gate = Completer<void>();

      final first = controller.loadMore();
      await controller.loadMore();
      expenses.gate!.complete();
      await first;

      expect(expenses.listCalls, [null, 'e2']);
      expect(ids(), ['e1', 'e2', 'e3', 'e4']);
    });

    test('a refresh after a write discards a "load more" still in flight', () async {
      await controller.load();
      final gate = expenses.gate = Completer<void>();
      // Page 2 of the old list, held until the gate opens.
      final stalePage = controller.loadMore();
      expenses.gate = null;

      // Someone adds an expense.
      expenses.all = [expenseOf('new'), ...expenses.all];
      await controller.refreshAfterWrite();

      expect(ids(), ['new', 'e1']);

      gate.complete();
      await stalePage;

      // The old page 2 (e3, e4) was not appended.
      expect(ids(), ['new', 'e1']);
      expect(controller.loadingMore, isFalse);

      await controller.loadMore();

      expect(ids(), ['new', 'e1', 'e2', 'e3']);
    });

    test('an older refresh that answers late cannot overwrite a newer one', () async {
      await controller.load();
      final gate = expenses.gate = Completer<void>();
      // This refresh sees e1 to e7 and is held.
      final older = controller.refreshAfterWrite();
      expenses.gate = null;
      expenses.all = [expenseOf('newer'), ...expenses.all];

      await controller.refreshAfterWrite();
      gate.complete();
      await older;

      expect(ids().first, 'newer');
    });
  });

  test('pull-to-refresh refetches the group too', () async {
    await controller.load();
    expect(groups.getCalls, 1);

    await controller.refreshAll();

    expect(groups.getCalls, 2);
  });

  test('retry shows the skeleton while it loads', () async {
    controller.loading.value = false;

    final retrying = controller.retry();

    expect(controller.loading.value, isTrue);
    await retrying;
    expect(controller.loading.value, isFalse);
  });

  group('members and invites', () {
    setUp(() async => controller.load());

    test('an invite checks the address, then shows the invite', () async {
      expect(await controller.invite('not-an-email'), S.enterValidEmail);
      expect(groups.calls, isEmpty);

      expect(await controller.invite(' new@x.com '), isNull);
      expect(groups.calls, ['invite new@x.com']);
      expect(controller.group.value!.invites.single.email, 'new@x.com');
    });

    test('inviting an existing member says so', () async {
      groups.failWith = apiError('ALREADY_MEMBER');

      expect(await controller.invite('b@x.com'), 'ALREADY_MEMBER');
    });

    test('cancelling an invite that is already gone just refreshes', () async {
      await controller.invite('new@x.com');
      final invite = controller.group.value!.invites.single;

      expect(await controller.cancelInvite(invite), isNull);
      expect(controller.group.value!.invites, isEmpty);

      groups.failWith = apiError('INVITE_NOT_FOUND', status: 404);

      expect(await controller.cancelInvite(invite), isNull);
    });

    test("removing someone who still owes says why it's blocked", () async {
      groups.failWith = apiError('BALANCE_NOT_ZERO');

      expect(await controller.removeMember(bat), S.removeBlocked);
      expect(controller.group.value!.members, contains(bat));

      expect(await controller.removeMember(bat), isNull);
      expect(controller.group.value!.members, isNot(contains(bat)));
    });

    test('leaving with a balance is blocked with its own message', () async {
      groups.failWith = apiError('BALANCE_NOT_ZERO');

      expect(await controller.leave(), S.leaveBlocked);
      expect(await controller.leave(), isNull);
      expect(shown.last, startsWith(S.leftGroup));
    });

    test('deleting a group with balances shows the error, and success says so', () async {
      groups.failWith = apiError('BALANCES_NOT_ZERO');

      expect(await controller.deleteGroup(), 'BALANCES_NOT_ZERO');
      expect(await controller.deleteGroup(), isNull);
      expect(shown.last, startsWith(S.groupDeleted));
    });

    test('renaming trims the name and allows 1 to 80 characters', () async {
      expect(await controller.rename('   '), S.giveGroupName);
      expect(await controller.rename('x' * 81), S.groupNameTooLong);

      expect(await controller.rename('  Байр  '), isNull);
      expect(groups.calls.last, 'rename Байр');
      expect(controller.group.value!.name, 'Байр');
    });
  });

  test('findExpense pages through for an expense that is not loaded', () async {
    await controller.load();

    final found = await controller.findExpense('e7');

    expect(found?.id, 'e7');
    expect(await controller.findExpense('gone'), isNull);
  });

  test('replaceExpense and removeExpense patch the loaded list', () async {
    await controller.load();

    controller.replaceExpense(expenseOf('e2', version: 2, description: 'Taxi'));
    expect(controller.expenses[1].description, 'Taxi');

    controller.removeExpense('e1');
    expect(ids(), ['e2']);
  });

  test("the user's balance comes from the loaded balances", () async {
    groups.balancesResult = const Balances(
      currency: 'USD',
      balances: [MemberBalance(userId: 'a', name: 'Anu', netCents: 500)],
      transfers: [Transfer(fromUserId: 'b', toUserId: 'a', amountCents: 500)],
    );

    await controller.load();

    expect(controller.myNetCents, 500);
    expect(controller.isSettled, isFalse);
  });
}
