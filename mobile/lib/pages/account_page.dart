import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app/strings.dart';
import '../controllers/account_controller.dart';
import 'widgets.dart';

/// Who I am, sign out, and delete my account.
class AccountPage extends GetView<AccountController> {
  const AccountPage({super.key});

  Future<void> _delete(BuildContext context) async {
    final ok = await confirmAction(
      context,
      title: S.deleteAccountQuestion,
      message: S.deleteAccountWarning,
      confirmLabel: S.deleteAccount,
    );
    if (!ok) return;
    final message = await controller.deleteAccount();
    if (message != null && context.mounted) await showMessage(context, title: S.deleteAccount, message: message);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text(S.accountTitle)),
      body: Obx(() {
        final me = controller.me.value;
        final error = controller.error.value;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (controller.loading.value)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (me != null)
              Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  leading: Initials(me.name, radius: 22),
                  title: Text(me.name, style: text.titleMedium),
                  subtitle: Text(me.email),
                ),
              )
            else if (error != null)
              InlineError(error),
            if (me != null && !me.emailVerified) ...[
              const SizedBox(height: 12),
              Text(S.emailNotVerified, style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            ],
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () => unawaited(controller.signOut()),
              icon: const Icon(Icons.logout),
              label: const Text(S.signOut),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: scheme.error),
              onPressed: controller.deleting.value ? null : () => unawaited(_delete(context)),
              icon: controller.deleting.value
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.delete_forever_outlined),
              label: const Text(S.deleteAccount),
            ),
          ],
        );
      }),
    );
  }
}
