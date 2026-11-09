// The Cognito client behind AuthService: the real one built on amazon_cognito_identity_dart_2,
// with tokens kept in secure storage.
import 'dart:async';
import 'dart:convert';

import 'package:amazon_cognito_identity_dart_2/cognito.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// One session's ID token and the claims we need from it. The API accepts only Cognito ID tokens.
class AuthTokens {
  const AuthTokens({required this.idToken, required this.userId, required this.expiresAt});

  /// The raw JWT, sent as the bearer token.
  final String idToken;

  /// The Cognito `sub`, which is also the user's id on the server.
  final String userId;

  /// When the token stops being accepted.
  final DateTime expiresAt;
}

/// The session saved on this device, read without the network.
class StoredSession {
  const StoredSession({required this.userId, this.tokens});

  /// The Cognito `sub` of the saved user.
  final String userId;

  /// The saved ID token, possibly expired. Null if it couldn't be read.
  final AuthTokens? tokens;
}

/// No refresh token is stored, so the session is over. This is different from being offline.
class SessionMissingException implements Exception {
  const SessionMissingException();
}

/// The parts of Cognito that AuthService uses. Tests pass a fake so token caching, expiry and
/// sign-out races can be checked without AWS.
///
/// Methods throw the library's own errors: [CognitoClientException] with a `code`, the
/// `CognitoUser...Exception` challenge types, [SessionMissingException], or storage errors.
abstract interface class CognitoBackend {
  /// The user saved on this device, from secure storage only. Null if nobody is signed in.
  Future<StoredSession?> restore();

  /// A valid session: the cached one, or refreshed with the refresh token when it has expired.
  Future<AuthTokens> session();

  /// New tokens from Cognito with the refresh token, even if the cached ones look valid.
  Future<AuthTokens> refresh();

  /// Signs in with a password and saves the session.
  Future<AuthTokens> signIn(String username, String password);

  /// Registers a new user. Cognito emails them a confirmation code.
  Future<void> signUp({required String username, required String password, required String name});

  /// Confirms a new account with the emailed code.
  Future<void> confirmSignUp(String username, String code);

  /// Emails the confirmation code again.
  Future<void> resendCode(String username);

  /// Emails a reset code.
  Future<void> forgotPassword(String username);

  /// Sets a new password with the emailed code.
  Future<void> confirmPassword(String username, String code, String newPassword);

  /// Forgets the session stored on this device. Never uses the network.
  Future<void> signOut();
}

/// Keeps Cognito's tokens in the iOS Keychain or Android's Keystore-backed storage instead of plain prefs.
class _SecureCognitoStorage extends CognitoStorage {
  _SecureCognitoStorage(this._storage);

  final FlutterSecureStorage _storage;
  static const _prefix = 'netzero.cognito.';

  @override
  Future<dynamic> getItem(String key) async {
    final raw = await _storage.read(key: '$_prefix$key');
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<dynamic> setItem(String key, dynamic value) async {
    await _storage.write(key: '$_prefix$key', value: jsonEncode(value));
    return value;
  }

  @override
  Future<dynamic> removeItem(String key) async {
    final old = await getItem(key);
    await _storage.delete(key: '$_prefix$key');
    return old;
  }

  @override
  Future<void> clear() async {
    final all = await _storage.readAll();
    for (final key in all.keys.where((k) => k.startsWith(_prefix))) {
      await _storage.delete(key: key);
    }
  }
}

/// Adds a timeout to every Cognito request, since the library has none. The library reports a timeout
/// as `CognitoClientException(code: 'Unknown error')`, which AuthService treats as offline.
class _TimeoutClient extends http.BaseClient {
  _TimeoutClient(this._inner, this._timeout);

  final http.Client _inner;
  final Duration _timeout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => _inner.send(request).timeout(_timeout);

  @override
  void close() => _inner.close();
}

/// The real [CognitoBackend], talking to the user pool over HTTPS.
class AmazonCognitoBackend implements CognitoBackend {
  AmazonCognitoBackend._(this._pool);

