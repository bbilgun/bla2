// The signed-in session: sign-in and sign-up flows, the cached ID token and its refresh.
import 'dart:async';
import 'dart:io';

import 'package:amazon_cognito_identity_dart_2/cognito.dart';
import 'package:get/get.dart';

import '../app/strings.dart';
import 'api_exception.dart';
import 'cognito_backend.dart';

/// A sign-in, sign-up or password reset failure, with a message to show on the auth screens.
class AuthException implements Exception {
  AuthException(this.message, {this.needsConfirmation = false});

  /// Mongolian text for the user.
  final String message;

  /// The account exists but the email code hasn't been entered yet.
  final bool needsConfirmation;

  @override
  String toString() => message;
}

/// The refresh token is missing or revoked, so the user has to sign in again.
class SessionExpiredException extends ApiException {
  SessionExpiredException() : super(code: 'UNAUTHORIZED', message: S.sessionExpired, status: 401);
}

/// Owns the Cognito session and hands out ID tokens to the rest of the app.
///
/// Every sign-in and sign-out bumps [generation]. Work that started under an older generation, such
/// as a token refresh or an API request, checks it when it finishes and drops its result if the
/// session has changed. That way user A's late refresh can't land in user B's session.
class AuthService extends GetxService {
  /// [clock] lets tests control token expiry.
  AuthService(this._cognito, {DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  final CognitoBackend _cognito;
  final DateTime Function() _now;

  /// The signed-in user's Cognito `sub`, which is also their id on the server. Null when signed out.
  String? userId;

  /// Whether someone is signed in on this device.
  bool get isSignedIn => userId != null;

  int _generation = 0;

  /// Counts sign-ins and sign-outs. Compare it before and after an await to tell whether the session changed.
  int get generation => _generation;

  String? _token;
  DateTime _tokenExpires = DateTime.fromMillisecondsSinceEpoch(0);
  Future<String?>? _tokenLoading;
  Future<void>? _signingOut;
  bool _expiredNotice = false;

  /// Loads the saved session from secure storage without touching the network, so the app can open
  /// on the right screen straight away. Returns this service for chaining.
  Future<AuthService> restore() async {
    try {
      final stored = await _cognito.restore();
      if (stored != null) {
        userId = stored.userId;
        final tokens = stored.tokens;
        if (tokens != null) _remember(tokens);
      }
    } on Object {
      // Storage we can't read means we start signed out. We leave the stored data alone.
    }
    return this;
  }

  bool get _cacheFresh => _token != null && _now().isBefore(_tokenExpires.subtract(const Duration(minutes: 2)));

  /// A valid ID token for the Authorization header, or null when signed out.
  ///
  /// The token is cached in memory until two minutes before it expires, so most requests never touch
  /// the Keychain. Requests that start together share one lookup.
  ///
  /// Throws [SessionExpiredException] when Cognito rejects the refresh token. Throws a `NETWORK`
  /// [ApiException] when Cognito can't be reached, and keeps the session so it works once the phone
  /// is back online.
  Future<String?> idToken() async {
    if (userId == null) return null;
    if (_cacheFresh) return _token;
    return _tokenLoading ?? _startLoad(force: false);
  }

  /// Gets a new token after the API answered 401 to a request sent with [rejected].
  ///
  /// Requests that got a 401 together share one refresh. Returns the new token, or null if the
  /// session changed while we waited.
  Future<String?> refreshAfterUnauthorized(String? rejected) async {
    final generation = _generation;
    if (userId == null) return null;
    final inflight = _tokenLoading;
    if (inflight != null) {
      final token = await inflight;
      if (generation != _generation) return null;
      if (token != null && token != rejected) return token;
    } else if (_cacheFresh && _token != rejected) {
      // Another request has already refreshed it.
      return _token;
    }
    if (generation != _generation || userId == null) return null;
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

  Future<String?> _load(int generation, {required bool force}) async {
    final AuthTokens tokens;
    try {
      tokens = await (force ? _cognito.refresh() : _cognito.session());
    } on Object catch (e) {
      // If the user signed out meanwhile, the failure belongs to a session nobody cares about.
      if (generation != _generation) return null;
      if (_sessionIsOver(e)) throw SessionExpiredException();
      throw ApiException(code: 'NETWORK', message: S.noConnection);
    }
    // A refresh that started before a sign-out or a sign-in belongs to a session that has ended.
    if (generation != _generation) return null;
    _remember(tokens);
    return tokens.idToken;
  }

  // Only Cognito saying "no" ends a session. Being offline, timeouts and unknown errors keep it.
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

  // Waits for a token lookup that's still running, so it can't write its tokens after we move on.
  Future<void> _settleInflightLoad() async {
    final inflight = _tokenLoading;
    _tokenLoading = null;
    if (inflight == null) return;
    try {
      await inflight;
    } on Object {
      // It belongs to the old session, so its result doesn't matter.
    }
  }

  /// Signs in with email and password. Throws [AuthException]. When the account still needs its
  /// email code, the exception has `needsConfirmation` set.
  Future<void> signIn(String email, String password) async {
    final username = _username(email);
    // A sign-out that is still clearing storage would wipe the tokens we're about to save.
    await _signingOut;
    // Retire the old session so a token load still running for it drops its result, wait for that
    // load, then give this sign-in a generation of its own.
    _generation++;
    await _settleInflightLoad();
    _generation++;
    final generation = _generation;
    try {
      final tokens = await _cognito.signIn(username, password);
      if (generation != _generation) return;
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

  /// Creates an account. Cognito then emails a confirmation code. Throws [AuthException].
  Future<void> signUp({required String name, required String email, required String password}) =>
      _guard(() => _cognito.signUp(username: _username(email), password: password, name: name.trim()));

  /// Confirms a new account with the emailed code. Throws [AuthException].
  Future<void> confirm(String email, String code) =>
      _guard(() => _cognito.confirmSignUp(_username(email), code.trim()));

  /// Emails the sign-up confirmation code again. Throws [AuthException].
  Future<void> resendCode(String email) => _guard(() => _cognito.resendCode(_username(email)));

  /// Emails a code for setting a new password. Throws [AuthException].
  Future<void> forgotPassword(String email) => _guard(() => _cognito.forgotPassword(_username(email)), reset: true);

  /// Sets a new password using the emailed reset code. Throws [AuthException].
  Future<void> confirmNewPassword(String email, String code, String newPassword) =>
      _guard(() => _cognito.confirmPassword(_username(email), code.trim(), newPassword), reset: true);

  /// Ends the session on this device. Calls that overlap all wait for the same sign-out.
  Future<void> signOut() => _signingOut ??= _signOut().whenComplete(() => _signingOut = null);

  Future<void> _signOut() async {
    _generation++;
    _forget();
    // A refresh still running would save its tokens after we clear storage, and the app would open
    // signed in as this user next time. Let it finish first and ignore its result.
    await _settleInflightLoad();
    try {
      await _cognito.signOut();
    } on Object {
      // Forgetting the session in memory is what matters. Clearing storage is best effort.
    }
  }

  /// Signs out because the API kept answering 401, and leaves a notice for the sign-in page.
  Future<void> expireSession() async {
    _expiredNotice = true;
    await signOut();
  }

  /// Returns true once after [expireSession], so the sign-in page can say the session expired.
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

  /// Mongolian text for a Cognito failure. Any kind of being offline reads as "no connection" rather
  /// than "wrong password". Pass [reset] for the forgot password flow, which words a few errors differently.
  static String friendlyError(Object e, {bool reset = false}) {
    if (e is TimeoutException || e is SocketException || e is HttpException) return S.noConnection;
    if (e is! CognitoClientException) return S.signInFailed;
    return switch (e.code) {
      'NetworkError' || 'Unknown error' => S.noConnection, // not UI text: the library's codes for no answer
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
