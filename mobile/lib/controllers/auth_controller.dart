import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../app/routes.dart';
import '../app/strings.dart';
import '../repositories/repositories.dart';
import '../services/auth_service.dart';

/// Shared by the sign-in, sign-up, confirm-code and password-reset pages.
class AuthController extends GetxController {
  AuthController(this._auth);

  final AuthService _auth;

  final signInForm = GlobalKey<FormState>();
  final signUpForm = GlobalKey<FormState>();
  final confirmForm = GlobalKey<FormState>();
  final forgotForm = GlobalKey<FormState>();
  final resetForm = GlobalKey<FormState>();

  final email = TextEditingController();
  final password = TextEditingController();
  final name = TextEditingController();
  final newEmail = TextEditingController();
  final newPassword = TextEditingController();
  final code = TextEditingController();
  final resetEmail = TextEditingController();
  final resetCode = TextEditingController();
  final resetPassword = TextEditingController();

  final loading = false.obs;
  final error = RxnString();
  final info = RxnString();

  /// Set while an account waits for its email code, so we can sign in right after confirming.
  String _pendingEmail = '';
  String _pendingPassword = '';
  String get pendingEmail => _pendingEmail;

  @override
  void onInit() {
    super.onInit();
    // We got here because the session ended on its own: say so instead of just showing the form.
    if (_auth.takeExpiredNotice()) info.value = S.sessionExpired;
  }

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
          unawaited(Get.toNamed<void>(Routes.confirm));
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
      unawaited(Get.toNamed<void>(Routes.confirm));
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

  /// "Forgot password?" on the sign-in page: carries over the email typed there.
  void openForgotPassword() {
    error.value = null;
    if (resetEmail.text.isEmpty) resetEmail.text = email.text.trim();
    unawaited(Get.toNamed<void>(Routes.forgotPassword));
  }

  Future<void> sendResetCode() async {
    if (!(forgotForm.currentState?.validate() ?? false)) return;
    await _run(() async {
      await _auth.forgotPassword(resetEmail.text);
      _pendingEmail = resetEmail.text.trim();
      info.value = S.resetCodeSent(_pendingEmail);
      unawaited(Get.toNamed<void>(Routes.resetPassword));
    });
  }

  Future<void> resendResetCode() async {
    await _run(() async {
      await _auth.forgotPassword(_pendingEmail);
      info.value = S.codeResent;
    });
  }

  /// Sets the new password with the emailed code, then signs straight in with it.
  Future<void> setNewPassword() async {
    if (!(resetForm.currentState?.validate() ?? false)) return;
    await _run(() async {
      await _auth.confirmNewPassword(_pendingEmail, resetCode.text, resetPassword.text);
      await _auth.signIn(_pendingEmail, resetPassword.text);
      await _enterApp();
    });
  }

  Future<void> _enterApp() async {
    // GET /me registers this user and keeps their name/email in groups up to date.
    try {
      if (Get.isRegistered<UserRepository>()) await Get.find<UserRepository>().me();
    } on Object {
      // Not fatal: the groups page calls it again.
    }
    unawaited(Get.offAllNamed<void>(Routes.groups));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (loading.value) return;
    loading.value = true;
    error.value = null;
    try {
      await action();
    } on AuthException catch (e) {
      error.value = e.message;
    } on Object {
      error.value = S.somethingWentWrong;
    } finally {
      loading.value = false;
    }
  }

  @override
  void onClose() {
    for (final c in [email, password, name, newEmail, newPassword, code, resetEmail, resetCode, resetPassword]) {
      c.dispose();
    }
    super.onClose();
  }
}
