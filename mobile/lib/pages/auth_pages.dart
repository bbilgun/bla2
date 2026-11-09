// The sign-in, sign-up, confirm-code and password reset pages. They share one AuthController.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app/brand.dart';
import '../app/routes.dart';
import '../app/strings.dart';
import '../controllers/auth_controller.dart';
import '../domain/validators.dart';
import 'widgets.dart';

/// A page's submit button. It shows a spinner and ignores taps while a request runs.
class _Submit extends StatelessWidget {
  const _Submit({required this.controller, required this.label, required this.onPressed});

  final AuthController controller;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Obx(
    () => FilledButton(
      onPressed: controller.loading.value ? null : onPressed,
      child: controller.loading.value
          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : Text(label),
    ),
  );
}

/// The controller's neutral notice, such as "we sent a code", when there is one.
class _Info extends StatelessWidget {
  const _Info({required this.controller});

  final AuthController controller;

  @override
  Widget build(BuildContext context) => Obx(() {
    final info = controller.info.value;
    if (info == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(info, style: Theme.of(context).textTheme.bodyMedium),
    );
  });
}

/// The layout every auth page shares: the mark, a title, a subtitle and the form.
class _AuthScaffold extends StatelessWidget {
  const _AuthScaffold({required this.title, required this.subtitle, required this.child, this.showBack = false});

  final String title;
  final String subtitle;
  final Widget child;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: showBack ? AppBar() : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Align(alignment: Alignment.centerLeft, child: NetZeroMark(size: 56)),
                  const SizedBox(height: 24),
                  Text(title, style: text.headlineMedium),
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    style: text.bodyLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 28),
                  child,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Email and password sign-in, with links to sign up and to reset a forgotten password.
class SignInPage extends GetView<AuthController> {
  const SignInPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _AuthScaffold(
      title: S.appName,
      subtitle: S.tagline,
      child: Form(
        key: controller.signInForm,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Info(controller: controller),
            TextFormField(
              controller: controller.email,
              decoration: const InputDecoration(labelText: S.email),
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              textInputAction: TextInputAction.next,
              validator: validateEmail,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controller.password,
              decoration: const InputDecoration(labelText: S.password),
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              onFieldSubmitted: (_) => unawaited(controller.signIn()),
              validator: (value) => validateRequired(value, S.enterPassword),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: controller.openForgotPassword, child: const Text(S.forgotPassword)),
            ),
            const SizedBox(height: 4),
            Obx(() => InlineError(controller.error.value)),
            const SizedBox(height: 8),
            _Submit(controller: controller, label: S.signIn, onPressed: controller.signIn),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () {
                controller.error.value = null;
                unawaited(Get.toNamed<void>(Routes.signUp));
              },
              child: const Text(S.newHere),
            ),
          ],
        ),
      ),
    );
  }
}

/// Creates an account with a name, email and password.
class SignUpPage extends GetView<AuthController> {
  const SignUpPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _AuthScaffold(
      showBack: true,
      title: S.createAccountTitle,
      subtitle: S.createAccountSubtitle,
      child: Form(
        key: controller.signUpForm,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: controller.name,
              decoration: const InputDecoration(labelText: S.yourName),
              textCapitalization: TextCapitalization.words,
              autofillHints: const [AutofillHints.name],
              textInputAction: TextInputAction.next,
              validator: (value) => validateRequired(value, S.enterName),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controller.newEmail,
              decoration: const InputDecoration(labelText: S.email),
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              textInputAction: TextInputAction.next,
              validator: validateEmail,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controller.newPassword,
              decoration: const InputDecoration(labelText: S.password, helperText: S.passwordHelper, helperMaxLines: 2),
              obscureText: true,
              autofillHints: const [AutofillHints.newPassword],
              onFieldSubmitted: (_) => unawaited(controller.signUp()),
              validator: validateNewPassword,
              autovalidateMode: AutovalidateMode.onUserInteraction,
            ),
            const SizedBox(height: 16),
            Obx(() => InlineError(controller.error.value)),
            const SizedBox(height: 8),
            _Submit(controller: controller, label: S.createAccount, onPressed: controller.signUp),
          ],
        ),
      ),
    );
  }
}

/// Takes the code emailed after sign-up, then signs the user in.
class ConfirmPage extends GetView<AuthController> {
  const ConfirmPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _AuthScaffold(
      showBack: true,
      title: S.checkEmailTitle,
      subtitle: S.enterCodeSentTo(controller.pendingEmail),
      child: Form(
        key: controller.confirmForm,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: controller.code,
              decoration: const InputDecoration(labelText: S.confirmationCode),
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              onFieldSubmitted: (_) => unawaited(controller.confirm()),
              validator: (value) => validateRequired(value, S.enterCode),
            ),
            const SizedBox(height: 12),
            _Info(controller: controller),
            Obx(() => InlineError(controller.error.value)),
            const SizedBox(height: 8),
            _Submit(controller: controller, label: S.confirmAndSignIn, onPressed: controller.confirm),
            const SizedBox(height: 8),
            TextButton(onPressed: controller.resendCode, child: const Text(S.resendCode)),
          ],
        ),
      ),
    );
  }
}

/// Asks for the email to send a password reset code to.
class ForgotPasswordPage extends GetView<AuthController> {
  const ForgotPasswordPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _AuthScaffold(
      showBack: true,
      title: S.resetPasswordTitle,
      subtitle: S.resetPasswordSubtitle,
      child: Form(
        key: controller.forgotForm,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: controller.resetEmail,
              decoration: const InputDecoration(labelText: S.email),
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              onFieldSubmitted: (_) => unawaited(controller.sendResetCode()),
              validator: validateEmail,
            ),
            const SizedBox(height: 16),
            Obx(() => InlineError(controller.error.value)),
            const SizedBox(height: 8),
            _Submit(controller: controller, label: S.sendCode, onPressed: controller.sendResetCode),
          ],
        ),
      ),
    );
  }
}

/// Takes the reset code and a new password, then signs the user in.
class ResetPasswordPage extends GetView<AuthController> {
  const ResetPasswordPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _AuthScaffold(
      showBack: true,
      title: S.newPasswordTitle,
      subtitle: S.newPasswordSubtitle(controller.pendingEmail),
      child: Form(
        key: controller.resetForm,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: controller.resetCode,
              decoration: const InputDecoration(labelText: S.confirmationCode),
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              textInputAction: TextInputAction.next,
              validator: (value) => validateRequired(value, S.enterCode),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controller.resetPassword,
              decoration: const InputDecoration(
                labelText: S.newPassword,
                helperText: S.passwordHelper,
                helperMaxLines: 2,
              ),
              obscureText: true,
              autofillHints: const [AutofillHints.newPassword],
              onFieldSubmitted: (_) => unawaited(controller.setNewPassword()),
              validator: validateNewPassword,
              autovalidateMode: AutovalidateMode.onUserInteraction,
            ),
            const SizedBox(height: 12),
            _Info(controller: controller),
            Obx(() => InlineError(controller.error.value)),
            const SizedBox(height: 8),
            _Submit(controller: controller, label: S.setPasswordAndSignIn, onPressed: controller.setNewPassword),
            const SizedBox(height: 8),
            TextButton(onPressed: controller.resendResetCode, child: const Text(S.resendCode)),
          ],
        ),
      ),
    );
  }
}
