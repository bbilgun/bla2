// Shared fakes for controller and service tests. No network, no AWS, no widget tree.
import 'dart:async';

import 'package:netzero/app/notify.dart';
import 'package:netzero/models/models.dart';
import 'package:netzero/repositories/repositories.dart';
import 'package:netzero/services/api_client.dart';
import 'package:netzero/services/cognito_backend.dart';

/// Snackbars shown during a test, as "title: message".
final shown = <String>[];

/// Call in setUp: controllers' snackbars go to [shown] instead of a GetX overlay.
void recordNotifications() {
  shown.clear();
  notifier = (title, message) => shown.add(message.isEmpty ? title : '$title: $message');
}

ApiException networkError() => ApiException(code: 'NETWORK', message: 'offline');

ApiException apiError(String code, {int status = 409, List<Object?> details = const []}) =>
    ApiException(code: code, message: code, status: status, details: details);

// ---------------------------------------------------------------- Cognito

AuthTokens tokens(String idToken, {String user = 'user-a', required DateTime expires}) =>
    AuthTokens(idToken: idToken, userId: user, expiresAt: expires);

/// Cognito, scripted. Each call runs the matching handler; tests replace handlers to make calls
/// slow (a Completer), fail, or answer for another user. [log] records the order of events.
class FakeCognito implements CognitoBackend {
  FakeCognito({this.stored, required this.now});

  StoredSession? stored;
  final DateTime Function() now;
  final log = <String>[];
  int sessionCalls = 0;
  int refreshCalls = 0;
  int signOutCalls = 0;

  late Future<AuthTokens> Function() onSession = () async => tokens('t-session', expires: now().add(_hour));
  late Future<AuthTokens> Function() onRefresh = () async => tokens('t-refreshed', expires: now().add(_hour));
  late Future<AuthTokens> Function(String username, String password) onSignIn = (username, _) async =>
      tokens('t-$username', user: 'sub-$username', expires: now().add(_hour));
  Future<void> Function(String username)? onForgotPassword;

  static const _hour = Duration(hours: 1);

  @override
  Future<StoredSession?> restore() async => stored;

  @override
  Future<AuthTokens> session() async {
    sessionCalls++;
    log.add('session');
    final t = await onSession();
    log.add('session done');
    return t;
  }

  @override
  Future<AuthTokens> refresh() async {
    refreshCalls++;
    log.add('refresh');
    final t = await onRefresh();
    log.add('refresh done');
    return t;
  }

  @override
  Future<AuthTokens> signIn(String username, String password) async {
    log.add('signIn $username');
    return onSignIn(username, password);
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    log.add('signOut');
  }

  @override
  Future<void> forgotPassword(String username) async {
    log.add('forgotPassword $username');
    await onForgotPassword?.call(username);
  }

  @override
  Future<void> confirmPassword(String username, String code, String newPassword) async =>
      log.add('confirmPassword $username $code');

  @override
  Future<void> signUp({required String username, required String password, required String name}) async =>
      log.add('signUp $username');

  @override
  Future<void> confirmSignUp(String username, String code) async => log.add('confirmSignUp $username');

  @override
  Future<void> resendCode(String username) async => log.add('resendCode $username');
}

// ---------------------------------------------------------------- models

const anu = Member(userId: 'a', email: 'a@x.com', name: 'Anu');
const bat = Member(userId: 'b', email: 'b@x.com', name: 'Bat');
const saraa = Member(userId: 'c', email: 'c@x.com', name: 'Saraa');

Group groupOf({
  String id = 'g1',
  String name = 'Flat',
  String currency = 'USD',
  List<Member> members = const [anu, bat, saraa],
  List<GroupInvite> invites = const [],
}) => Group(
  id: id,
  name: name,
  currency: currency,
  members: members,
  invites: invites,
  createdAt: DateTime.utc(2026, 11, 1),
);

Expense expenseOf(
  String id, {
  String groupId = 'g1',
  int amountCents = 9000,
  String paidBy = 'a',
  SplitType splitType = SplitType.even,
  List<Split>? splits,
  int version = 1,
  String description = 'Dinner',
}) => Expense(
  id: id,
  groupId: groupId,
  description: description,
  amountCents: amountCents,
  paidBy: paidBy,
  splitType: splitType,
  splits:
      splits ??
      const [
        Split(userId: 'a', amountCents: 3000),
        Split(userId: 'b', amountCents: 3000),
        Split(userId: 'c', amountCents: 3000),
      ],
  hasReceipt: false,
  createdAt: DateTime.utc(2026, 11, 5),
  version: version,
);

