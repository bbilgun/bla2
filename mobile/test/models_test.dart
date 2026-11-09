import 'package:flutter_test/flutter_test.dart';
import 'package:netzero/models/models.dart';

void main() {
  final expenseJson = {
    'id': 'e1',
    'groupId': 'g1',
    'description': 'Dinner',
    'amountCents': 10000,
    'paidBy': 'a',
    'splitType': 'EVEN',
    'splits': [
      {'userId': 'a', 'amountCents': 3334},
      {'userId': 'b', 'amountCents': 3333},
      {'userId': 'c', 'amountCents': 3333},
    ],
    'hasReceipt': false,
    'createdBy': 'a',
    'createdAt': '2026-11-05T10:00:00.000Z',
  };

  test('Expense.fromJson keeps integer cents', () {
    final e = Expense.fromJson(expenseJson);
    expect(e.amountCents, 10000);
    expect(e.splitType, SplitType.even);
    expect(e.splits.map((s) => s.amountCents).reduce((a, b) => a + b), 10000);
  });

  test('a float amount from the server is a bug, and fails loudly', () {
    expect(() => Expense.fromJson({...expenseJson, 'amountCents': 100.5}), throwsA(isA<TypeError>()));
  });

  test('Balances.fromJson and netOf', () {
    final b = Balances.fromJson({
      'groupId': 'g1',
      'currency': 'USD',
      'balances': [
        {'userId': 'a', 'name': 'A', 'netCents': 6666},
        {'userId': 'b', 'name': 'B', 'netCents': -3333},
        {'userId': 'c', 'name': 'C', 'netCents': -3333},
      ],
      'transfers': [
        {'fromUserId': 'b', 'toUserId': 'a', 'amountCents': 3333},
        {'fromUserId': 'c', 'toUserId': 'a', 'amountCents': 3333},
      ],
    });
    expect(b.netOf('a'), 6666);
    expect(b.netOf('nobody'), 0);
    expect(b.transfers, hasLength(2));
  });

  test('Group.nameOf', () {
    final g = Group.fromJson({
      'id': 'g1',
      'name': 'Flat',
      'currency': 'MNT',
      'members': [
        {'userId': 'a', 'email': 'a@x.com', 'name': 'Anu'},
      ],
      'createdBy': 'a',
      'createdAt': '2026-11-05T10:00:00.000Z',
    });
    expect(g.nameOf('a'), 'Anu');
    expect(g.nameOf('zzz'), 'Хуучин гишүүн');
  });
}
