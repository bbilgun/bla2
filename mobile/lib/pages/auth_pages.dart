import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app/brand.dart';
import '../app/routes.dart';
import '../app/strings.dart';
import '../controllers/auth_controller.dart';
import 'widgets.dart';

String? _required(String? v, String message) => (v == null || v.trim().isEmpty) ? message : null;

String? _email(String? v) =>
    (v == null || !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim())) ? S.enterValidEmail : null;

String? _password(String? v) {
  if (v == null || v.length < 8) return S.passwordTooShort;
  if (!RegExp(r'[a-z]').hasMatch(v) || !RegExp(r'\d').hasMatch(v)) return S.passwordNeedsLowerAndDigit;
  return null;
}

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
            TextFormField(
              controller: controller.email,
              decoration: const InputDecoration(labelText: S.email),
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              textInputAction: TextInputAction.next,
              validator: _email,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controller.password,
              decoration: const InputDecoration(labelText: S.password),
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              onFieldSubmitted: (_) => controller.signIn(),
              validator: (v) => _required(v, S.enterPassword),
            ),
            const SizedBox(height: 16),
            Obx(() => InlineError(controller.error.value)),
            const SizedBox(height: 8),
            Obx(
              () => FilledButton(
                onPressed: controller.loading.value ? null : controller.signIn,
                child: controller.loading.value
                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text(S.signIn),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () {
                controller.error.value = null;
                Get.toNamed(Routes.signUp);
              },
              child: const Text(S.newHere),
            ),
          ],
        ),
      ),
    );
  }
}

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
              validator: (v) => _required(v, S.enterName),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controller.newEmail,
              decoration: const InputDecoration(labelText: S.email),
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              textInputAction: TextInputAction.next,
              validator: _email,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controller.newPassword,
              decoration: const InputDecoration(labelText: S.password, helperText: S.passwordHelper),
              obscureText: true,
              autofillHints: const [AutofillHints.newPassword],
              onFieldSubmitted: (_) => controller.signUp(),
              validator: _password,
            ),
            const SizedBox(height: 16),
            Obx(() => InlineError(controller.error.value)),
            const SizedBox(height: 8),
            Obx(
              () => FilledButton(
                onPressed: controller.loading.value ? null : controller.signUp,
                child: controller.loading.value
                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text(S.createAccount),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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
              onFieldSubmitted: (_) => controller.confirm(),
              validator: (v) => _required(v, S.enterCode),
            ),
            const SizedBox(height: 12),
            Obx(() {
              final info = controller.info.value;
              return info == null ? const SizedBox.shrink() : Text(info, style: Theme.of(context).textTheme.bodyMedium);
            }),
            const SizedBox(height: 12),
            Obx(() => InlineError(controller.error.value)),
            const SizedBox(height: 8),
            Obx(
              () => FilledButton(
                onPressed: controller.loading.value ? null : controller.confirm,
                child: controller.loading.value
                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text(S.confirmAndSignIn),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: controller.resendCode, child: const Text(S.resendCode)),
          ],
        ),
      ),
    );
  }
}
