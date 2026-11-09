import '../models/models.dart';
import '../services/api_client.dart';

/// Repositories turn API JSON into models. They are the only code that imports ApiClient,
/// the same way only your API module would import axios in a React Native app.

class UserRepository {
  UserRepository(this._api);
  final ApiClient _api;

  /// Also registers the user server-side so others can add them to groups by email.
  Future<Me> me() async => Me.fromJson(await _api.get('/me'));

  /// Uploads a screenshot of the user's bank-app "receive money" QR, shown to bill guests.
  Future<void> uploadPayQr(List<int> bytes, {required String contentType}) async {
    final signed = ReceiptUpload.fromJson(await _api.post('/me/pay-qr-url', data: {'contentType': contentType}));
    await _api.putPresigned(signed.uploadUrl, bytes, signed.headers);
  }
}

class BillsRepository {
  BillsRepository(this._api);
  final ApiClient _api;

  Future<List<BillSummary>> list() async {
    final json = await _api.get('/bills');
    return (json['items'] as List).map((b) => BillSummary.fromJson(b as Map<String, dynamic>)).toList();
  }

  Future<Bill> get(String id) async => Bill.fromJson(await _api.get('/bills/$id'));

  /// [idempotencyKey] must be reused on retries of the same create.
  Future<Bill> create(Map<String, dynamic> body, {required String idempotencyKey}) async =>
      Bill.fromJson(await _api.post('/bills', data: body, idempotencyKey: idempotencyKey));

  /// Full replace of title, lines and payment. Safe to retry as is.
  Future<Bill> update(String id, Map<String, dynamic> body) async =>
      Bill.fromJson(await _api.put('/bills/$id', data: body));

  Future<Bill> setOpen(String id, bool open) async =>
      Bill.fromJson(await _api.post('/bills/$id/status', data: {'status': open ? 'OPEN' : 'CLOSED'}));

  /// Ticks are the full list, not a toggle, so a retry can't flip them back.
  Future<Bill> updateGuest(String id, String guestId, {List<String>? itemIds, bool? paid}) async =>
      Bill.fromJson(await _api.put('/bills/$id/guests/$guestId', data: {'itemIds': ?itemIds, 'paid': ?paid}));

  Future<Bill> removeGuest(String id, String guestId) async =>
      Bill.fromJson(await _api.delete('/bills/$id/guests/$guestId'));
}

class GroupsRepository {
  GroupsRepository(this._api);
  final ApiClient _api;

  Future<List<Group>> list() async {
    final json = await _api.get('/groups');
    return (json['items'] as List).map((g) => Group.fromJson(g as Map<String, dynamic>)).toList();
  }

  Future<Group> get(String id) async => Group.fromJson(await _api.get('/groups/$id'));

  Future<Group> create({required String name, required String currency}) async =>
      Group.fromJson(await _api.post('/groups', data: {'name': name, 'currency': currency}));

  Future<Group> addMember(String groupId, String email) async =>
      Group.fromJson(await _api.post('/groups/$groupId/members', data: {'email': email}));

  Future<Balances> balances(String groupId) async => Balances.fromJson(await _api.get('/groups/$groupId/balances'));
}

class ExpensesRepository {
  ExpensesRepository(this._api);
  final ApiClient _api;

  Future<ExpensePage> list(String groupId, {String? cursor, int limit = 20}) async =>
      ExpensePage.fromJson(await _api.get('/groups/$groupId/expenses', query: {'limit': limit, 'cursor': ?cursor}));

  /// [body] is exactly what the server validates; [idempotencyKey] must be reused on retries.
  Future<Expense> create(String groupId, Map<String, dynamic> body, {required String idempotencyKey}) async =>
      Expense.fromJson(await _api.post('/groups/$groupId/expenses', data: body, idempotencyKey: idempotencyKey));
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

  Future<List<Settlement>> list(String groupId) async {
    final json = await _api.get('/groups/$groupId/settlements');
    return (json['items'] as List).map((s) => Settlement.fromJson(s as Map<String, dynamic>)).toList();
  }
}

class ReceiptsRepository {
  ReceiptsRepository(this._api);
  final ApiClient _api;

  /// Asks Lambda for a presigned PUT, then uploads the bytes straight to S3.
  Future<void> upload(String groupId, String expenseId, List<int> bytes, {required String contentType}) async {
    final signed = ReceiptUpload.fromJson(
      await _api.post('/groups/$groupId/expenses/$expenseId/receipt-url', data: {'contentType': contentType}),
    );
    await _api.putPresigned(signed.uploadUrl, bytes, signed.headers);
  }

  /// A presigned GET, valid for 15 minutes.
  Future<String> viewUrl(String groupId, String expenseId) async =>
      (await _api.get('/groups/$groupId/expenses/$expenseId/receipt-url'))['url'] as String;
}
