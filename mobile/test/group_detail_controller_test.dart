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
  late GroupDetailController c;

  setUp(() {
    Get.testMode = true;
    recordNotifications();
    groups = FakeGroups();
    expenses = FakeExpenses([for (var i = 1; i <= 7; i++) expenseOf('e$i')]); // pages of 2
    c = GroupDetailController('g1', groups, expenses, myUserId: () => 'a');
  });

  List<String> ids() => c.expenses.map((e) => e.id).toList();

  group('pagination', () {
    test('first page, then the next pages in order, then no more', () async {
      await c.load();
      expect(ids(), ['e1', 'e2']);
      expect(c.hasMore, isTrue);
      expect(c.shouldAutoLoad, isTrue);

      await c.loadMore();
      await c.loadMore();
      await c.loadMore();
      expect(ids(), ['e1', 'e2', 'e3', 'e4', 'e5', 'e6', 'e7']);
      expect(c.hasMore, isFalse);
      expect(c.shouldAutoLoad, isFalse);
      expect(expenses.listCalls, [null, 'e2', 'e4', 'e6']);
    });

    test('a failed page stops auto-loading until "load more" is tapped (no tight retry loop)', () async {
      await c.load();
      expenses.failNextPage = networkError();
      await c.loadMore();
      expect(ids(), ['e1', 'e2']);
      expect(c.loadMoreFailed, isTrue);
      expect(c.hasMore, isTrue); // the button stays
      expect(c.shouldAutoLoad, isFalse); // but the list doesn't fetch on its own
      expect(shown.single, startsWith(S.couldNotLoadMore));

      await c.loadMore(); // the button
      expect(ids(), ['e1', 'e2', 'e3', 'e4']);
      expect(c.loadMoreFailed, isFalse);
      expect(c.shouldAutoLoad, isTrue);
    });

    test('loadMore while one is in flight does nothing', () async {
      await c.load();
      expenses.gate = Completer<void>();
      final first = c.loadMore();
      await c.loadMore();
      expenses.gate!.complete();
      await first;
      expect(expenses.listCalls, [null, 'e2']);
      expect(ids(), ['e1', 'e2', 'e3', 'e4']);
    });

    test('a refresh after a write discards a "load more" still in flight (no out-of-order pages)', () async {
      await c.load();
      final gate = expenses.gate = Completer<void>();
      final stalePage = c.loadMore(); // page 2 of the old list, held
      expenses.gate = null;

      expenses.all = [expenseOf('new'), ...expenses.all]; // someone added an expense
      await c.refreshAfterWrite();
      expect(ids(), ['new', 'e1']);

      gate.complete();
      await stalePage;
      expect(ids(), ['new', 'e1']); // the old page 2 (e3, e4) was not appended
      expect(c.loadingMore, isFalse);

      await c.loadMore();
      expect(ids(), ['new', 'e1', 'e2', 'e3']);
    });

    test('an older refresh that answers late cannot overwrite a newer one', () async {
      await c.load();
      final gate = expenses.gate = Completer<void>();
      final older = c.refreshAfterWrite(); // sees e1..e7, held
      expenses.gate = null;
      expenses.all = [expenseOf('newer'), ...expenses.all];
      await c.refreshAfterWrite();
      gate.complete();
      await older;
      expect(ids().first, 'newer');
    });
  });

  test('pull-to-refresh refetches the group too (members, invites)', () async {
    await c.load();
    expect(groups.getCalls, 1);
    await c.refreshAll();
    expect(groups.getCalls, 2);
  });

  test('retry shows the skeleton instead of flashing the empty state', () async {
    c.loading.value = false;
    final retrying = c.retry();
    expect(c.loading.value, isTrue);
    await retrying;
    expect(c.loading.value, isFalse);
  });

  group('members and invites', () {
    setUp(() async => c.load());

    test('invite by email: checks the address, then shows the invite', () async {
      expect(await c.invite('not-an-email'), S.enterValidEmail);
      expect(groups.calls, isEmpty);
      expect(await c.invite(' new@x.com '), isNull);
      expect(groups.calls, ['invite new@x.com']);
      expect(c.group.value!.invites.single.email, 'new@x.com');
    });

    test('inviting an existing member says so', () async {
      groups.failWith = apiError('ALREADY_MEMBER');
      expect(await c.invite('b@x.com'), 'ALREADY_MEMBER');
    });

    test('cancel an invite; one that is already gone just refreshes', () async {
      await c.invite('new@x.com');
      final invite = c.group.value!.invites.single;
      expect(await c.cancelInvite(invite), isNull);
      expect(c.group.value!.invites, isEmpty);

      groups.failWith = apiError('INVITE_NOT_FOUND', status: 404);
      expect(await c.cancelInvite(invite), isNull);
    });

    test("removing someone who still owes shows why it's blocked", () async {
      groups.failWith = apiError('BALANCE_NOT_ZERO');
      expect(await c.removeMember(bat), S.removeBlocked);
      expect(c.group.value!.members, contains(bat));

      expect(await c.removeMember(bat), isNull);
      expect(c.group.value!.members, isNot(contains(bat)));
    });

    test('leaving with a balance is blocked with its own message', () async {
      groups.failWith = apiError('BALANCE_NOT_ZERO');
      expect(await c.leave(), S.leaveBlocked);
      expect(await c.leave(), isNull);
      expect(shown.last, startsWith(S.leftGroup));
    });

    test('delete group: BALANCES_NOT_ZERO is shown; success says so', () async {
      groups.failWith = apiError('BALANCES_NOT_ZERO');
      expect(await c.deleteGroup(), 'BALANCES_NOT_ZERO');
      expect(await c.deleteGroup(), isNull);
      expect(shown.last, startsWith(S.groupDeleted));
    });

    test('rename: trimmed, 1-80 characters', () async {
      expect(await c.rename('   '), S.giveGroupName);
      expect(await c.rename('x' * 81), S.groupNameTooLong);
      expect(await c.rename('  Байр  '), isNull);
      expect(groups.calls.last, 'rename Байр');
      expect(c.group.value!.name, 'Байр');
    });
  });

  test('findExpense walks the pages for an expense that is not loaded', () async {
    await c.load();
    final found = await c.findExpense('e7');
    expect(found?.id, 'e7');
    expect(await c.findExpense('gone'), isNull);
  });

  test('replaceExpense and removeExpense patch the loaded list with server data', () async {
    await c.load();
    c.replaceExpense(expenseOf('e2', version: 2, description: 'Taxi'));
    expect(c.expenses[1].description, 'Taxi');
    c.removeExpense('e1');
    expect(ids(), ['e2']);
  });

  test('a balance of a member is read through plain getters', () async {
    groups.balancesResult = const Balances(
      currency: 'USD',
      balances: [MemberBalance(userId: 'a', name: 'Anu', netCents: 500)],
      transfers: [Transfer(fromUserId: 'b', toUserId: 'a', amountCents: 500)],
    );
    await c.load();
    expect(c.myNetCents, 500);
    expect(c.isSettled, isFalse);
  });
}
