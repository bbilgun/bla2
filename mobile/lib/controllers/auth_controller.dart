// State and actions for the sign-in, sign-up, confirm-code and password reset pages.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../app/routes.dart';
import '../app/strings.dart';
import '../repositories/repositories.dart';
import '../services/auth_service.dart';

/// One controller shared by all the auth pages, so an email typed on one page carries over to the next.
class AuthController extends GetxController {
  AuthController(this._auth);

  final AuthService _auth;

  /// Form keys, one per page, for running the field validators.
  final signInForm = GlobalKey<FormState>();
  final signUpForm = GlobalKey<FormState>();
  final confirmForm = GlobalKey<FormState>();
  final forgotForm = GlobalKey<FormState>();
  final resetForm = GlobalKey<FormState>();

  // Text fields. Sign-up and password reset have their own email and password fields.
  final email = TextEditingController();
  final password = TextEditingController();
  final name = TextEditingController();
  final newEmail = TextEditingController();
  final newPassword = TextEditingController();
  final code = TextEditingController();
  final resetEmail = TextEditingController();
  final resetCode = TextEditingController();
  final resetPassword = TextEditingController();

  /// True while a request runs. The submit buttons show a spinner.
  final loading = false.obs;

  /// The last failure, shown above the form.
  final error = RxnString();

  /// A neutral notice, such as "we sent you a code".
  final info = RxnString();

  // Kept while an account waits for its email code, so we can sign in right after confirming.
  String _pendingEmail = '';
  String _pendingPassword = '';

  /// The address the current code was sent to.
  String get pendingEmail => _pendingEmail;

  @override
  void onInit() {
    super.onInit();
    // If the session expired on its own, say so instead of just showing the form.
    if (_auth.takeExpiredNotice()) info.value = S.sessionExpired;
  }

  /// Signs in and opens the groups list. An unconfirmed account gets a fresh code and goes to the
  /// confirm page instead.
  Future<void> signIn() async {
    if (!_validate(signInForm)) return;
    await _run(() async {
      try {
        await _auth.signIn(email.text, password.text);
      } on AuthException catch (e) {
        if (!e.needsConfirmation) rethrow;
        _pendingEmail = email.text.trim();
        _pendingPassword = password.text;
        await _auth.resendCode(_pendingEmail);
        info.value = S.newCodeSent(_pendingEmail);
        unawaited(Get.toNamed<void>(Routes.confirm));
        return;
      }
      await _enterApp();
    });
  }

  /// Creates the account and goes to the confirm page.
  Future<void> signUp() async {
    if (!_validate(signUpForm)) return;
    await _run(() async {
      await _auth.signUp(name: name.text, email: newEmail.text, password: newPassword.text);
      _pendingEmail = newEmail.text.trim();
      _pendingPassword = newPassword.text;
      info.value = S.codeSent(_pendingEmail);
      unawaited(Get.toNamed<void>(Routes.confirm));
    });
  }

  /// Confirms the account with the emailed code, then signs in with the password from before.
  Future<void> confirm() async {
    if (!_validate(confirmForm)) return;
    await _run(() async {
      await _auth.confirm(_pendingEmail, code.text);
      await _auth.signIn(_pendingEmail, _pendingPassword);
      await _enterApp();
    });
  }

  /// Sends the confirmation code again.
  Future<void> resendCode() async {
    await _run(() async {
      await _auth.resendCode(_pendingEmail);
      info.value = S.codeResent;
    });
  }

  /// Opens the forgot password page, carrying over the email typed on the sign-in page.
  void openForgotPassword() {
    error.value = null;
    if (resetEmail.text.isEmpty) resetEmail.text = email.text.trim();
    unawaited(Get.toNamed<void>(Routes.forgotPassword));
  }

  /// Emails a reset code and goes to the page for entering it.
  Future<void> sendResetCode() async {
    if (!_validate(forgotForm)) return;
    await _run(() async {
      await _auth.forgotPassword(resetEmail.text);
      _pendingEmail = resetEmail.text.trim();
      info.value = S.resetCodeSent(_pendingEmail);
      unawaited(Get.toNamed<void>(Routes.resetPassword));
    });
  }

  /// Sends the reset code again.
  Future<void> resendResetCode() async {
    await _run(() async {
      await _auth.forgotPassword(_pendingEmail);
      info.value = S.codeResent;
    });
  }

  /// Sets the new password with the emailed code, then signs straight in with it.
  Future<void> setNewPassword() async {
    if (!_validate(resetForm)) return;
    await _run(() async {
      await _auth.confirmNewPassword(_pendingEmail, resetCode.text, resetPassword.text);
      await _auth.signIn(_pendingEmail, resetPassword.text);
      await _enterApp();
    });
  }

  bool _validate(GlobalKey<FormState> form) => form.currentState?.validate() ?? false;

  Future<void> _enterApp() async {
    // GET /me registers a new user on the server and keeps their name and email in groups up to date.
    try {
      if (Get.isRegistered<UserRepository>()) await Get.find<UserRepository>().me();
    } on Object {
      // Not fatal, because the groups page calls it again.
    }
    unawaited(Get.offAllNamed<void>(Routes.groups));
  }

  // Runs one auth action with the loading flag set, turning failures into [error].
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
    final fields = [email, password, name, newEmail, newPassword, code, resetEmail, resetCode, resetPassword];
    for (final field in fields) {
      field.dispose();
    }
    super.onClose();
  }
}
