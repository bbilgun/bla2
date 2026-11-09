import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:netzero/app/strings.dart';
import 'package:netzero/controllers/account_controller.dart';
import 'package:netzero/models/models.dart';
import 'package:netzero/repositories/repositories.dart';
import 'package:netzero/services/auth_service.dart';
import 'package:netzero/services/cognito_backend.dart';

import 'fakes.dart';

class FakeUsers implements UserRepository {
  Object? failDelete;
  int deletes = 0;

  @override
  Future<Me> me() async => const Me(userId: 'sub-a', email: 'a@x.com', name: 'Anu', emailVerified: true);

  @override
  Future<void> deleteAccount() async {
    deletes++;
    final error = failDelete;
    if (error != null) {
      failDelete = null;
      throw error;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeCognito cognito;
  late AuthService auth;
  late FakeUsers users;
  late AccountController c;

  setUp(() async {
    Get.testMode = true;
    recordNotifications();
    final now = DateTime(2026, 11, 9);
    cognito = FakeCognito(
      now: () => now,
      stored: StoredSession(
        userId: 'sub-a',
        tokens: tokens('t', user: 'sub-a', expires: DateTime(2026, 11, 10)),
      ),
    );
    auth = await AuthService(cognito, clock: () => now).restore();
    users = FakeUsers();
    c = AccountController(users, auth);
  });

  test('delete blocked by balances names the groups, and keeps the session', () async {
    users.failDelete = apiError(
      'BALANCES_NOT_ZERO',
      details: [
        {'groupId': 'g1', 'name': 'Байр'},
        {'groupId': 'g2', 'name': 'Аялал'},
      ],
    );
    expect(await c.deleteAccount(), S.deleteAccountBlocked(['Байр', 'Аялал']));
    expect(auth.isSignedIn, isTrue);
    expect(c.deleting.value, isFalse);
  });

  test('deleted: the local session is cleared', () async {
    expect(await c.deleteAccount(), isNull);
    expect(users.deletes, 1);
    expect(auth.isSignedIn, isFalse);
    expect(cognito.signOutCalls, 1);
    expect(shown, [S.accountDeleted]);
  });

  test('offline: says so, nothing changes', () async {
    users.failDelete = networkError();
    expect(await c.deleteAccount(), 'offline');
    expect(auth.isSignedIn, isTrue);
  });

  test('sign out', () async {
    await c.signOut();
    expect(auth.isSignedIn, isFalse);
    expect(cognito.signOutCalls, 1);
  });
}
