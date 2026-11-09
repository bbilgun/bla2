import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app/strings.dart';
import '../controllers/settle_up_controller.dart';
import '../domain/money.dart';
import '../models/models.dart';
import 'widgets.dart';

class SettleUpPage extends GetView<SettleUpController> {
  const SettleUpPage({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text(S.settleUp)),
      body: Obx(() {
        final group = controller.detail.group.value;
        if (group == null) return const SizedBox.shrink();
        final transfers = controller.transfers;
        final history = controller.history;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Text(transfers.isEmpty ? S.everyoneSettled : S.settleUpHint, style: text.bodyMedium),
            const SizedBox(height: 16),
            for (final t in transfers)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Initials(group.nameOf(t.fromUserId), radius: 16),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 6),
                          child: Icon(Icons.arrow_forward, size: 18),
                        ),
                        Initials(group.nameOf(t.toUserId), radius: 16),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(controller.describe(t), style: text.bodyMedium),
                              MoneyText(
                                t.amountCents,
                                currency: group.currency,
                                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ],
                          ),
                        ),
                        if (controller.canRecord(t))
                          controller.isBusy(t)
                              ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
                              : FilledButton.tonal(
                                  style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                                  onPressed: () => unawaited(_record(context, group, t)),
                                  child: const Text(S.record),
                                ),
                      ],
                    ),
                  ),
                ),
              ),
            if (history.items.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(S.recordedPayments, style: text.titleMedium),
              const SizedBox(height: 4),
              for (final s in history.items)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    S.transfer(controller.nameFor(group, s.fromUserId), controller.nameFor(group, s.toUserId)),
                  ),
                  subtitle: Text(shortDate(s.createdAt)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(formatCents(s.amountCents, currency: group.currency)),
                      if (controller.canDelete(s))
                        controller.deleting.contains(s.id)
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                              )
                            : IconButton(
                                tooltip: S.deletePayment,
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => unawaited(_delete(context, s)),
                              ),
                    ],
                  ),
                ),
              LoadMoreFooter(
                hasMore: history.hasMore,
                loading: history.loadingMore,
                onLoadMore: () => unawaited(controller.loadMoreHistory()),
              ),
            ],
          ],
        );
      }),
    );
  }

  Future<void> _delete(BuildContext context, Settlement s) async {
    final ok = await confirmAction(
      context,
      title: S.deletePayment,
      message: S.deletePaymentQuestion,
      confirmLabel: S.delete,
    );
    if (!ok) return;
    final message = await controller.deleteSettlement(s);
    if (message != null) Get.snackbar(S.actionFailed, message, snackPosition: SnackPosition.BOTTOM);
  }

  Future<void> _record(BuildContext context, Group group, Transfer t) async {
    final cents = await showDialog<int>(
      context: context,
      builder: (_) => _AmountDialog(
        title: S.transfer(controller.nameFor(group, t.fromUserId), controller.nameFor(group, t.toUserId)),
        currency: group.currency,
        initialCents: t.amountCents,
      ),
    );
    if (cents == null) return;
    final message = await controller.record(t, cents);
    if (message != null) Get.snackbar(S.notRecorded, message, snackPosition: SnackPosition.BOTTOM);
  }
}

/// The amount actually paid (a partial payment is fine). Owns (and disposes) its text controller.
class _AmountDialog extends StatefulWidget {
  const _AmountDialog({required this.title, required this.currency, required this.initialCents});

  final String title;
  final String currency;
  final int initialCents;

  @override
  State<_AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<_AmountDialog> {
  late final _amount = TextEditingController(text: centsToInput(widget.initialCents, currency: widget.currency));
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _submit() {
    final cents = tryParseCents(_amount.text, currency: widget.currency);
    if (cents == null || cents <= 0) return setState(() => _error = S.amountHint);
    Navigator.of(context).pop(cents);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _amount,
      keyboardType: TextInputType.numberWithOptions(decimal: hasMinorUnits(widget.currency)),
      decoration: InputDecoration(labelText: S.amount, errorText: _error, helperText: S.partialPaymentHelper),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text(S.cancel)),
      FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size(88, 40)),
        onPressed: _submit,
        child: const Text(S.recordPayment),
      ),
    ],
  );
}
