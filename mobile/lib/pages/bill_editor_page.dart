import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app/strings.dart';
import '../controllers/bill_editor_controller.dart';
import '../domain/money.dart';
import 'widgets.dart';

class BillEditorPage extends GetView<BillEditorController> {
  const BillEditorPage({super.key});

  /// Returns the saved bill to the page that opened it, which reloads either way.
  Future<void> _save() async {
    final bill = await controller.save();
    if (bill != null) Get.back<Object?>(result: bill);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final closed = controller.existing?.isOpen == false;
    return FormPopScope(
      saving: () => controller.saving.value,
      isDirty: () => controller.isDirty,
      child: Scaffold(
        appBar: AppBar(title: Text(controller.isEditing ? S.editBill : S.newBill)),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (closed) ...[const InlineError(S.reopenToEdit), const SizedBox(height: 12)],
              Obx(
                () => TextField(
                  controller: controller.title,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: S.billTitle,
                    hintText: S.billTitleHint,
                    errorText: controller.fieldErrors['title'],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Obx(
                () => DropdownButtonFormField<String>(
                  initialValue: controller.currency.value,
                  decoration: const InputDecoration(labelText: S.currency),
                  items: [for (final c in currencyCodes) DropdownMenuItem(value: c, child: Text(c))],
                  onChanged: (v) => controller.currency.value = v ?? 'MNT',
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(child: Text(S.items, style: text.titleMedium)),
                  Obx(
                    () => Text(
                      S.itemsTotal(formatCents(controller.totalCents, currency: controller.currency.value)),
                      style: text.titleSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              _Lines(controller: controller),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: controller.addLine,
                  icon: const Icon(Icons.add),
                  label: const Text(S.addItem),
                ),
              ),
              Obx(() {
                final e = controller.fieldErrors['items'];
                return e == null ? const SizedBox.shrink() : _ErrorText(e);
              }),
              const SizedBox(height: 24),
              Text(S.whereToPay, style: text.titleMedium),
              const SizedBox(height: 4),
              Text(S.whereToPayHint, style: text.bodySmall),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) => DropdownMenu<String>(
                  controller: controller.bank,
                  width: constraints.maxWidth,
                  enableFilter: true,
                  requestFocusOnTap: true,
                  label: const Text(S.bank),
                  dropdownMenuEntries: [for (final b in S.banks) DropdownMenuEntry(value: b, label: b)],
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller.accountNumber,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: S.accountNumber),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller.accountName,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: S.accountName),
              ),
              Obx(() {
                final e = controller.fieldErrors['payment'];
                return e == null ? const SizedBox.shrink() : _ErrorText(e);
              }),
              const SizedBox(height: 20),
              _PayQr(controller: controller),
              const SizedBox(height: 24),
              Obx(() => InlineError(controller.error.value)),
              const SizedBox(height: 12),
              Obx(
                () => FilledButton(
                  onPressed: controller.saving.value ? null : () => unawaited(_save()),
                  child: controller.saving.value
                      ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(controller.isEditing ? S.save : S.createBillAndQr),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Lines extends StatelessWidget {
  const _Lines({required this.controller});

  final BillEditorController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => Column(
        children: [
          for (final (i, line) in controller.lines.indexed)
            Padding(
              key: ObjectKey(line),
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: line.name,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(labelText: S.itemName, hintText: i == 0 ? S.itemNameHint : null),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 120,
                    child: TextField(
                      controller: line.price,
                      keyboardType: TextInputType.numberWithOptions(decimal: hasMinorUnits(controller.currency.value)),
                      textAlign: TextAlign.end,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: S.price,
                        suffixText: symbolAfterAmount(controller.currency.value)
                            ? currencySymbol(controller.currency.value)
                            : null,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: S.remove,
                    onPressed: controller.lines.length > 1 ? () => controller.removeLine(i) : null,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PayQr extends StatelessWidget {
  const _PayQr({required this.controller});

  final BillEditorController controller;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Obx(() {
      final url = controller.payQrUrl.value;
      final uploading = controller.uploadingQr.value;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
                clipBehavior: Clip.antiAlias,
                child: uploading
                    ? const Center(child: CircularProgressIndicator())
                    : url == null
                    ? Icon(Icons.qr_code_2, color: scheme.outline)
                    : Image.network(
                        url,
                        fit: BoxFit.cover,
                        cacheWidth: (72 * MediaQuery.devicePixelRatioOf(context)).round(),
                        errorBuilder: (_, _, _) => Icon(Icons.qr_code_2, color: scheme.outline),
                      ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(S.payQr, style: text.titleSmall),
                    const SizedBox(height: 2),
                    Text(S.payQrHint, style: text.bodySmall),
                    TextButton(
                      style: TextButton.styleFrom(padding: EdgeInsets.zero),
                      onPressed: uploading ? null : () => unawaited(controller.uploadQr()),
                      child: Text(url == null ? S.uploadQr : S.replaceQr),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(message, style: TextStyle(color: Theme.of(context).colorScheme.error)),
  );
}
