import 'dart:async';
import 'dart:io';

import 'package:amazon_cognito_identity_dart_2/cognito.dart';
import 'package:get/get.dart';

import '../app/strings.dart';
import 'api_exception.dart';
import 'cognito_backend.dart';

/// Thrown for anything the person should see on the sign-in screens.
class AuthException implements Exception {
  AuthException(this.message, {this.needsConfirmation = false});

  final String message;

  /// The account exists but the email code hasn't been entered yet.
  final bool needsConfirmation;

  @override
  String toString() => message;
}

/// The session is really over (refresh token revoked or missing): the person has to sign in again.
class SessionExpiredException extends ApiException {
  SessionExpiredException() : super(code: 'UNAUTHORIZED', message: S.sessionExpired, status: 401);
}

/// Owns the Cognito session. Everything else asks it for a fresh ID token.
///
/// Every sign-in and sign-out starts a new [generation]. Work that began under an older generation
/// (a token refresh, a request) can't change the current session when it finishes: a refresh started
/// for user A can't put A's token into B's session, and a 401 from A's request can't sign B out.
class AuthService extends GetxService {
  AuthService(this._cognito, {DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  final CognitoBackend _cognito;
  final DateTime Function() _now;

  /// The signed-in person's Cognito `sub`, the same id the server uses for them. Null when signed out.
  String? userId;
  bool get isSignedIn => userId != null;

  int _generation = 0;
  int get generation => _generation;

  String? _token;
  DateTime _tokenExpires = DateTime.fromMillisecondsSinceEpoch(0);
  Future<String?>? _tokenLoading;
  Future<void>? _signingOut;
  bool _expiredNotice = false;

  /// Reads the saved session from secure storage, without the network, so the app can open on the
  /// right screen at once. Tokens are refreshed later, on the first request that needs one.
  Future<AuthService> restore() async {
    try {
      final stored = await _cognito.restore();
      if (stored != null) {
        userId = stored.userId;
        final tokens = stored.tokens;
        if (tokens != null) _remember(tokens);
      }
    } on Object {
      // Unreadable storage: start signed out, and leave it as it is.
    }
    return this;
  }

  bool get _cacheFresh => _token != null && _now().isBefore(_tokenExpires.subtract(const Duration(minutes: 2)));

  /// A valid ID token, refreshed with the refresh token when needed. Null when signed out.
  /// The API's JWT authorizer verifies it and passes its `sub` to Lambda as the caller's identity.
  ///
  /// Kept in memory until 2 minutes before it expires: otherwise every request re-read the session
  /// from the Keychain. Requests that start together (a screen loading 3 things) share one lookup.
  ///
  /// Throws [SessionExpiredException] when Cognito says the session is over, and a `NETWORK`
  /// [ApiException] when Cognito can't be reached; the session is kept then, so it works again
  /// once the phone is back online.
  Future<String?> idToken() async {
    if (userId == null) return null;
    if (_cacheFresh) return _token;
    return _tokenLoading ?? _startLoad(force: false);
  }

  /// The API answered 401 to a request sent with [rejected]. Throws the cached token away and asks
  /// Cognito for a new one, once for all the requests that got that 401 together.
  /// Returns the new token, or null if the session has changed meanwhile.
  Future<String?> refreshAfterUnauthorized(String? rejected) async {
    final gen = _generation;
    if (userId == null) return null;
    final inflight = _tokenLoading;
    if (inflight != null) {
      final token = await inflight;
      if (gen != _generation) return null;
      if (token != null && token != rejected) return token;
    } else if (_cacheFresh && _token != rejected) {
      return _token; // another request already refreshed it
    }
    if (gen != _generation || userId == null) return null;
    _token = null;
    _tokenExpires = DateTime.fromMillisecondsSinceEpoch(0);
    return _tokenLoading ?? _startLoad(force: true);
  }

  Future<String?> _startLoad({required bool force}) {
    final future = _load(_generation, force: force);
    _tokenLoading = future;
    void done() {
      if (identical(_tokenLoading, future)) _tokenLoading = null;
    }

    unawaited(future.then((_) => done(), onError: (Object _) => done()));
    return future;
  }

  Future<String?> _load(int gen, {required bool force}) async {
    final AuthTokens tokens;
    try {
      tokens = await (force ? _cognito.refresh() : _cognito.session());
    } on Object catch (e) {
      if (gen != _generation) return null; // signed out meanwhile: nothing to report
      if (_sessionIsOver(e)) throw SessionExpiredException();
      throw ApiException(code: 'NETWORK', message: S.noConnection);
    }
    // A refresh that started before a sign-out or a sign-in belongs to a session that has ended.
    if (gen != _generation) return null;
    _remember(tokens);
    return tokens.idToken;
  }

  /// Only Cognito saying "no" ends a session. Being offline, timeouts and unknown errors keep it.
  static bool _sessionIsOver(Object e) =>
      e is SessionMissingException || (e is CognitoClientException && e.code == 'NotAuthorizedException');

  void _remember(AuthTokens tokens) {
    _token = tokens.idToken;
    _tokenExpires = tokens.expiresAt;
  }

  void _forget() {
    userId = null;
    _token = null;
    _tokenExpires = DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// Waits for a token lookup that's still running, so it can't write its tokens after we move on.
  Future<void> _settleInflightLoad() async {
    final inflight = _tokenLoading;
    _tokenLoading = null;
    if (inflight == null) return;
    try {
      await inflight;
    } on Object {
      // It belongs to the old session; its result doesn't matter.
    }
  }

  Future<void> signIn(String email, String password) async {
    final username = _username(email);
    await _signingOut; // a sign-out still clearing storage would wipe the tokens we're about to save
    _generation++;
    await _settleInflightLoad();
    final gen = ++_generation;
    try {
      final tokens = await _cognito.signIn(username, password);
      if (gen != _generation) return;
      userId = tokens.userId;
      _remember(tokens);
      _expiredNotice = false;
    } on CognitoUserConfirmationNecessaryException {
      throw AuthException(S.checkEmailForCode, needsConfirmation: true);
    } on CognitoUserNewPasswordRequiredException {
      throw AuthException(S.needsNewPassword);
    } on CognitoClientException catch (e) {
      if (e.code == 'UserNotConfirmedException') throw AuthException(S.checkEmailForCode, needsConfirmation: true);
      throw AuthException(friendlyError(e));
    } on Object catch (e) {
      throw AuthException(friendlyError(e));
    }
  }

  Future<void> signUp({required String name, required String email, required String password}) =>
      _guard(() => _cognito.signUp(username: _username(email), password: password, name: name.trim()));

  Future<void> confirm(String email, String code) =>
      _guard(() => _cognito.confirmSignUp(_username(email), code.trim()));

  Future<void> resendCode(String email) => _guard(() => _cognito.resendCode(_username(email)));

  /// Emails a code for setting a new password.
  Future<void> forgotPassword(String email) => _guard(() => _cognito.forgotPassword(_username(email)), reset: true);

  Future<void> confirmNewPassword(String email, String code, String newPassword) =>
      _guard(() => _cognito.confirmPassword(_username(email), code.trim(), newPassword), reset: true);

  /// Ends the session on this device. Safe to call twice at once: both wait for the same sign-out.
  Future<void> signOut() => _signingOut ??= _signOut().whenComplete(() => _signingOut = null);

  Future<void> _signOut() async {
    _generation++;
    _forget();
    // A refresh still running would save its tokens to storage after we clear it, and the app would
    // open signed in as this person next time. Let it finish first; its result is ignored.
    await _settleInflightLoad();
    try {
      await _cognito.signOut();
    } on Object {
      // Forgetting the session in memory is what matters; storage is best effort.
    }
  }

  /// The session ended on its own (the API kept saying 401). The sign-in page explains why.
  Future<void> expireSession() async {
    _expiredNotice = true;
    await signOut();
  }

  /// True once after [expireSession], so the sign-in page can say "your session expired".
  bool takeExpiredNotice() {
    final notice = _expiredNotice;
    _expiredNotice = false;
    return notice;
  }

  static String _username(String email) => email.trim().toLowerCase();

  Future<void> _guard(Future<void> Function() action, {bool reset = false}) async {
    try {
      await action();
    } on Object catch (e) {
      throw AuthException(friendlyError(e, reset: reset));
    }
  }

  /// Mongolian text for a Cognito failure. Being offline in any form (no DNS, refused connection,
  /// timeout) is "no connection", not "wrong password".
  static String friendlyError(Object e, {bool reset = false}) {
    if (e is TimeoutException || e is SocketException || e is HttpException) return S.noConnection;
    if (e is! CognitoClientException) return S.signInFailed;
    return switch (e.code) {
      // The library's own codes for a request that never got an answer.
      'NetworkError' || 'Unknown error' => S.noConnection, // not UI text: the library's codes
      'UserNotFoundException' when reset => S.noAccountForEmail,
      'InvalidParameterException' when reset => S.cannotResetUnverified,
      'NotAuthorizedException' || 'UserNotFoundException' => S.wrongEmailOrPassword,
      'UsernameExistsException' => S.accountExists,
      'InvalidPasswordException' => S.passwordRules,
      'CodeMismatchException' => S.codeMismatch,
      'ExpiredCodeException' => reset ? S.resetCodeExpired : S.codeExpired,
      'LimitExceededException' || 'TooManyRequestsException' || 'TooManyFailedAttemptsException' => S.tooManyAttempts,
      _ => S.signInFailed,
    };
  }
}
