import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';

import '../app/strings.dart';
import '../controllers/expense_controller.dart';
import '../domain/money.dart';
import 'widgets.dart';

class ExpensePage extends GetView<ExpenseController> {
  const ExpensePage({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text(S.expense)),
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
              S.expenseMeta(
                expense.paidBy == controller.detail.myUserId ? S.you : group.nameOf(expense.paidBy),
                shortDate(expense.createdAt),
                expense.splitType.label,
              ),
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  children: [
                    for (final s in expense.splits)
                      ListTile(
                        dense: true,
                        leading: Initials(group.nameOf(s.userId), radius: 14),
                        title: Text(group.nameOf(s.userId)),
                        trailing: Text(
                          formatCents(s.amountCents, currency: group.currency),
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
                    onPressed: controller.uploading.value ? null : () => controller.attachReceipt(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: const Text(S.camera),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: controller.uploading.value ? null : () => controller.attachReceipt(ImageSource.gallery),
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
        onTap: () => Get.to<void>(() => _FullScreenImage(url)),
        child: Image.network(
          url,
          height: 260,
          width: double.infinity,
          // Decode at screen width, not the photo's 2000px: less memory, faster first paint.
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
