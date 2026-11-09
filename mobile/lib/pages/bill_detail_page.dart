import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../app/brand.dart';
import '../app/routes.dart';
import '../app/strings.dart';
import '../controllers/bill_detail_controller.dart';
import '../domain/money.dart';
import '../models/models.dart';
import 'widgets.dart';

class BillDetailPage extends GetView<BillDetailController> {
  const BillDetailPage({super.key});

  Future<void> _edit() async {
    final updated = await Get.toNamed(Routes.editBillPath(controller.billId));
    if (updated is Bill) controller.replace(updated);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Obx(() => Text(controller.bill.value?.title ?? '')),
        actions: [
          Obx(() {
            final bill = controller.bill.value;
            if (bill == null) return const SizedBox.shrink();
            return PopupMenuButton<String>(
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text(S.editBill)),
                PopupMenuItem(value: 'status', child: Text(bill.isOpen ? S.closeBill : S.reopenBill)),
              ],
              onSelected: (v) => v == 'edit' ? _edit() : controller.setOpen(!bill.isOpen),
            );
          }),
        ],
      ),
      body: Obx(() {
        if (controller.loading.value) return const SkeletonList(header: true, count: 3);
        final bill = controller.bill.value;
        final error = controller.error.value;
        if (bill == null) return ErrorRetry(message: error ?? S.somethingWentWrong, onRetry: controller.load);
        return RefreshIndicator(
          onRefresh: controller.load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (!bill.isOpen) ...[const InlineError(S.closedBanner), const SizedBox(height: 12)],
              _CollectedHero(bill: bill),
              const SizedBox(height: 12),
              _QrCard(bill: bill, controller: controller),
              const SizedBox(height: 12),
              _MyItems(bill: bill, controller: controller),
              const SizedBox(height: 12),
              _Guests(bill: bill, controller: controller),
            ],
          ),
        );
      }),
    );
  }
}

class _QrCard extends StatelessWidget {
  const _QrCard({required this.bill, required this.controller});

  final Bill bill;
  final BillDetailController controller;

  Future<void> _share(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        text: S.shareText(bill.title, bill.url),
        subject: bill.title,
        // iPad shows the share sheet as a popover and needs to know where to point it.
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
              // Black on white whatever the theme: cameras read that best.
              // High error correction leaves room for the logo in the middle and still scans in dim light.
              child: QrImageView(
                data: bill.url,
                size: 220,
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.H,
                eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Brand.ink),
                dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Brand.ink),
                embeddedImage: const AssetImage('assets/brand/mark.png'),
                embeddedImageStyle: const QrEmbeddedImageStyle(size: Size.square(44)),
              ),
            ),
            const SizedBox(height: 12),
            Text(S.scanToJoin, textAlign: TextAlign.center, style: text.bodyMedium),
            const SizedBox(height: 4),
            Text(S.transferNote(bill.code), style: text.bodySmall),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Builder(
                    builder: (buttonContext) => FilledButton.icon(
                      onPressed: () => _share(buttonContext),
                      icon: const Icon(Icons.ios_share),
                      label: const Text(S.shareLink),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: controller.copyLink,
                  icon: const Icon(Icons.link),
                  label: const Text(S.copyLink),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// What the guests owe you and how much of it has come in, as a bar.
class _CollectedHero extends StatelessWidget {
  const _CollectedHero({required this.bill});

  final Bill bill;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? Brand.emeraldBright : Brand.emerald;
    final fg = dark ? Brand.ink : Colors.white;
    String money(int c) => formatCents(c, currency: bill.currency);
    // A display ratio for the bar, not money math: both numbers come from the server.
    final progress = bill.owedCents == 0 ? 0.0 : (bill.paidCents / bill.owedCents).clamp(0.0, 1.0);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: ShapeDecoration(
        color: bg,
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(28)),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -36,
            top: -28,
            child: CustomPaint(
              size: const Size.square(190),
              painter: NetZeroMarkPainter(shape: MarkShape.none, foreground: fg.withValues(alpha: 0.09)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(S.collected, style: text.titleSmall?.copyWith(color: fg.withValues(alpha: 0.8))),
                const SizedBox(height: 6),
                Text(
                  money(bill.paidCents),
                  style: text.displaySmall?.copyWith(color: fg, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
                Text('/ ${money(bill.owedCents)}', style: text.titleMedium?.copyWith(color: fg.withValues(alpha: 0.8))),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 10,
                    color: fg,
                    backgroundColor: fg.withValues(alpha: 0.2),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${S.total}: ${money(bill.totalCents)}',
                  style: text.bodyMedium?.copyWith(color: fg, fontWeight: FontWeight.w600),
                ),
                if (bill.unclaimedCents > 0)
                  Text(
                    '${S.unclaimed}: ${money(bill.unclaimedCents)}',
                    style: text.bodyMedium?.copyWith(color: fg, fontWeight: FontWeight.w800),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MyItems extends StatelessWidget {
  const _MyItems({required this.bill, required this.controller});

  final Bill bill;
  final BillDetailController controller;

  // Own Obx: the page's Obx doesn't track the busy set read here.
  @override
  Widget build(BuildContext context) => Obx(() => _build(context));

  Widget _build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // Optimistic: shows the tick before the server answers (see BillDetailController.toggleMine).
    final mine = controller.myItemIds;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(S.myItems, style: text.titleMedium),
                  const SizedBox(height: 2),
                  Text(S.myItemsHint, style: text.bodySmall),
                ],
              ),
            ),
            const SizedBox(height: 4),
            for (final item in bill.items)
              CheckboxListTile(
                value: mine.contains(item.id),
                onChanged: bill.isOpen ? (_) => controller.toggleMine(item.id) : null,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(item.name),
                subtitle: Text(
                  item.claimedBy.isEmpty
                      ? S.nobodyClaimed
                      : item.claimedBy.map((id) => id == Bill.hostGuestId ? S.you : bill.nameOf(id)).join(', '),
                ),
                secondary: Text(
                  formatCents(item.priceCents, currency: bill.currency),
                  style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Guests extends StatelessWidget {
  const _Guests({required this.bill, required this.controller});

  final Bill bill;
  final BillDetailController controller;

  Future<void> _confirmRemove(BuildContext context, BillGuest guest) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(S.removeGuestQuestion(guest.name)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text(S.cancel)),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text(S.remove)),
        ],
      ),
    );
    if (ok == true) await controller.removeGuest(guest.id);
  }

  @override
  Widget build(BuildContext context) => Obx(() => _build(context));

  Widget _build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final guests = bill.others;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(S.guests, style: text.titleMedium),
            ),
            if (guests.isEmpty) const Padding(padding: EdgeInsets.fromLTRB(20, 8, 20, 4), child: Text(S.noGuestsYet)),
            for (final g in guests)
              ListTile(
                leading: Initials(g.name),
                title: Text(g.name),
                subtitle: g.paid
                    ? Text(
                        S.paidBadge,
                        style: TextStyle(color: colors.primary, fontWeight: FontWeight.w600),
                      )
                    : null,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MoneyText(g.totalCents, currency: bill.currency, style: text.titleSmall),
                    controller.isBusy(g.id)
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                          )
                        : PopupMenuButton<String>(
                            itemBuilder: (_) => [
                              PopupMenuItem(value: 'paid', child: Text(g.paid ? S.markUnpaid : S.markPaid)),
                              const PopupMenuItem(value: 'remove', child: Text(S.remove)),
                            ],
                            onSelected: (v) =>
                                v == 'paid' ? controller.setPaid(g.id, !g.paid) : _confirmRemove(context, g),
                          ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
