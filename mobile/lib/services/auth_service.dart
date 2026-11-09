import 'dart:convert';

import 'package:amazon_cognito_identity_dart_2/cognito.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';

import '../app/config.dart';
import '../app/strings.dart';

/// Thrown for anything the person should see on the sign-in screens.
class AuthException implements Exception {
  AuthException(this.message, {this.needsConfirmation = false});

  final String message;

  /// The account exists but the email code hasn't been entered yet.
  final bool needsConfirmation;

  @override
  String toString() => message;
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
    } catch (_) {
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

/// Owns the Cognito session. Everything else asks it for a fresh ID token.
class AuthService extends GetxService {
  late final CognitoUserPool _pool;
  CognitoUser? _user;

  final isSignedIn = false.obs;

  /// The signed-in user's Cognito `sub`, the same id the server uses for them.
  String? userId;

  Future<AuthService> init() async {
    _pool = CognitoUserPool(
      AppConfig.userPoolId,
      AppConfig.clientId,
      storage: _SecureCognitoStorage(const FlutterSecureStorage()),
    );
    try {
      _user = await _pool.getCurrentUser();
      final session = await _user?.getSession();
      userId = session?.getIdToken().getSub();
      isSignedIn.value = (session?.isValid() ?? false) && userId != null;
    } catch (_) {
      // Stored refresh token expired or was revoked: start signed out.
      _user = null;
      isSignedIn.value = false;
    }
    return this;
  }

  String? _token;
  DateTime _tokenExpires = DateTime.fromMillisecondsSinceEpoch(0);
  Future<String?>? _tokenLoading;

  /// A valid ID token, refreshed with the refresh token when needed. Null when signed out.
  /// The API's JWT authorizer verifies it and passes its `sub` to Lambda as the caller's identity.
  ///
  /// Kept in memory until 2 minutes before it expires: otherwise every request re-read the session
  /// from the Keychain. Requests that start together (a screen loading 3 things) share one lookup.
  Future<String?> idToken() async {
    if (_user == null) return null;
    final cached = _token;
    if (cached != null && DateTime.now().isBefore(_tokenExpires.subtract(const Duration(minutes: 2)))) {
      return cached;
    }
    return _tokenLoading ??= _loadToken().whenComplete(() => _tokenLoading = null);
  }

  Future<String?> _loadToken() async {
    final user = _user;
    if (user == null) return null;
    try {
      _remember(await user.getSession());
      return _token;
    } catch (_) {
      await signOut();
      return null;
    }
  }

  void _remember(CognitoUserSession? session) {
    final jwt = session?.getIdToken();
    _token = jwt?.getJwtToken();
    _tokenExpires = jwt == null
        ? DateTime.fromMillisecondsSinceEpoch(0)
        : DateTime.fromMillisecondsSinceEpoch(jwt.getExpiration() * 1000);
  }

  Future<void> signIn(String email, String password) async {
    final user = CognitoUser(email.trim().toLowerCase(), _pool, storage: _pool.storage);
    try {
      final session = await user.authenticateUser(
        AuthenticationDetails(username: email.trim().toLowerCase(), password: password),
      );
      _user = user;
      userId = session?.getIdToken().getSub();
      _remember(session);
      isSignedIn.value = true;
    } on CognitoUserConfirmationNecessaryException {
      throw AuthException(S.checkEmailForCode, needsConfirmation: true);
    } on CognitoUserNewPasswordRequiredException {
      throw AuthException(S.needsNewPassword);
    } on CognitoClientException catch (e) {
      throw AuthException(_friendly(e));
    }
  }

  Future<void> signUp({required String name, required String email, required String password}) async {
    try {
      await _pool.signUp(
        email.trim().toLowerCase(),
        password,
        userAttributes: [
          AttributeArg(name: 'email', value: email.trim().toLowerCase()),
          AttributeArg(name: 'name', value: name.trim()),
        ],
      );
    } on CognitoClientException catch (e) {
      throw AuthException(_friendly(e));
    }
  }

  Future<void> confirm(String email, String code) async {
    final user = CognitoUser(email.trim().toLowerCase(), _pool, storage: _pool.storage);
    try {
      await user.confirmRegistration(code.trim());
    } on CognitoClientException catch (e) {
      throw AuthException(_friendly(e));
    }
  }

  Future<void> resendCode(String email) async {
    final user = CognitoUser(email.trim().toLowerCase(), _pool, storage: _pool.storage);
    try {
      await user.resendConfirmationCode();
    } on CognitoClientException catch (e) {
      throw AuthException(_friendly(e));
    }
  }

  Future<void> signOut() async {
    try {
      await _user?.signOut();
    } catch (_) {
      // Signing out locally is what matters.
    }
    await _pool.storage.clear();
    _user = null;
    userId = null;
    _token = null;
    _tokenExpires = DateTime.fromMillisecondsSinceEpoch(0);
    isSignedIn.value = false;
  }

  String _friendly(CognitoClientException e) => switch (e.code) {
    'NotAuthorizedException' || 'UserNotFoundException' => S.wrongEmailOrPassword,
    'UsernameExistsException' => S.accountExists,
    'InvalidPasswordException' => S.passwordRules,
    'CodeMismatchException' => S.codeMismatch,
    'ExpiredCodeException' => S.codeExpired,
    'LimitExceededException' || 'TooManyRequestsException' => S.tooManyAttempts,
    'NetworkError' => S.noConnection,
    _ => S.signInFailed,
  };
}
