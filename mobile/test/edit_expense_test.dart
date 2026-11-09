import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:netzero/app/strings.dart';
import 'package:netzero/controllers/add_expense_controller.dart';
import 'package:netzero/controllers/expense_controller.dart';
import 'package:netzero/controllers/group_detail_controller.dart';
import 'package:netzero/models/models.dart';
import 'package:netzero/repositories/repositories.dart';

import 'fakes.dart';

class NoReceipts implements ReceiptsRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final exactExpense = expenseOf(
  'e1',
  amountCents: 10000,
  splitType: SplitType.exact,
  version: 3,
  splits: const [
    Split(userId: 'a', amountCents: 7000),
    Split(userId: 'b', amountCents: 3000),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeExpenses expenses;

  setUp(() {
    Get.testMode = true;
    recordNotifications();
    expenses = FakeExpenses([exactExpense]);
  });

  AddExpenseController editing(Expense e) =>
      AddExpenseController(group: groupOf(), myUserId: 'a', expenses: expenses, existing: e);

  group('the form in edit mode', () {
    test('is filled from the expense, and is not "dirty" until something changes', () {
      final c = editing(exactExpense);
      expect(c.isEditing, isTrue);
      expect(c.description.text, 'Dinner');
      expect(c.amount.text, '100.00');
      expect(c.splitType.value, SplitType.exact);
      expect(c.exactCtrls['a']!.text, '70.00');
      expect(c.exactCtrls['b']!.text, '30.00');
      expect(c.exactCtrls['c']!.text, '');
      expect(c.isDirty, isFalse);

      c.description.text = 'Dinner and drinks';
      expect(c.isDirty, isTrue);
    });

    test('an EVEN expense ticks only the people who were in it', () {
      final c = editing(
        expenseOf(
          'e2',
          splits: const [
            Split(userId: 'a', amountCents: 50),
            Split(userId: 'c', amountCents: 50),
          ],
        ),
      );
      expect(c.included, {'a', 'c'});
    });

    test('a PERCENT expense asks for the percents again (the server returns amounts only)', () {
      final c = editing(expenseOf('e3', splitType: SplitType.percent));
      expect(c.mustReenterPercents, isTrue);
      expect(c.percentCtrls.values.map((t) => t.text), everyElement(isEmpty));
    });

    test('save sends PUT with the edited version and no Idempotency-Key', () async {
      final c = editing(exactExpense);
      c.description.text = 'Dinner and drinks';
      final saved = await c.save();
      expect(saved?.version, 4);
      final update = expenses.updates.single;
      expect(update.id, 'e1');
      expect(update.version, 3);
      expect(update.body['description'], 'Dinner and drinks');
      expect((update.body['split'] as Map)['type'], 'EXACT');
      expect(c.pendingIdempotencyKey, isNull);
      expect(c.isDirty, isFalse); // saved: leaving doesn't ask
    });

    test('EXPENSE_CHANGED: marked outdated with the explanation, nothing saved', () async {
      final c = editing(exactExpense);
      expenses.failUpdate = apiError('EXPENSE_CHANGED');
      expect(await c.save(), isNull);
      expect(c.outdated, isTrue);
      expect(c.error.value, 'EXPENSE_CHANGED');
    });

    test('offline: the same edit can simply be sent again', () async {
      final c = editing(exactExpense);
      expenses.failUpdate = networkError();
      expect(await c.save(), isNull);
      expect(c.error.value, S.saveOffline);
      expect(c.outdated, isFalse);
      expect(await c.save(), isNotNull);
      expect(expenses.updates.map((u) => u.version), [3, 3]);
    });
  });

  group('the expense page', () {
    late GroupDetailController detail;
    late ExpenseController c;

    setUp(() async {
      expenses = FakeExpenses([for (var i = 1; i <= 5; i++) expenseOf('e$i')]);
      detail = GroupDetailController('g1', FakeGroups(), expenses, myUserId: () => 'a');
      await detail.load(); // e1, e2 loaded
    });

    test('backing out of the editor (or EXPENSE_CHANGED) reloads, even an expense beyond the first page', () async {
      await detail.loadMore();
      c = ExpenseController(detail, 'e3', NoReceipts(), expenses)..onInit();
      expenses.all = [
        for (final e in expenses.all) e.id == 'e3' ? expenseOf('e3', description: 'Changed', version: 2) : e,
      ];
      await c.reload();
      expect(c.expense?.description, 'Changed');
      expect(c.expense?.version, 2);
    });

    test('reload notices it was deleted', () async {
      c = ExpenseController(detail, 'e2', NoReceipts(), expenses)..onInit();
      expenses.all = [...expenses.all.where((e) => e.id != 'e2')];
      await c.reload();
      expect(c.expense, isNull);
    });

    test('delete removes it from the group list and refreshes', () async {
      c = ExpenseController(detail, 'e1', NoReceipts(), expenses)..onInit();
      expect(await c.delete(), isTrue);
      expect(expenses.deletes, ['e1']);
      expect(detail.expenses.map((e) => e.id), isNot(contains('e1')));
      expect(shown, contains(S.expenseDeleted));
    });

    test('deleting one someone else already deleted counts as done', () async {
      c = ExpenseController(detail, 'e1', NoReceipts(), expenses)..onInit();
      expenses.failDelete = apiError('EXPENSE_NOT_FOUND', status: 404);
      expect(await c.delete(), isTrue);
    });

    test('a failed delete keeps it and says why', () async {
      c = ExpenseController(detail, 'e1', NoReceipts(), expenses)..onInit();
      expenses.failDelete = networkError();
      expect(await c.delete(), isFalse);
      expect(c.error.value, 'offline');
      expect(c.expense, isNotNull);
    });
  });
}