const emptyBalances = Balances(currency: 'USD', balances: [], transfers: []);

// ---------------------------------------------------------------- repositories

/// Groups, scripted per call.
class FakeGroups implements GroupsRepository {
  FakeGroups({Group? group}) : group = group ?? groupOf();

  Group group;
  Balances balancesResult = emptyBalances;
  int balanceCalls = 0;
  int getCalls = 0;
  final calls = <String>[];

  /// Set to make the next matching write fail.
  ApiException? failWith;

  Future<T> _write<T>(String call, T Function() result) async {
    calls.add(call);
    final error = failWith;
    if (error != null) {
      failWith = null;
      throw error;
    }
    return result();
  }

  @override
  Future<Group> get(String id) async {
    getCalls++;
    return group;
  }

  @override
  Future<Balances> balances(String groupId) async {
    balanceCalls++;
    return balancesResult;
  }

  @override
  Future<Group> invite(String groupId, String email) => _write('invite $email', () {
    group = groupOf(
      invites: [
        ...group.invites,
        GroupInvite(id: 'inv-$email', email: email, invitedBy: 'a', createdAt: DateTime.utc(2026, 11, 9)),
      ],
    );
    return group;
  });

  @override
  Future<Group> cancelInvite(String groupId, String inviteId) => _write('cancel $inviteId', () {
    group = groupOf(invites: [...group.invites.where((i) => i.id != inviteId)]);
    return group;
  });

  @override
  Future<Group> removeMember(String groupId, String userId) => _write('remove $userId', () {
    group = groupOf(members: [...group.members.where((m) => m.userId != userId)]);
    return group;
  });

  @override
  Future<Group> rename(String groupId, String name) => _write('rename $name', () => group = groupOf(name: name));

  @override
  Future<void> leave(String groupId) => _write('leave', () {});

  @override
  Future<void> delete(String groupId) => _write('delete', () {});

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

/// Expense pages served from a list in pages of [pageSize]; each list() can be held with [gate].
class FakeExpenses implements ExpensesRepository {
  FakeExpenses(this.all, {this.pageSize = 2});

  List<Expense> all;
  final int pageSize;
  final listCalls = <String?>[];
  final updates = <({String id, Map<String, dynamic> body, int version})>[];
  final deletes = <String>[];

  /// When set, list() waits for it (so a test can interleave calls).
  Completer<void>? gate;

  /// When set, the next list() with a cursor fails with it.
  ApiException? failNextPage;
  ApiException? failUpdate;
  ApiException? failDelete;

  @override
  Future<ExpensePage> list(String groupId, {String? cursor, int limit = 20}) async {
    listCalls.add(cursor);
    final waitFor = gate;
    final snapshot = [...all]; // what the server had when the request arrived
    if (waitFor != null) await waitFor.future;
    final error = failNextPage;
    if (cursor != null && error != null) {
      failNextPage = null;
      throw error;
    }
    // The app's default page (20) is shrunk to [pageSize] so a few expenses make several pages.
    final size = limit == 20 ? pageSize : limit;
    final start = cursor == null ? 0 : snapshot.indexWhere((e) => e.id == cursor) + 1;
    final items = snapshot.skip(start).take(size).toList();
    final end = start + items.length;
    return ExpensePage(items: items, nextCursor: end < snapshot.length ? items.last.id : null);
  }

  @override
  Future<Expense> update(String groupId, String expenseId, Map<String, dynamic> body, {required int version}) async {
    updates.add((id: expenseId, body: body, version: version));
    final error = failUpdate;
    if (error != null) {
      failUpdate = null;
      throw error;
    }
    return expenseOf(
      expenseId,
      description: body['description'] as String,
      amountCents: body['amountCents'] as int,
      version: version + 1,
    );
  }

  @override
  Future<void> delete(String groupId, String expenseId) async {
    deletes.add(expenseId);
    final error = failDelete;
    if (error != null) {
      failDelete = null;
      throw error;
    }
    all = [...all.where((e) => e.id != expenseId)];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}