  /// Connects to the pool. [timeout] applies to every call to Cognito.
  factory AmazonCognitoBackend({
    required String userPoolId,
    required String clientId,
    Duration timeout = const Duration(seconds: 15),
  }) {
    final region = userPoolId.split('_').first;
    return AmazonCognitoBackend._(
      CognitoUserPool(
        userPoolId,
        clientId,
        storage: _SecureCognitoStorage(const FlutterSecureStorage()),
        customClient: Client(region: region, client: _TimeoutClient(http.Client(), timeout)),
      ),
    );
  }

  final CognitoUserPool _pool;
  CognitoUser? _user;

  CognitoUser _userNamed(String username) => CognitoUser(username, _pool, storage: _pool.storage);

  static AuthTokens _tokens(CognitoIdToken token) => AuthTokens(
    idToken: token.getJwtToken() ?? '',
    userId: token.getSub() ?? '',
    expiresAt: DateTime.fromMillisecondsSinceEpoch(token.getExpiration() * 1000),
  );

  static AuthTokens _fromSession(CognitoUserSession? session) {
    if (session == null) throw const SessionMissingException();
    return _tokens(session.getIdToken());
  }

  Future<String?> _storedRefreshToken(CognitoUser user) async {
    final value = await _pool.storage.getItem('${user.keyPrefix}.refreshToken');
    return value is String && value.isNotEmpty ? value : null;
  }

  @override
  Future<StoredSession?> restore() async {
    final user = await _pool.getCurrentUser();
    if (user == null || await _storedRefreshToken(user) == null) return null;
    final id = await _pool.storage.getItem('${user.keyPrefix}.idToken');
    if (id is! String) return null;
    final tokens = _tokens(CognitoIdToken(id));
    if (tokens.userId.isEmpty) return null;
    _user = user;
    return StoredSession(userId: tokens.userId, tokens: tokens);
  }

  @override
  Future<AuthTokens> session() async {
    final user = _user;
    // Without a refresh token getSession() throws a plain Exception, so we say what it means up front.
    if (user == null || await _storedRefreshToken(user) == null) throw const SessionMissingException();
    return _fromSession(await user.getSession());
  }

  @override
  Future<AuthTokens> refresh() async {
    final user = _user;
    final token = user == null ? null : await _storedRefreshToken(user);
    if (user == null || token == null) throw const SessionMissingException();
    return _fromSession(await user.refreshSession(CognitoRefreshToken(token)));
  }

  @override
  Future<AuthTokens> signIn(String username, String password) async {
    final user = _userNamed(username);
    final session = await user.authenticateUser(AuthenticationDetails(username: username, password: password));
    if (session == null) throw CognitoClientException('NoSession', code: 'NoSession');
    _user = user;
    return _fromSession(session);
  }

  @override
  Future<void> signUp({required String username, required String password, required String name}) async {
    await _pool.signUp(
      username,
      password,
      userAttributes: [
        AttributeArg(name: 'email', value: username),
        AttributeArg(name: 'name', value: name),
      ],
    );
  }

  @override
  Future<void> confirmSignUp(String username, String code) async {
    await _userNamed(username).confirmRegistration(code);
  }

  @override
  Future<void> resendCode(String username) async {
    await _userNamed(username).resendConfirmationCode();
  }

  @override
  Future<void> forgotPassword(String username) async {
    await _userNamed(username).forgotPassword();
  }

  @override
  Future<void> confirmPassword(String username, String code, String newPassword) async {
    await _userNamed(username).confirmPassword(code, newPassword);
  }

  @override
  Future<void> signOut() async {
    final user = _user;
    _user = null;
    try {
      // This is local only. It clears that user's cached tokens without calling Cognito.
      await user?.signOut();
    } on Exception {
      // Clearing storage below is what matters.
    }
    await _pool.storage.clear();
  }
}
