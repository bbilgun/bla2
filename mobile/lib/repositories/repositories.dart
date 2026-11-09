import '../models/models.dart';
import '../services/api_client.dart';

/// Repositories turn API JSON into models. They are the only code that imports ApiClient,
/// the same way only your API module would import axios in a React Native app.

/// "receipt.jpg" / "qr.png": S3 keeps the content type from the signed fields; the name is cosmetic.
String _filename(String base, String contentType) => switch (contentType) {
  'image/png' => '$base.png',
  'image/heic' => '$base.heic',
  _ => '$base.jpg',
};

class UserRepository {
  UserRepository(this._api);
  final ApiClient _api;

  /// Also refreshes the caller's name/email in their groups when they changed.
  Future<Me> me() async => Me.fromJson(await _api.get('/me'));

  /// Uploads a screenshot of the user's bank-app "receive money" QR, shown to bill guests.
  /// Returns the new view URL.
  Future<String?> uploadPayQr(List<int> bytes, {required String contentType}) async {
    final signed = PresignedPost.fromJson(await _api.post('/me/pay-qr-url', data: {'contentType': contentType}));
    await _api.postPresigned(signed, bytes, contentType: contentType, filename: _filename('qr', contentType));
    return (await _api.put('/me/pay-qr', data: {'key': signed.key}))['payQrUrl'] as String?;
  }

  /// Deletes the account: leaves every group, deletes my bills and the Cognito user.
  /// 409 BALANCES_NOT_ZERO (details: the groups) while I still owe or am owed anything.
  Future<void> deleteAccount() async {
    await _api.delete('/me');
  }
}

class BillsRepository {
  BillsRepository(this._api);
  final ApiClient _api;

  Future<CursorPage<BillSummary>> list({String? cursor, int limit = 20}) async =>
      CursorPage.fromJson(await _api.get('/bills', query: {'limit': limit, 'cursor': ?cursor}), BillSummary.fromJson);

  Future<Bill> get(String id) async => Bill.fromJson(await _api.get('/bills/$id'));

  /// [idempotencyKey] must be reused on retries of the same create.
  Future<Bill> create(Map<String, dynamic> body, {required String idempotencyKey}) async =>
      Bill.fromJson(await _api.post('/bills', data: body, idempotencyKey: idempotencyKey));

  /// Full replace of title, lines and payment. Safe to retry as is. 409 BILL_CLOSED while closed.
  Future<Bill> update(String id, Map<String, dynamic> body) async =>
      Bill.fromJson(await _api.put('/bills/$id', data: body));

  Future<void> delete(String id) async {
    await _api.delete('/bills/$id');
  }

  /// A new link and QR; the old ones stop working.
  Future<Bill> rotateToken(String id) async => Bill.fromJson(await _api.post('/bills/$id/token'));

  Future<Bill> setOpen(String id, bool open) async =>
      Bill.fromJson(await _api.post('/bills/$id/status', data: {'status': open ? 'OPEN' : 'CLOSED'}));

  /// Ticks are the full list, not a toggle, so a retry can't flip them back.
  /// [paidCents] goes with `paid: true`: the amount the host saw when marking it.
  Future<Bill> updateGuest(String id, String guestId, {List<String>? itemIds, bool? paid, int? paidCents}) async =>
      Bill.fromJson(
        await _api.put(
          '/bills/$id/guests/$guestId',
          data: {'itemIds': ?itemIds, 'paid': ?paid, 'paidCents': ?paidCents},
        ),
      );

  Future<Bill> removeGuest(String id, String guestId) async =>
      Bill.fromJson(await _api.delete('/bills/$id/guests/$guestId'));
}

class GroupsRepository {
  GroupsRepository(this._api);
  final ApiClient _api;

  Future<CursorPage<Group>> list({String? cursor, int limit = 50}) async =>
      CursorPage.fromJson(await _api.get('/groups', query: {'limit': limit, 'cursor': ?cursor}), Group.fromJson);

  Future<Group> get(String id) async => Group.fromJson(await _api.get('/groups/$id'));

  Future<Group> create({required String name, required String currency}) async =>
      Group.fromJson(await _api.post('/groups', data: {'name': name, 'currency': currency}));

  Future<Group> rename(String groupId, String name) async =>
      Group.fromJson(await _api.patch('/groups/$groupId', data: {'name': name}));

  /// 409 BALANCES_NOT_ZERO while anyone still owes anything.
  Future<void> delete(String groupId) async {
    await _api.delete('/groups/$groupId');
  }

  /// Inviting an email that's already invited is a no-op. 409 ALREADY_MEMBER / GROUP_FULL.
  Future<Group> invite(String groupId, String email) async =>
      Group.fromJson(await _api.post('/groups/$groupId/invites', data: {'email': email}));

