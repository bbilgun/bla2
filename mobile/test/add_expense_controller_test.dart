// AddExpenseController: the Idempotency-Key on save, currencies, and the request body.
import 'package:flutter_test/flutter_test.dart';
import 'package:netzero/controllers/add_expense_controller.dart';
import 'package:netzero/models/models.dart';
import 'package:netzero/repositories/repositories.dart';

import 'fakes.dart';

/// Records every create() call. The first [failures] calls fail as if offline.
class RecordingExpenses implements ExpensesRepository {
  RecordingExpenses({this.failures = 0});

  int failures;
  final calls = <({Map<String, dynamic> body, String key})>[];

  @override
  Future<Expense> create(String groupId, Map<String, dynamic> body, {required String idempotencyKey}) async {
    calls.add((body: body, key: idempotencyKey));
    if (failures > 0) {
      failures--;
      throw networkError();
    }
    return Expense(
      id: 'e${calls.length}',
      groupId: groupId,
      description: body['description'] as String,
      amountCents: body['amountCents'] as int,
      paidBy: body['paidBy'] as String,
      splitType: SplitType.even,
      splits: const [],
      hasReceipt: false,
      createdAt: DateTime.utc(2026, 11, 5),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// A form for a 100.00 dinner in the Flat group, entered by Anu.
AddExpenseController dinnerForm(RecordingExpenses repo) {
  final form = AddExpenseController(group: groupOf(), myUserId: 'a', expenses: repo);
  form.description.text = 'Dinner';
  form.amount.text = '100.00';
  return form;
}

void main() {
  group('Idempotency-Key', () {
    test('a retry after a network error sends the same key, which is dropped after success', () async {
      final repo = RecordingExpenses(failures: 1);
      final form = dinnerForm(repo);

      expect(await form.save(), isNull);

      final firstKey = repo.calls.single.key;
      expect(form.pendingIdempotencyKey, firstKey);
      expect(form.error.value, contains('давхар бүртгэгдэхгүй'));

      expect(await form.save(), isNotNull);

      expect(repo.calls.map((call) => call.key), [firstKey, firstKey]);
      expect(form.pendingIdempotencyKey, isNull);
    });

    test('changing the form after a failure makes a new request with a new key', () async {
      final repo = RecordingExpenses(failures: 1);
      final form = dinnerForm(repo);

      await form.save();
      form.amount.text = '120.00';
      await form.save();

      expect(repo.calls[0].key, isNot(repo.calls[1].key));
    });

    test('two separate expenses never share a key', () async {
      final repo = RecordingExpenses();
      final form = dinnerForm(repo);

      await form.save();
      await form.save();

      expect(repo.calls[0].key, isNot(repo.calls[1].key));
    });
  });

  group('currencies without decimals', () {
    test('KRW amounts are whole won', () {
      final seoul = groupOf(id: 'g2', name: 'Seoul', currency: 'KRW');
      final form = AddExpenseController(group: seoul, myUserId: 'a', expenses: RecordingExpenses())
        ..description.text = 'Bibimbap'
        ..amount.text = '25,000';

      expect(form.amountCents, 25000);

      form.amount.text = '25000.50';

      expect(form.amountCents, isNull);
    });
  });

  test('splitting percentages evenly gives the leftover to the first row', () {
    final form = dinnerForm(RecordingExpenses())..splitType.value = SplitType.percent;

    form.splitPercentEvenly();

    expect(form.percentFields['a']!.text, '33.34');
    expect(form.percentFields['b']!.text, '33.33');
  });

  group('request body', () {
    test('an even split sends who is in, not amounts', () {
      final form = dinnerForm(RecordingExpenses());

      form.toggleIncluded('c');

      expect(form.buildBody(), {
        'description': 'Dinner',
        'amountCents': 10000,
        'paidBy': 'a',
        'split': {
          'type': 'EVEN',
          'userIds': ['a', 'b'],
        },
      });
    });

    test('exact shares must add up before anything is sent', () {
      final form = dinnerForm(RecordingExpenses())..splitType.value = SplitType.exact;
      form.exactFields['a']!.text = '60';
      form.exactFields['b']!.text = '30';

      expect(form.exactRemainingCents, 1000);
      expect(form.buildBody(), isNull);
      expect(form.fieldErrors['split'], contains(r'$100.00'));

      form.exactFields['c']!.text = '10.00';

      expect(form.exactRemainingCents, 0);
      expect((form.buildBody()!['split'] as Map)['shares'], [
        {'userId': 'a', 'amountCents': 6000},
        {'userId': 'b', 'amountCents': 3000},
        {'userId': 'c', 'amountCents': 1000},
      ]);
    });

    test('a percent split sends basis points', () {
      final form = dinnerForm(RecordingExpenses())..splitType.value = SplitType.percent;

      form.splitPercentEvenly();

      expect(form.percentAssignedBp, 10000);
      expect((form.buildBody()!['split'] as Map)['shares'], [
        {'userId': 'a', 'basisPoints': 3334},
        {'userId': 'b', 'basisPoints': 3333},
        {'userId': 'c', 'basisPoints': 3333},
      ]);
    });

    test('missing fields are reported next to the field', () {
      final form = dinnerForm(RecordingExpenses());
      form.description.text = '';
      form.amount.text = '12.345';

      expect(form.buildBody(), isNull);
      expect(form.fieldErrors.keys, containsAll(['description', 'amount']));
    });
  });
}
