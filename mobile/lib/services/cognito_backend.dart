import 'dart:async';
import 'dart:convert';

import 'package:amazon_cognito_identity_dart_2/cognito.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// The ID token of one session, decoded. The API accepts only Cognito ID tokens.
class AuthTokens {
  const AuthTokens({required this.idToken, required this.userId, required this.expiresAt});

  final String idToken;

  /// The Cognito `sub`, the same id the server uses for this person.
  final String userId;
  final DateTime expiresAt;
}

/// What's saved on this device for the last signed-in person, read without the network.
class StoredSession {
  const StoredSession({required this.userId, this.tokens});

  final String userId;

  /// The saved ID token, possibly expired. Null if it couldn't be read.
  final AuthTokens? tokens;
}

/// Nothing to refresh with: no refresh token stored. The session is over, not offline.
class SessionMissingException implements Exception {
  const SessionMissingException();
}

/// The parts of Cognito that [AuthService] uses. The real one wraps amazon_cognito_identity_dart_2;
/// tests pass a fake so token caching, expiry and sign-out races can be checked without AWS.
///
/// Errors are the library's own: [CognitoClientException] (with `code`), the
/// `CognitoUser*Exception` challenge types, [SessionMissingException], or storage errors.
abstract interface class CognitoBackend {
  /// The person saved on this device, from secure storage only. Null if nobody is signed in.
  Future<StoredSession?> restore();

  /// A valid session: the cached one, or refreshed with the refresh token when it has expired.
  Future<AuthTokens> session();

  /// New tokens from Cognito with the refresh token, even if the cached ones look valid.
  Future<AuthTokens> refresh();

  Future<AuthTokens> signIn(String username, String password);

  Future<void> signUp({required String username, required String password, required String name});

  Future<void> confirmSignUp(String username, String code);

  Future<void> resendCode(String username);

  /// Emails a reset code.
  Future<void> forgotPassword(String username);

  /// Sets a new password with the emailed code.
  Future<void> confirmPassword(String username, String code, String newPassword);

  /// Forgets the session on this device (secure storage). Never uses the network.
  Future<void> signOut();
}

/// Cognito tokens live in the Keychain (iOS) / Keystore-backed storage (Android), not plain prefs.
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

/// The Cognito library has no timeouts of its own. A request that hangs fails here instead;
/// the library reports it as `CognitoClientException(code: 'Unknown error')`, which we treat as offline.
class _TimeoutClient extends http.BaseClient {
  _TimeoutClient(this._inner, this._timeout);

  final http.Client _inner;
  final Duration _timeout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => _inner.send(request).timeout(_timeout);

  @override
  void close() => _inner.close();
}

class AmazonCognitoBackend implements CognitoBackend {
  AmazonCognitoBackend._(this._pool);

  /// [timeout] bounds every call to Cognito (sign-in, refresh, codes).
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
    // Without a refresh token getSession() can only throw a plain Exception; say what it means instead.
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
      await user?.signOut(); // local only: clears that user's cached tokens
    } on Exception {
      // Clearing storage below is what matters.
    }
    await _pool.storage.clear();
  }
}
