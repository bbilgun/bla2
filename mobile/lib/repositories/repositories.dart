// One repository per API area. Each turns calls into HTTP requests and JSON into models, and they
// are the only code that uses ApiClient. Every method throws ApiException on failure.
import '../models/models.dart';
import '../services/api_client.dart';

// S3 takes the content type from the signed fields, so the file name is only cosmetic.
String _filename(String base, String contentType) => switch (contentType) {
  'image/png' => '$base.png',
  'image/heic' => '$base.heic',
  _ => '$base.jpg',
};

/// The signed-in user's own account.
class UserRepository {
  UserRepository(this._api);

  final ApiClient _api;

  /// The user's profile. The server also copies a changed name or email into their groups.
  Future<Me> me() async => Me.fromJson(await _api.get('/me'));

  /// Uploads a screenshot of the user's bank "receive money" QR, which bill guests can scan.
  /// Returns a download URL for it.
  Future<String?> uploadPayQr(List<int> bytes, {required String contentType}) async {
    final signed = PresignedPost.fromJson(await _api.post('/me/pay-qr-url', data: {'contentType': contentType}));
    await _api.postPresigned(signed, bytes, contentType: contentType, filename: _filename('qr', contentType));
    final saved = await _api.put('/me/pay-qr', data: {'key': signed.key});
    return saved['payQrUrl'] as String?;
  }

  /// Deletes the account: leaves every group, deletes the user's bills and their Cognito user.
  /// Fails with `BALANCES_NOT_ZERO`, listing the groups in `details`, while any balance isn't zero.
  Future<void> deleteAccount() async {
    await _api.delete('/me');
  }
}

/// Groups, their members and the invites they send.
class GroupsRepository {
  GroupsRepository(this._api);

  final ApiClient _api;

  /// One page of the user's groups.
  Future<CursorPage<Group>> list({String? cursor, int limit = 50}) async =>
      CursorPage.fromJson(await _api.get('/groups', query: {'limit': limit, 'cursor': ?cursor}), Group.fromJson);

  /// One group with its members and open invites. Fails with `GROUP_NOT_FOUND` for non-members.
  Future<Group> get(String id) async => Group.fromJson(await _api.get('/groups/$id'));

  /// Creates a group with the user as its only member.
  Future<Group> create({required String name, required String currency}) async =>
      Group.fromJson(await _api.post('/groups', data: {'name': name, 'currency': currency}));

  /// Renames the group.
  Future<Group> rename(String groupId, String name) async =>
      Group.fromJson(await _api.patch('/groups/$groupId', data: {'name': name}));

  /// Deletes the group for everyone. Fails with `BALANCES_NOT_ZERO` while anyone owes anything.
  Future<void> delete(String groupId) async {
    await _api.delete('/groups/$groupId');
  }

  /// Invites [email] to the group. Inviting an address twice does nothing the second time.
  /// Fails with `ALREADY_MEMBER` or `GROUP_FULL`.
  Future<Group> invite(String groupId, String email) async =>
      Group.fromJson(await _api.post('/groups/$groupId/invites', data: {'email': email}));

  /// Withdraws an invite that hasn't been accepted.
  Future<Group> cancelInvite(String groupId, String inviteId) async =>
      Group.fromJson(await _api.delete('/groups/$groupId/invites/$inviteId'));

  /// Takes the user out of the group. Fails with `BALANCE_NOT_ZERO` while they owe or are owed.
  Future<void> leave(String groupId) async {
    await _api.post('/groups/$groupId/leave');
  }

  /// Removes another member. Fails with `BALANCE_NOT_ZERO` while that member owes or is owed.
  Future<Group> removeMember(String groupId, String userId) async =>
      Group.fromJson(await _api.delete('/groups/$groupId/members/$userId'));

  /// Everyone's balance and the suggested payments to settle up.
  Future<Balances> balances(String groupId) async => Balances.fromJson(await _api.get('/groups/$groupId/balances'));
}

/// Invites addressed to the signed-in user, matched by their verified email.
class InvitesRepository {
  InvitesRepository(this._api);

  final ApiClient _api;

  /// The user's pending invites.
  Future<List<PendingInvite>> list() async {
    final page = CursorPage.fromJson(await _api.get('/invites'), PendingInvite.fromJson);
    return page.items;
  }

  /// Joins the group and returns it.
  Future<Group> accept(PendingInvite invite) async =>
      Group.fromJson(await _api.post('/groups/${invite.groupId}/invites/${invite.id}/accept'));

  /// Turns the invite down.
  Future<void> decline(PendingInvite invite) async {
    await _api.post('/groups/${invite.groupId}/invites/${invite.id}/decline');
  }
}

/// A group's expenses.
class ExpensesRepository {
  ExpensesRepository(this._api);

  final ApiClient _api;

  /// One page of the group's expenses, newest first.
  Future<ExpensePage> list(String groupId, {String? cursor, int limit = 20}) async => CursorPage.fromJson(
    await _api.get('/groups/$groupId/expenses', query: {'limit': limit, 'cursor': ?cursor}),
    Expense.fromJson,
  );

