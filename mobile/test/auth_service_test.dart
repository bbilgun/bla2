// AuthService: restoring a session, the token cache and refresh, sign-out races, and error text.
import 'dart:async';

import 'package:amazon_cognito_identity_dart_2/cognito.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netzero/app/strings.dart';
import 'package:netzero/services/api_client.dart';
import 'package:netzero/services/auth_service.dart';
import 'package:netzero/services/cognito_backend.dart';

import 'fakes.dart';

void main() {
  late DateTime now;
  late FakeCognito cognito;
  late AuthService auth;

  DateTime clock() => now;

  setUp(() {
    now = DateTime(2026, 11, 9, 12);
    cognito = FakeCognito(now: clock);
    auth = AuthService(cognito, clock: clock);
  });

  Future<void> restoreAs(String userId, {required Duration validFor}) async {
    cognito.stored = StoredSession(
      userId: userId,
      tokens: tokens('t-stored', user: userId, expires: now.add(validFor)),
    );
    await auth.restore();
  }

  group('restore', () {
    test('a saved session signs in without the network and its token is used as is', () async {
      await restoreAs('user-a', validFor: const Duration(minutes: 30));

      expect(auth.isSignedIn, isTrue);
      expect(auth.userId, 'user-a');
      expect(await auth.idToken(), 't-stored');
      expect(cognito.sessionCalls, 0);
    });

    test('starts signed out when nothing is saved', () async {
      await auth.restore();

      expect(auth.isSignedIn, isFalse);
      expect(await auth.idToken(), isNull);
    });

    test('starts signed out when storage is unreadable', () async {
      final broken = AuthService(_ThrowingRestore(now: clock), clock: clock);

      await broken.restore();

      expect(broken.isSignedIn, isFalse);
    });
  });

  group('token cache', () {
    test('keeps a token until two minutes before it expires, then refreshes once', () async {
      await restoreAs('user-a', validFor: const Duration(minutes: 10));
      expect(await auth.idToken(), 't-stored');

      // Three minutes left.
      now = now.add(const Duration(minutes: 7));
      expect(await auth.idToken(), 't-stored');

      // One minute left.
      now = now.add(const Duration(minutes: 2));
      expect(await auth.idToken(), 't-session');
      expect(cognito.sessionCalls, 1);

      // The new token is cached.
      expect(await auth.idToken(), 't-session');
      expect(cognito.sessionCalls, 1);
    });

    test('requests that start together share one lookup', () async {
      await restoreAs('user-a', validFor: Duration.zero);
      final slow = Completer<AuthTokens>();
      cognito.onSession = () => slow.future;

      final lookups = [auth.idToken(), auth.idToken(), auth.idToken()];
      slow.complete(tokens('t-new', expires: now.add(const Duration(hours: 1))));

      expect(await Future.wait(lookups), ['t-new', 't-new', 't-new']);
      expect(cognito.sessionCalls, 1);
    });
  });

  group('errors while refreshing', () {
    for (final (name, error) in [
      ('DNS failure', CognitoClientException('SocketException', code: 'NetworkError')),
      ('any other transport error', CognitoClientException('Unknown Error', code: 'Unknown error')),
      ('a timeout', TimeoutException('slow')),
      ('a Cognito 500', CognitoClientException('boom', code: 'InternalErrorException', statusCode: 500)),
    ]) {
      test('$name is a NETWORK error that keeps the session for the next try', () async {
        await restoreAs('user-a', validFor: Duration.zero);
        cognito.onSession = () async => throw error;

        await expectLater(
          auth.idToken(),
          throwsA(
            isA<ApiException>().having((e) => e.code, 'code', 'NETWORK').having((e) => e.message, 'm', S.noConnection),
          ),
        );
        expect(auth.isSignedIn, isTrue);
        expect(cognito.signOutCalls, 0);

        cognito.onSession = () async => tokens('t-back', expires: now.add(const Duration(hours: 1)));

        expect(await auth.idToken(), 't-back');
      });
    }

    test('a revoked refresh token ends the session', () async {
      await restoreAs('user-a', validFor: Duration.zero);
      cognito.onSession = () async => throw CognitoClientException('revoked', code: 'NotAuthorizedException');

      await expectLater(auth.idToken(), throwsA(isA<SessionExpiredException>()));
    });

    test('a missing refresh token ends the session', () async {
      await restoreAs('user-a', validFor: Duration.zero);
      cognito.onSession = () async => throw const SessionMissingException();

      await expectLater(auth.idToken(), throwsA(isA<SessionExpiredException>()));
    });
  });

  group('sign-out racing a token refresh', () {
    test('sign-out waits for the refresh before clearing storage and drops its token', () async {
      await restoreAs('user-a', validFor: Duration.zero);
      final slow = Completer<AuthTokens>();
      cognito.onSession = () => slow.future;
      final lookup = auth.idToken();

      final signingOut = auth.signOut();

      // Signed out in memory at once, but storage waits for the refresh, which would save its tokens again.
      expect(auth.isSignedIn, isFalse);
      expect(cognito.signOutCalls, 0);

      slow.complete(tokens('t-stale', expires: now.add(const Duration(hours: 1))));
      await signingOut;

      expect(await lookup, isNull);
      expect(cognito.log, ['session', 'session done', 'signOut']);
      expect(await auth.idToken(), isNull);
    });

    test("a refresh for user A can't put A's token into B's session", () async {
      await restoreAs('user-a', validFor: Duration.zero);
      final slow = Completer<AuthTokens>();
      cognito.onSession = () => slow.future;
      unawaited(auth.idToken());

      // The sign-out waits on A's refresh.
      unawaited(auth.signOut());
      final signingIn = auth.signIn('B@x.com', 'Password123');
      slow.complete(tokens('t-of-a', user: 'user-a', expires: now.add(const Duration(hours: 1))));
      await signingIn;

      expect(auth.userId, 'sub-b@x.com');
      expect(await auth.idToken(), 't-b@x.com');
      // B signed in only after A's refresh finished and A's storage was cleared.
      expect(cognito.log, ['session', 'session done', 'signOut', 'signIn b@x.com']);
    });

    test('two sign-outs at once clear storage once', () async {
      await restoreAs('user-a', validFor: const Duration(hours: 1));

      await Future.wait([auth.signOut(), auth.signOut()]);

      expect(cognito.signOutCalls, 1);
    });

    test('each sign-in and sign-out starts a new generation', () async {
      final before = auth.generation;

      await auth.signIn('a@x.com', 'Password123');
      final afterSignIn = auth.generation;
      await auth.signOut();

      expect(afterSignIn, greaterThan(before));
      expect(auth.generation, greaterThan(afterSignIn));
    });
  });

  group('after a 401', () {
    test('forces one shared refresh even though the cached token looks valid', () async {
      await restoreAs('user-a', validFor: const Duration(hours: 1));
      final slow = Completer<AuthTokens>();
      cognito.onRefresh = () => slow.future;

      final first = auth.refreshAfterUnauthorized('t-stored');
      final second = auth.refreshAfterUnauthorized('t-stored');
      slow.complete(tokens('t-new', expires: now.add(const Duration(hours: 1))));

      expect(await Future.wait([first, second]), ['t-new', 't-new']);
      expect(cognito.refreshCalls, 1);
    });

    test('skips a second refresh when another request already got a new token', () async {
      await restoreAs('user-a', validFor: const Duration(hours: 1));

      expect(await auth.refreshAfterUnauthorized('t-stored'), 't-refreshed');
      expect(await auth.refreshAfterUnauthorized('t-stored'), 't-refreshed');
      expect(cognito.refreshCalls, 1);
    });
  });

  group('sign-in errors in Mongolian', () {
    test('any kind of offline reads as no connection, not a wrong password', () {
      expect(AuthService.friendlyError(CognitoClientException('x', code: 'NetworkError')), S.noConnection);
      expect(AuthService.friendlyError(CognitoClientException('x', code: 'Unknown error')), S.noConnection);
      expect(AuthService.friendlyError(TimeoutException('x')), S.noConnection);
      expect(
        AuthService.friendlyError(CognitoClientException('x', code: 'NotAuthorizedException')),
        S.wrongEmailOrPassword,
      );
    });

    test('password reset has its own wording', () {
      final notFound = CognitoClientException('x', code: 'UserNotFoundException');
      expect(AuthService.friendlyError(notFound), S.wrongEmailOrPassword);
      expect(AuthService.friendlyError(notFound, reset: true), S.noAccountForEmail);
      expect(
        AuthService.friendlyError(CognitoClientException('x', code: 'ExpiredCodeException'), reset: true),
        S.resetCodeExpired,
      );
    });

    test('an unconfirmed account asks for the email code', () async {
      cognito.onSignIn = (_, _) async => throw CognitoClientException('x', code: 'UserNotConfirmedException');

      await expectLater(
        auth.signIn('a@x.com', 'Password123'),
        throwsA(isA<AuthException>().having((e) => e.needsConfirmation, 'needsConfirmation', isTrue)),
      );
    });

    test('password reset uses the trimmed, lower-case email', () async {
      await auth.forgotPassword('  A@X.com ');
      await auth.confirmNewPassword('A@x.com', ' 123456 ', 'NewPassword1');

      expect(cognito.log, ['forgotPassword a@x.com', 'confirmPassword a@x.com 123456']);
    });
  });

  test('the session expired notice is shown once', () async {
    await restoreAs('user-a', validFor: const Duration(hours: 1));

    await auth.expireSession();

    expect(auth.isSignedIn, isFalse);
    expect(auth.takeExpiredNotice(), isTrue);
    expect(auth.takeExpiredNotice(), isFalse);
  });
}

/// A Cognito whose stored session can't be read.
class _ThrowingRestore extends FakeCognito {
  _ThrowingRestore({required super.now});

  @override
  Future<StoredSession?> restore() async => throw StateError('keychain locked');
}