  Future<Group> cancelInvite(String groupId, String inviteId) async =>
      Group.fromJson(await _api.delete('/groups/$groupId/invites/$inviteId'));

  /// 409 BALANCE_NOT_ZERO while I owe or am owed.
  Future<void> leave(String groupId) async {
    await _api.post('/groups/$groupId/leave');
  }

  /// Someone else. 409 BALANCE_NOT_ZERO while they owe or are owed.
  Future<Group> removeMember(String groupId, String userId) async =>
      Group.fromJson(await _api.delete('/groups/$groupId/members/$userId'));

  Future<Balances> balances(String groupId) async => Balances.fromJson(await _api.get('/groups/$groupId/balances'));
}

/// Invites to me, matched by my verified email.
class InvitesRepository {
  InvitesRepository(this._api);
  final ApiClient _api;

  Future<List<PendingInvite>> list() async =>
      CursorPage.fromJson(await _api.get('/invites'), PendingInvite.fromJson).items;

  /// Returns the group I just joined.
  Future<Group> accept(PendingInvite invite) async =>
      Group.fromJson(await _api.post('/groups/${invite.groupId}/invites/${invite.id}/accept'));

  Future<void> decline(PendingInvite invite) async {
    await _api.post('/groups/${invite.groupId}/invites/${invite.id}/decline');
  }
}

class ExpensesRepository {
  ExpensesRepository(this._api);
  final ApiClient _api;

  Future<ExpensePage> list(String groupId, {String? cursor, int limit = 20}) async => CursorPage.fromJson(
    await _api.get('/groups/$groupId/expenses', query: {'limit': limit, 'cursor': ?cursor}),
    Expense.fromJson,
  );

  /// [body] is exactly what the server validates; [idempotencyKey] must be reused on retries.
  Future<Expense> create(String groupId, Map<String, dynamic> body, {required String idempotencyKey}) async =>
      Expense.fromJson(await _api.post('/groups/$groupId/expenses', data: body, idempotencyKey: idempotencyKey));

  /// Replaces the expense. [version] is the one that was edited: 409 EXPENSE_CHANGED if someone saved
  /// a newer one meanwhile. Safe to retry as is (the server recognises a repeat of the same edit).
  Future<Expense> update(String groupId, String expenseId, Map<String, dynamic> body, {required int version}) async =>
      Expense.fromJson(await _api.put('/groups/$groupId/expenses/$expenseId', data: {...body, 'version': version}));

  Future<void> delete(String groupId, String expenseId) async {
    await _api.delete('/groups/$groupId/expenses/$expenseId');
  }
}

class SettlementsRepository {
  SettlementsRepository(this._api);
  final ApiClient _api;

  Future<Settlement> create(
    String groupId, {
    required String fromUserId,
    required String toUserId,
    required int amountCents,
    required String idempotencyKey,
  }) async => Settlement.fromJson(
    await _api.post(
      '/groups/$groupId/settlements',
      data: {'fromUserId': fromUserId, 'toUserId': toUserId, 'amountCents': amountCents},
      idempotencyKey: idempotencyKey,
    ),
  );

  Future<CursorPage<Settlement>> list(String groupId, {String? cursor, int limit = 20}) async => CursorPage.fromJson(
    await _api.get('/groups/$groupId/settlements', query: {'limit': limit, 'cursor': ?cursor}),
    Settlement.fromJson,
  );

  /// Only the payer or the receiver may delete it (403 NOT_A_PARTY). Deleting twice is fine.
  Future<void> delete(String groupId, String settlementId) async {
    await _api.delete('/groups/$groupId/settlements/$settlementId');
  }
}

class ReceiptsRepository {
  ReceiptsRepository(this._api);
  final ApiClient _api;

  /// Asks Lambda for a presigned POST, uploads straight to S3, then confirms the key.
  /// Returns the expense with `hasReceipt: true`.
  Future<Expense> upload(String groupId, String expenseId, List<int> bytes, {required String contentType}) async {
    final base = '/groups/$groupId/expenses/$expenseId';
    final signed = PresignedPost.fromJson(await _api.post('$base/receipt-url', data: {'contentType': contentType}));
    await _api.postPresigned(signed, bytes, contentType: contentType, filename: _filename('receipt', contentType));
    return Expense.fromJson(await _api.put('$base/receipt', data: {'key': signed.key}));
  }

  /// A presigned GET, valid for 15 minutes.
  Future<String> viewUrl(String groupId, String expenseId) async =>
      (await _api.get('/groups/$groupId/expenses/$expenseId/receipt-url'))['url'] as String;
}