  /// Adds an expense. [body] is sent exactly as given. Reuse the same [idempotencyKey] when retrying
  /// this save, so the server can't record it twice.
  Future<Expense> create(String groupId, Map<String, dynamic> body, {required String idempotencyKey}) async =>
      Expense.fromJson(await _api.post('/groups/$groupId/expenses', data: body, idempotencyKey: idempotencyKey));

  /// Replaces an expense. [version] is the version that was edited, and the server answers
  /// `EXPENSE_CHANGED` if someone saved a newer one. Retrying the same edit is safe.
  Future<Expense> update(String groupId, String expenseId, Map<String, dynamic> body, {required int version}) async =>
      Expense.fromJson(await _api.put('/groups/$groupId/expenses/$expenseId', data: {...body, 'version': version}));

  /// Deletes an expense.
  Future<void> delete(String groupId, String expenseId) async {
    await _api.delete('/groups/$groupId/expenses/$expenseId');
  }
}

/// Recorded payments between members.
class SettlementsRepository {
  SettlementsRepository(this._api);

  final ApiClient _api;

  /// Records a payment. Reuse the same [idempotencyKey] when retrying, so it can't be recorded twice.
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

  /// One page of the group's recorded payments, newest first.
  Future<CursorPage<Settlement>> list(String groupId, {String? cursor, int limit = 20}) async => CursorPage.fromJson(
    await _api.get('/groups/$groupId/settlements', query: {'limit': limit, 'cursor': ?cursor}),
    Settlement.fromJson,
  );

  /// Deletes a payment. Only its payer or receiver may, others get `NOT_A_PARTY`.
  /// Deleting one that's already gone succeeds.
  Future<void> delete(String groupId, String settlementId) async {
    await _api.delete('/groups/$groupId/settlements/$settlementId');
  }
}

/// Receipt photos attached to expenses.
class ReceiptsRepository {
  ReceiptsRepository(this._api);

  final ApiClient _api;

  /// Gets a presigned POST from the API, uploads the photo straight to S3, then confirms it.
  /// Returns the expense with `hasReceipt` set.
  Future<Expense> upload(String groupId, String expenseId, List<int> bytes, {required String contentType}) async {
    final base = '/groups/$groupId/expenses/$expenseId';
    final signed = PresignedPost.fromJson(await _api.post('$base/receipt-url', data: {'contentType': contentType}));
    await _api.postPresigned(signed, bytes, contentType: contentType, filename: _filename('receipt', contentType));
    return Expense.fromJson(await _api.put('$base/receipt', data: {'key': signed.key}));
  }

  /// A download URL for the receipt, valid for 15 minutes.
  Future<String> viewUrl(String groupId, String expenseId) async {
    final response = await _api.get('/groups/$groupId/expenses/$expenseId/receipt-url');
    return response['url'] as String;
  }
}

/// QR bills the signed-in user hosts.
class BillsRepository {
  BillsRepository(this._api);

  final ApiClient _api;

  /// One page of the user's bills, newest first.
  Future<CursorPage<BillSummary>> list({String? cursor, int limit = 20}) async =>
      CursorPage.fromJson(await _api.get('/bills', query: {'limit': limit, 'cursor': ?cursor}), BillSummary.fromJson);

  /// One bill with its guests and totals.
  Future<Bill> get(String id) async => Bill.fromJson(await _api.get('/bills/$id'));

  /// Creates a bill. Reuse the same [idempotencyKey] when retrying, so it can't be created twice.
  Future<Bill> create(Map<String, dynamic> body, {required String idempotencyKey}) async =>
      Bill.fromJson(await _api.post('/bills', data: body, idempotencyKey: idempotencyKey));

  /// Replaces the title, lines and payment details. Safe to retry. Fails with `BILL_CLOSED` while closed.
  Future<Bill> update(String id, Map<String, dynamic> body) async =>
      Bill.fromJson(await _api.put('/bills/$id', data: body));

  /// Deletes the bill. Its guest link stops working.
  Future<void> delete(String id) async {
    await _api.delete('/bills/$id');
  }

  /// Issues a new guest link and QR. The old ones stop working.
  Future<Bill> rotateToken(String id) async => Bill.fromJson(await _api.post('/bills/$id/token'));

  /// Opens or closes the bill. Guests can't change their items while it's closed.
  Future<Bill> setOpen(String id, bool open) async =>
      Bill.fromJson(await _api.post('/bills/$id/status', data: {'status': open ? 'OPEN' : 'CLOSED'}));

  /// Updates one guest as the host. [itemIds] is the full list of their items rather than a toggle,
  /// so a retry can't flip a tick back. Send [paidCents] with `paid: true`: the amount the host saw.
  Future<Bill> updateGuest(String id, String guestId, {List<String>? itemIds, bool? paid, int? paidCents}) async {
    final body = {'itemIds': ?itemIds, 'paid': ?paid, 'paidCents': ?paidCents};
    return Bill.fromJson(await _api.put('/bills/$id/guests/$guestId', data: body));
  }

  /// Removes a guest from the bill.
  Future<Bill> removeGuest(String id, String guestId) async =>
      Bill.fromJson(await _api.delete('/bills/$id/guests/$guestId'));
}
