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
                                  onPressed: () => _confirm(context, t),
                                  child: const Text(S.record),
                                ),
                      ],
                    ),
                  ),
                ),
              ),
            if (controller.history.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(S.recordedPayments, style: text.titleMedium),
              const SizedBox(height: 4),
              for (final s in controller.history)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    S.transfer(controller.nameFor(group, s.fromUserId), controller.nameFor(group, s.toUserId)),
                  ),
                  subtitle: Text(shortDate(s.createdAt)),
                  trailing: Text(formatCents(s.amountCents, currency: group.currency)),
                ),
            ],
          ],
        );
      }),
    );
  }

  Future<void> _confirm(BuildContext context, Transfer t) async {
    final group = controller.detail.group.value!;
    final amount = TextEditingController(text: centsToInput(t.amountCents));
    String? error;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(S.transfer(controller.nameFor(group, t.fromUserId), controller.nameFor(group, t.toUserId))),
          content: TextField(
            controller: amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: S.amount, errorText: error, helperText: S.partialPaymentHelper),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text(S.cancel)),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(88, 40)),
              onPressed: () async {
                final cents = tryParseCents(amount.text);
                if (cents == null || cents <= 0) return setState(() => error = S.amountHint);
                Navigator.of(ctx).pop();
                final message = await controller.record(t, cents);
                if (message != null) Get.snackbar(S.notRecorded, message, snackPosition: SnackPosition.BOTTOM);
              },
              child: const Text(S.recordPayment),
            ),
          ],
        ),
      ),
    );
  }
}
