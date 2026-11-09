// The bills tab: the user's QR bills, newest first.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app/strings.dart';
import '../controllers/bills_controller.dart';
import '../controllers/groups_controller.dart';
import '../domain/money.dart';
import '../models/models.dart';
import 'widgets.dart';

/// Lists the bills the user hosts, with a button to create one.
class BillsPage extends GetView<BillsController> {
  const BillsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(S.billsTitle),
        actions: [
          // The groups tab already loads the profile, so borrow its name for the avatar.
          Obx(
            () => AccountButton(
              name: Get.isRegistered<GroupsController>() ? Get.find<GroupsController>().me.value?.name : null,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'new-bill',
        onPressed: () => unawaited(controller.create()),
        icon: const Icon(Icons.add),
        label: const Text(S.newBill),
      ),
      body: Obx(() {
        if (controller.loading.value) return const SkeletonList();
        final error = controller.error.value;
        if (error != null) return ErrorRetry(message: error, onRetry: controller.retry);
        final bills = controller.bills;
        if (bills.isEmpty) {
          return RefreshIndicator(
            onRefresh: controller.load,
            child: const ScrollableEmpty(child: _EmptyBills()),
          );
        }
        final list = controller.list;
        final autoLoad = list.shouldAutoLoad;
        return RefreshIndicator(
          onRefresh: controller.load,
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            itemCount: bills.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, index) {
              if (index == bills.length) {
                return LoadMoreFooter(
                  hasMore: list.hasMore,
                  loading: list.loadingMore,
                  onLoadMore: () => unawaited(controller.loadMore()),
                );
              }
              // Building the last row fetches the next page, after this frame so it doesn't rebuild mid-build.
              if (autoLoad && index == bills.length - 1) {
                WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(controller.loadMore()));
              }
              return _BillTile(bills[index], onTap: (id) => unawaited(controller.open(id)));
            },
          ),
        );
      }),
    );
  }
}

/// One bill in the list: title, date, status, total and how many guests have paid.
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
                      '${S.date(bill.createdAt)} · ${bill.isOpen ? S.billOpen : S.billClosed}',
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

/// What the tab shows before the first bill, explaining what bills are for.
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
