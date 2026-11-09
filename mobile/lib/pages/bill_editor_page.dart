// The bill editor: title, item lines and where guests should pay.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app/strings.dart';
import '../controllers/bill_editor_controller.dart';
import '../domain/money.dart';
import '../models/models.dart';
import 'widgets.dart';

/// Creates a bill, or edits the controller's `existing` one. Pops with the saved [Bill].
class BillEditorPage extends GetView<BillEditorController> {
  const BillEditorPage({super.key});

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
                  items: [for (final code in currencyCodes) DropdownMenuItem(value: code, child: Text(code))],
                  onChanged: (code) => controller.currency.value = code ?? 'MNT',
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
              Obx(() => _ErrorText(controller.fieldErrors['items'])),
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
                  dropdownMenuEntries: [for (final bank in S.banks) DropdownMenuEntry(value: bank, label: bank)],
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
              Obx(() => _ErrorText(controller.fieldErrors['payment'])),
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

/// The editable item lines, each with a name, a price and a remove button.
class _Lines extends StatelessWidget {
  const _Lines({required this.controller});

  final BillEditorController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => Column(
        children: [
          for (final (index, line) in controller.lines.indexed)
            Padding(
              // Keyed by the line, so removing one doesn't shift field state onto its neighbours.
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
                      decoration: InputDecoration(labelText: S.itemName, hintText: index == 0 ? S.itemNameHint : null),
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
                    onPressed: controller.lines.length > 1 ? () => controller.removeLine(index) : null,
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

/// The host's bank QR screenshot, with a button to upload or replace it.
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
                child: _thumbnail(context, url: url, uploading: uploading),
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

  Widget _thumbnail(BuildContext context, {required String? url, required bool uploading}) {
    final placeholder = Icon(Icons.qr_code_2, color: Theme.of(context).colorScheme.outline);
    if (uploading) return const Center(child: CircularProgressIndicator());
    if (url == null) return placeholder;
    return Image.network(
      url,
      fit: BoxFit.cover,
      cacheWidth: (72 * MediaQuery.devicePixelRatioOf(context)).round(),
      errorBuilder: (_, _, _) => placeholder,
    );
  }
}

/// A field error in red under a group of fields. Shows nothing when [message] is null.
class _ErrorText extends StatelessWidget {
  const _ErrorText(this.message);

  final String? message;

  @override
  Widget build(BuildContext context) {
    final message = this.message;
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(message, style: TextStyle(color: Theme.of(context).colorScheme.error)),
    );
  }
}
