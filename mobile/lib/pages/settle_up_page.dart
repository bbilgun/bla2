// The settle up page: who should pay whom, recording payments, and the payment history.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app/notify.dart';
import '../app/strings.dart';
import '../controllers/settle_up_controller.dart';
import '../domain/money.dart';
import '../models/models.dart';
import 'widgets.dart';

/// The suggested payments that would settle the group, and the payments already recorded.
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
            for (final transfer in transfers)
              _TransferCard(
                transfer,
                group: group,
                controller: controller,
                onRecord: () => unawaited(_record(context, group, transfer)),
              ),
            if (history.items.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(S.recordedPayments, style: text.titleMedium),
              const SizedBox(height: 4),
              for (final settlement in history.items) _paymentRow(context, group, settlement),
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

  Widget _paymentRow(BuildContext context, Group group, Settlement settlement) {
    final Widget? deleteButton;
    if (!controller.canDelete(settlement)) {
      deleteButton = null;
    } else if (controller.deleting.contains(settlement.id)) {
      deleteButton = const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    } else {
      deleteButton = IconButton(
        tooltip: S.deletePayment,
        icon: const Icon(Icons.delete_outline),
        onPressed: () => unawaited(_delete(context, settlement)),
      );
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(
        S.transfer(controller.nameFor(group, settlement.fromUserId), controller.nameFor(group, settlement.toUserId)),
      ),
      subtitle: Text(S.date(settlement.createdAt)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(formatCents(settlement.amountCents, currency: group.currency)),
          ?deleteButton,
        ],
      ),
    );
  }

  Future<void> _delete(BuildContext context, Settlement settlement) async {
    final confirmed = await confirmAction(
      context,
      title: S.deletePayment,
      message: S.deletePaymentQuestion,
      confirmLabel: S.delete,
    );
    if (!confirmed) return;
    final message = await controller.deleteSettlement(settlement);
    if (message != null) notify(S.actionFailed, message);
  }

  Future<void> _record(BuildContext context, Group group, Transfer transfer) async {
    final cents = await showDialog<int>(
      context: context,
      builder: (_) => _AmountDialog(
        title: S.transfer(controller.nameFor(group, transfer.fromUserId), controller.nameFor(group, transfer.toUserId)),
        currency: group.currency,
        initialCents: transfer.amountCents,
      ),
    );
    if (cents == null) return;
    final message = await controller.record(transfer, cents);
    if (message != null) notify(S.notRecorded, message);
  }
}

/// One suggested payment, with a button to record it when the user is the payer or receiver.
class _TransferCard extends StatelessWidget {
  const _TransferCard(this.transfer, {required this.group, required this.controller, required this.onRecord});

  final Transfer transfer;
  final Group group;
  final SettleUpController controller;
  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Initials(group.nameOf(transfer.fromUserId), radius: 16),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.arrow_forward, size: 18)),
              Initials(group.nameOf(transfer.toUserId), radius: 16),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(controller.describe(transfer), style: text.bodyMedium),
                    MoneyText(
                      transfer.amountCents,
                      currency: group.currency,
                      style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              if (controller.canRecord(transfer))
                if (controller.isBusy(transfer))
                  const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
                else
                  FilledButton.tonal(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                    onPressed: onRecord,
                    child: const Text(S.record),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Asks how much was actually paid, starting from the suggested amount. A partial payment is fine.
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
    if (cents == null || cents <= 0) {
      setState(() => _error = S.amountHint);
      return;
    }
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
