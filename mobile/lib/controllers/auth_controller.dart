import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../app/routes.dart';
import '../app/strings.dart';
import '../repositories/repositories.dart';
import '../services/auth_service.dart';

/// Shared by the sign-in, sign-up and confirm-code pages.
class AuthController extends GetxController {
  AuthController(this._auth);

  final AuthService _auth;

  final signInForm = GlobalKey<FormState>();
  final signUpForm = GlobalKey<FormState>();
  final confirmForm = GlobalKey<FormState>();

  final email = TextEditingController();
  final password = TextEditingController();
  final name = TextEditingController();
  final newEmail = TextEditingController();
  final newPassword = TextEditingController();
  final code = TextEditingController();

  final loading = false.obs;
  final error = RxnString();
  final info = RxnString();

  /// Set while an account waits for its email code, so we can sign in right after confirming.
  String _pendingEmail = '';
  String _pendingPassword = '';
  String get pendingEmail => _pendingEmail;

  Future<void> signIn() async {
    if (!(signInForm.currentState?.validate() ?? false)) return;
    await _run(() async {
      try {
        await _auth.signIn(email.text, password.text);
      } on AuthException catch (e) {
        if (e.needsConfirmation) {
          _pendingEmail = email.text.trim();
          _pendingPassword = password.text;
          await _auth.resendCode(_pendingEmail);
          info.value = S.newCodeSent(_pendingEmail);
          Get.toNamed(Routes.confirm);
          return;
        }
        rethrow;
      }
      await _enterApp();
    });
  }

  Future<void> signUp() async {
    if (!(signUpForm.currentState?.validate() ?? false)) return;
    await _run(() async {
      await _auth.signUp(name: name.text, email: newEmail.text, password: newPassword.text);
      _pendingEmail = newEmail.text.trim();
      _pendingPassword = newPassword.text;
      info.value = S.codeSent(_pendingEmail);
      Get.toNamed(Routes.confirm);
    });
  }

  Future<void> confirm() async {
    if (!(confirmForm.currentState?.validate() ?? false)) return;
    await _run(() async {
      await _auth.confirm(_pendingEmail, code.text);
      await _auth.signIn(_pendingEmail, _pendingPassword);
      await _enterApp();
    });
  }

  Future<void> resendCode() async {
    await _run(() async {
      await _auth.resendCode(_pendingEmail);
      info.value = S.codeResent;
    });
  }

  Future<void> _enterApp() async {
    // GET /me records this user so friends can add them to groups by email.
    try {
      await Get.find<UserRepository>().me();
    } catch (_) {
      // Not fatal: the groups page calls it again.
    }
    Get.offAllNamed(Routes.groups);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (loading.value) return;
    loading.value = true;
    error.value = null;
    try {
      await action();
    } on AuthException catch (e) {
      error.value = e.message;
    } catch (e) {
      error.value = S.somethingWentWrong;
    } finally {
      loading.value = false;
    }
  }

  @override
  void onClose() {
    for (final c in [email, password, name, newEmail, newPassword, code]) {
      c.dispose();
    }
    super.onClose();
  }
}
