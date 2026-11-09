// Parsing the API's JSON into models.
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

  test('an expense keeps integer cents', () {
    final expense = Expense.fromJson(expenseJson);

    expect(expense.amountCents, 10000);
    expect(expense.splitType, SplitType.even);
    expect(expense.splits.map((split) => split.amountCents).reduce((a, b) => a + b), 10000);
  });

  test('an expense keeps its version and who last edited it', () {
    final edited = Expense.fromJson({
      ...expenseJson,
      'version': 3,
      'updatedAt': '2026-11-06T10:00:00.000Z',
      'updatedBy': 'b',
    });

    expect(edited.version, 3);
    expect(edited.updatedBy, 'b');
    expect(edited.updatedAt, DateTime.utc(2026, 11, 6, 10));
    expect(Expense.fromJson(expenseJson).version, 1);
  });

  test('an unknown split type reads as exact', () {
    final expense = Expense.fromJson({...expenseJson, 'splitType': 'SHARES'});

    expect(expense.splitType, SplitType.exact);
    expect(expense.splits, hasLength(3));
  });

  test('a float amount fails to parse', () {
    expect(() => Expense.fromJson({...expenseJson, 'amountCents': 100.5}), throwsA(isA<TypeError>()));
  });

  test('balances look up a member and default to zero', () {
    final balances = Balances.fromJson({
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

    expect(balances.netOf('a'), 6666);
    expect(balances.netOf('nobody'), 0);
    expect(balances.transfers, hasLength(2));
  });

  test('a group names former members', () {
    final group = Group.fromJson({
      'id': 'g1',
      'name': 'Flat',
      'currency': 'MNT',
      'members': [
        {'userId': 'a', 'email': 'a@x.com', 'name': 'Anu'},
      ],
      'createdBy': 'a',
      'createdAt': '2026-11-05T10:00:00.000Z',
    });

    expect(group.nameOf('a'), 'Anu');
    expect(group.nameOf('zzz'), 'Хуучин гишүүн');
    expect(group.invites, isEmpty);
  });

  test('group invites and pending invites parse', () {
    final group = Group.fromJson({
      'id': 'g1',
      'name': 'Flat',
      'currency': 'MNT',
      'members': <Object>[],
      'invites': [
        {'id': 'i1', 'email': 'new@x.com', 'invitedBy': 'a', 'createdAt': '2026-11-05T10:00:00.000Z'},
      ],
      'createdAt': '2026-11-05T10:00:00.000Z',
    });
    final pending = PendingInvite.fromJson({
      'id': 'i1',
      'groupId': 'g1',
      'groupName': 'Flat',
      'currency': 'MNT',
      'memberCount': 3,
      'invitedByName': 'Anu',
      'createdAt': '2026-11-05T10:00:00.000Z',
    });

    expect(group.invites.single.email, 'new@x.com');
    expect(pending.memberCount, 3);
    expect(pending.invitedByName, 'Anu');
  });

  test('a profile is unverified unless the server says so', () {
    final json = {'userId': 'a', 'email': 'a@x.com', 'name': 'Anu'};
    expect(Me.fromJson({...json, 'emailVerified': true}).emailVerified, isTrue);
    expect(Me.fromJson(json).emailVerified, isFalse);
  });

  test('a presigned post and a cursor page parse', () {
    final post = PresignedPost.fromJson({
      'uploadUrl': 'https://b.s3.ap-northeast-1.amazonaws.com/',
      'method': 'POST',
      'fields': {'key': 'k', 'Policy': 'p'},
      'key': 'k',
      'maxBytes': 10485760,
      'expiresIn': 300,
    });
    final page = CursorPage.fromJson({
      'items': [expenseJson],
      'nextCursor': 'e1',
    }, Expense.fromJson);

    expect(post.fields, {'key': 'k', 'Policy': 'p'});
    expect(post.maxBytes, 10485760);
    expect(page.items.single.id, 'e1');
    expect(page.nextCursor, 'e1');
  });
}
