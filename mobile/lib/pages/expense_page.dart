// The expense detail page: amount, splits and receipt, with edit and delete.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';

import '../app/strings.dart';
import '../controllers/expense_controller.dart';
import '../domain/money.dart';
import '../models/models.dart';
import 'widgets.dart';

/// One expense: who paid, how it's split, and the receipt photo.
class ExpensePage extends GetView<ExpenseController> {
  const ExpensePage({super.key});

  Future<void> _delete(BuildContext context) async {
    final confirmed = await confirmAction(
      context,
      title: S.deleteExpense,
      message: S.deleteExpenseQuestion,
      confirmLabel: S.delete,
    );
    if (!confirmed) return;
    final deleted = await controller.delete();
    if (deleted) Get.back<void>();
  }

  String _nameOf(Group group, String userId) => userId == controller.detail.myUserId ? S.you : group.nameOf(userId);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text(S.expense),
        actions: [
          Obx(() {
            final busy = controller.expense == null || controller.deleting.value || controller.uploading.value;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: S.editExpense,
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: busy ? null : () => unawaited(controller.edit()),
                ),
                IconButton(
                  tooltip: S.deleteExpense,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: busy ? null : () => unawaited(_delete(context)),
                ),
              ],
            );
          }),
        ],
      ),
      body: Obx(() {
        final expense = controller.expense;
        final group = controller.detail.group.value;
        if (expense == null || group == null) return const Center(child: Text(S.expenseNotFound));
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Text(expense.description, style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            MoneyText(
              expense.amountCents,
              currency: group.currency,
              style: text.displaySmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              S.expenseMeta(_nameOf(group, expense.paidBy), S.date(expense.createdAt), expense.splitType.label),
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (expense.updatedAt != null && expense.updatedBy != null)
              Text(
                S.editedBy(_nameOf(group, expense.updatedBy!), S.date(expense.updatedAt!)),
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  children: [
                    for (final split in expense.splits)
                      ListTile(
                        dense: true,
                        leading: Initials(group.nameOf(split.userId), radius: 14),
                        title: Text(group.nameOf(split.userId)),
                        trailing: Text(
                          formatCents(split.amountCents, currency: group.currency),
                          style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(S.receipt, style: text.titleMedium),
            const SizedBox(height: 8),
            _receipt(context),
            const SizedBox(height: 12),
            InlineError(controller.error.value),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: controller.uploading.value
                        ? null
                        : () => unawaited(controller.attachReceipt(ImageSource.camera)),
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: const Text(S.camera),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: controller.uploading.value
                        ? null
                        : () => unawaited(controller.attachReceipt(ImageSource.gallery)),
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text(S.photos),
                  ),
                ),
              ],
            ),
          ],
        );
      }),
    );
  }

  // The receipt area: a spinner while loading or uploading, a placeholder, or the photo.
  Widget _receipt(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final box = BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(16));
    if (controller.uploading.value || controller.loadingReceipt.value) {
      return Container(
        height: 220,
        decoration: box,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(controller.uploading.value ? S.uploading : S.loading),
          ],
        ),
      );
    }
    final url = controller.receiptUrl.value;
    if (url == null) {
      return Container(
        height: 120,
        decoration: box,
        alignment: Alignment.center,
        child: Text(S.noReceiptYet, style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: GestureDetector(
        onTap: () => unawaited(Get.to<void>(() => _FullScreenImage(url))),
        child: Image.network(
          url,
          height: 260,
          width: double.infinity,
          // Decode at screen width rather than the photo's 2000px, which saves memory and paints sooner.
          cacheWidth: (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context)).round(),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Container(
            height: 120,
            decoration: box,
            alignment: Alignment.center,
            child: TextButton(onPressed: controller.loadReceipt, child: const Text(S.couldNotLoadReceipt)),
          ),
        ),
      ),
    );
  }
}

/// The receipt on black, with pinch to zoom.
class _FullScreenImage extends StatelessWidget {
  const _FullScreenImage(this.url);

  final String url;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: Center(child: InteractiveViewer(child: Image.network(url))),
    );
  }
}
