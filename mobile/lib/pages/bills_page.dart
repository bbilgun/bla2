import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app/strings.dart';
import '../controllers/bills_controller.dart';
import '../domain/money.dart';
import '../models/models.dart';
import 'widgets.dart';

class BillsPage extends GetView<BillsController> {
  const BillsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(S.billsTitle)),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'new-bill',
        onPressed: controller.create,
        icon: const Icon(Icons.add),
        label: const Text(S.newBill),
      ),
      body: Obx(() {
        if (controller.loading.value) return const SkeletonList();
        final error = controller.error.value;
        if (error != null) return ErrorRetry(message: error, onRetry: controller.load);
        if (controller.bills.isEmpty) return const _EmptyBills();
        return RefreshIndicator(
          onRefresh: controller.load,
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            itemCount: controller.bills.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, i) => _BillTile(controller.bills[i], onTap: controller.open),
          ),
        );
      }),
    );
  }
}

class _BillTile extends StatelessWidget {
  const _BillTile(this.bill, {required this.onTap});

  final BillSummary bill;
  final void Function(String id) onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final allPaid = bill.guestCount > 0 && bill.paidCount == bill.guestCount;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onTap(bill.id),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: ShapeDecoration(
                  color: bill.isOpen ? scheme.primaryContainer : scheme.surfaceContainerHigh,
                  shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Icon(
                  bill.isOpen ? Icons.qr_code_2 : Icons.lock_outline,
                  color: bill.isOpen ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(bill.title, style: text.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      '${shortDate(bill.createdAt)} · ${bill.isOpen ? S.billOpen : S.billClosed}',
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    formatCents(bill.totalCents, currency: bill.currency),
                    style: text.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    S.paidOf(bill.paidCount, bill.guestCount),
                    style: text.labelSmall?.copyWith(
                      color: allPaid ? scheme.primary : scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyBills extends StatelessWidget {
  const _EmptyBills();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.qr_code_2, size: 56, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(S.noBillsYet, style: text.titleLarge),
            const SizedBox(height: 8),
            Text(S.noBillsHint, textAlign: TextAlign.center, style: text.bodyMedium),
          ],
        ),
      ),
    );
  }
}
