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

  test('Expense keeps version and who edited it', () {
    final e = Expense.fromJson({
      ...expenseJson,
      'version': 3,
      'updatedAt': '2026-11-06T10:00:00.000Z',
      'updatedBy': 'b',
    });
    expect(e.version, 3);
    expect(e.updatedBy, 'b');
    expect(e.updatedAt, DateTime.utc(2026, 11, 6, 10));
    expect(Expense.fromJson(expenseJson).version, 1);
  });

  test("an unknown split type (a newer server) doesn't break the group page", () {
    final e = Expense.fromJson({...expenseJson, 'splitType': 'SHARES'});
    expect(e.splitType, SplitType.exact);
    expect(e.splits, hasLength(3));
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
    expect(g.invites, isEmpty);
  });

  test('Group.invites and PendingInvite', () {
    final g = Group.fromJson({
      'id': 'g1',
      'name': 'Flat',
      'currency': 'MNT',
      'members': <Object>[],
      'invites': [
        {'id': 'i1', 'email': 'new@x.com', 'invitedBy': 'a', 'createdAt': '2026-11-05T10:00:00.000Z'},
      ],
      'createdAt': '2026-11-05T10:00:00.000Z',
    });
    expect(g.invites.single.email, 'new@x.com');

    final p = PendingInvite.fromJson({
      'id': 'i1',
      'groupId': 'g1',
      'groupName': 'Flat',
      'currency': 'MNT',
      'memberCount': 3,
      'invitedByName': 'Anu',
      'createdAt': '2026-11-05T10:00:00.000Z',
    });
    expect(p.memberCount, 3);
    expect(p.invitedByName, 'Anu');
  });

  test('Me.emailVerified', () {
    final json = {'userId': 'a', 'email': 'a@x.com', 'name': 'Anu'};
    expect(Me.fromJson({...json, 'emailVerified': true}).emailVerified, isTrue);
    expect(Me.fromJson(json).emailVerified, isFalse);
  });

  test('PresignedPost and a page with a cursor', () {
    final post = PresignedPost.fromJson({
      'uploadUrl': 'https://b.s3.ap-northeast-1.amazonaws.com/',
      'method': 'POST',
      'fields': {'key': 'k', 'Policy': 'p'},
      'key': 'k',
      'maxBytes': 10485760,
      'expiresIn': 300,
    });
    expect(post.fields, {'key': 'k', 'Policy': 'p'});
    expect(post.maxBytes, 10485760);

    final page = CursorPage.fromJson({
      'items': [expenseJson],
      'nextCursor': 'e1',
    }, Expense.fromJson);
    expect(page.items.single.id, 'e1');
    expect(page.nextCursor, 'e1');
  });
}
