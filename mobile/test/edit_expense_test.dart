// Editing an expense in the form, and the expense page's reload and delete.
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:netzero/app/strings.dart';
import 'package:netzero/controllers/add_expense_controller.dart';
import 'package:netzero/controllers/expense_controller.dart';
import 'package:netzero/controllers/group_detail_controller.dart';
import 'package:netzero/models/models.dart';
import 'package:netzero/repositories/repositories.dart';

import 'fakes.dart';

/// A receipts repository for tests that never touch receipts.
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

  AddExpenseController editing(Expense expense) =>
      AddExpenseController(group: groupOf(), myUserId: 'a', expenses: expenses, existing: expense);

  group('the form in edit mode', () {
    test('is filled from the expense and stays clean until something changes', () {
      final form = editing(exactExpense);

      expect(form.isEditing, isTrue);
      expect(form.description.text, 'Dinner');
      expect(form.amount.text, '100.00');
      expect(form.splitType.value, SplitType.exact);
      expect(form.exactFields['a']!.text, '70.00');
      expect(form.exactFields['b']!.text, '30.00');
      expect(form.exactFields['c']!.text, '');
      expect(form.isDirty, isFalse);

      form.description.text = 'Dinner and drinks';

      expect(form.isDirty, isTrue);
    });

    test('an even split ticks only the people who were in it', () {
      final form = editing(
        expenseOf(
          'e2',
          splits: const [
            Split(userId: 'a', amountCents: 50),
            Split(userId: 'c', amountCents: 50),
          ],
        ),
      );

      expect(form.included, {'a', 'c'});
    });

    test('a percent split asks for the percentages again', () {
      final form = editing(expenseOf('e3', splitType: SplitType.percent));

      expect(form.mustReenterPercents, isTrue);
      expect(form.percentFields.values.map((field) => field.text), everyElement(isEmpty));
    });

    test('saving sends a PUT with the edited version and no Idempotency-Key', () async {
      final form = editing(exactExpense);
      form.description.text = 'Dinner and drinks';

      final saved = await form.save();

      expect(saved?.version, 4);
      final update = expenses.updates.single;
      expect(update.id, 'e1');
      expect(update.version, 3);
      expect(update.body['description'], 'Dinner and drinks');
      expect((update.body['split'] as Map)['type'], 'EXACT');
      expect(form.pendingIdempotencyKey, isNull);
      expect(form.isDirty, isFalse);
    });

    test('a conflicting edit marks the form outdated and saves nothing', () async {
      final form = editing(exactExpense);
      expenses.failUpdate = apiError('EXPENSE_CHANGED');

      final saved = await form.save();

      expect(saved, isNull);
      expect(form.outdated, isTrue);
      expect(form.error.value, 'EXPENSE_CHANGED');
    });

    test('an edit that failed offline can be sent again as is', () async {
      final form = editing(exactExpense);
      expenses.failUpdate = networkError();

      expect(await form.save(), isNull);
      expect(form.error.value, S.saveOffline);
      expect(form.outdated, isFalse);

      expect(await form.save(), isNotNull);
      expect(expenses.updates.map((update) => update.version), [3, 3]);
    });
  });

  group('the expense page', () {
    late GroupDetailController detail;
    late ExpenseController controller;

    ExpenseController open(String expenseId) => ExpenseController(detail, expenseId, NoReceipts(), expenses)..onInit();

    setUp(() async {
      expenses = FakeExpenses([for (var i = 1; i <= 5; i++) expenseOf('e$i')]);
      detail = GroupDetailController('g1', FakeGroups(), expenses, myUserId: () => 'a');
      // The first page holds e1 and e2.
      await detail.load();
    });

    test('reloading finds the newest version even beyond the first page', () async {
      await detail.loadMore();
      controller = open('e3');
      expenses.all = [
        for (final expense in expenses.all)
          expense.id == 'e3' ? expenseOf('e3', description: 'Changed', version: 2) : expense,
      ];

      await controller.reload();

      expect(controller.expense?.description, 'Changed');
      expect(controller.expense?.version, 2);
    });

    test('reloading notices the expense was deleted', () async {
      controller = open('e2');
      expenses.all = [...expenses.all.where((expense) => expense.id != 'e2')];

      await controller.reload();

      expect(controller.expense, isNull);
    });

    test('deleting removes it from the group list', () async {
      controller = open('e1');

      expect(await controller.delete(), isTrue);

      expect(expenses.deletes, ['e1']);
      expect(detail.expenses.map((expense) => expense.id), isNot(contains('e1')));
      expect(shown, contains(S.expenseDeleted));
    });

    test('deleting one someone else already deleted counts as done', () async {
      controller = open('e1');
      expenses.failDelete = apiError('EXPENSE_NOT_FOUND', status: 404);

      expect(await controller.delete(), isTrue);
    });

    test('a failed delete keeps the expense and says why', () async {
      controller = open('e1');
      expenses.failDelete = networkError();

      expect(await controller.delete(), isFalse);

      expect(controller.error.value, 'offline');
      expect(controller.expense, isNotNull);
    });
  });
}
