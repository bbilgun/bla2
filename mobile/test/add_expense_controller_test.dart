import 'package:flutter_test/flutter_test.dart';
import 'package:netzero/controllers/add_expense_controller.dart';
import 'package:netzero/models/models.dart';
import 'package:netzero/repositories/repositories.dart';
import 'package:netzero/services/api_client.dart';

/// Records every create() call; fails the first [failures] calls with a network error.
class FakeExpenses implements ExpensesRepository {
  FakeExpenses({this.failures = 0});

  int failures;
  final calls = <({Map<String, dynamic> body, String key})>[];

  @override
  Future<Expense> create(String groupId, Map<String, dynamic> body, {required String idempotencyKey}) async {
    calls.add((body: body, key: idempotencyKey));
    if (failures > 0) {
      failures--;
      throw ApiException(code: 'NETWORK', message: 'offline');
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
  Future<ExpensePage> list(String groupId, {String? cursor, int limit = 20}) => throw UnimplementedError();
}

final flat = Group(
  id: 'g1',
  name: 'Flat',
  currency: 'USD',
  members: const [
    Member(userId: 'a', email: 'a@x.com', name: 'Anu'),
    Member(userId: 'b', email: 'b@x.com', name: 'Bat'),
    Member(userId: 'c', email: 'c@x.com', name: 'Saraa'),
  ],
  createdAt: DateTime.utc(2026, 11, 1),
);

AddExpenseController make(FakeExpenses repo) {
  final c = AddExpenseController(group: flat, myUserId: 'a', expenses: repo);
  c.description.text = 'Dinner';
  c.amount.text = '100.00';
  return c;
}

void main() {
  group('exit check: Save, network drops, Save again', () {
    test('the retry sends the same Idempotency-Key, and it is dropped after success', () async {
      final repo = FakeExpenses(failures: 1);
      final c = make(repo);

      expect(await c.save(), isNull); // network error
      final firstKey = repo.calls.single.key;
      expect(c.pendingIdempotencyKey, firstKey);
      expect(c.error.value, contains('давхар бүртгэгдэхгүй'));

      expect(await c.save(), isNotNull); // retry succeeds
      expect(repo.calls.map((call) => call.key), [firstKey, firstKey]);
      expect(c.pendingIdempotencyKey, isNull);
    });

    test('editing the form after a failure makes it a new request with a new key', () async {
      final repo = FakeExpenses(failures: 1);
      final c = make(repo);
      await c.save();
      c.amount.text = '120.00';
      await c.save();
      expect(repo.calls[0].key, isNot(repo.calls[1].key));
    });

    test('two separate expenses never share a key', () async {
      final repo = FakeExpenses();
      final c = make(repo);
      await c.save();
      await c.save();
      expect(repo.calls[0].key, isNot(repo.calls[1].key));
    });
  });

  group('body', () {
    test('EVEN sends intent, not amounts', () {
      final c = make(FakeExpenses());
      c.toggleIncluded('c');
      expect(c.buildBody(), {
        'description': 'Dinner',
        'amountCents': 10000,
        'paidBy': 'a',
        'split': {
          'type': 'EVEN',
          'userIds': ['a', 'b'],
        },
      });
    });

    test('EXACT must add up before it is sent', () {
      final c = make(FakeExpenses())..splitType.value = SplitType.exact;
      c.exactCtrls['a']!.text = '60';
      c.exactCtrls['b']!.text = '30';
      expect(c.exactRemainingCents, 1000);
      expect(c.buildBody(), isNull);
      expect(c.fieldErrors['split'], contains(r'$100.00'));

      c.exactCtrls['c']!.text = '10.00';
      expect(c.exactRemainingCents, 0);
      expect((c.buildBody()!['split'] as Map)['shares'], [
        {'userId': 'a', 'amountCents': 6000},
        {'userId': 'b', 'amountCents': 3000},
        {'userId': 'c', 'amountCents': 1000},
      ]);
    });

    test('PERCENT sends basis points', () {
      final c = make(FakeExpenses())..splitType.value = SplitType.percent;
      c.splitPercentEvenly();
      expect(c.percentAssignedBp, 10000);
      expect((c.buildBody()!['split'] as Map)['shares'], [
        {'userId': 'a', 'basisPoints': 3334},
        {'userId': 'b', 'basisPoints': 3333},
        {'userId': 'c', 'basisPoints': 3333},
      ]);
    });

    test('missing fields are reported next to the field', () {
      final c = make(FakeExpenses());
      c.description.text = '';
      c.amount.text = '12.345';
      expect(c.buildBody(), isNull);
      expect(c.fieldErrors.keys, containsAll(['description', 'amount']));
    });
  });
}
