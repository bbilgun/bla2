// The bill page: what's been collected, the QR code to share, the host's own items and the guests.
import 'dart:async';

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

/// The choices in the app bar menu.
enum _BillAction { edit, status, newLink, delete }

/// The choices in a guest's menu.
enum _GuestAction { markPaid, markUnpaid, remove }

/// One bill as its host sees it, kept up to date while guests claim items.
class BillDetailPage extends GetView<BillDetailController> {
  const BillDetailPage({super.key});

  // Shows what the editor saved. If the user backed out, or a save's answer was lost, reloads instead.
  Future<void> _edit() async {
    final updated = await Get.toNamed<Object?>(Routes.editBillPath(controller.billId));
    if (updated is Bill) {
      controller.replace(updated);
    } else {
      await controller.load();
    }
  }

  Future<void> _onAction(BuildContext context, Bill bill, _BillAction action) async {
    switch (action) {
      case _BillAction.edit:
        await _edit();
      case _BillAction.status:
        await controller.setOpen(!bill.isOpen);
      case _BillAction.newLink:
        final confirmed = await confirmAction(
          context,
          title: S.newLinkQuestion,
          message: S.newLinkWarning,
          confirmLabel: S.newLink,
        );
        if (confirmed) await controller.rotateLink();
      case _BillAction.delete:
        final confirmed = await confirmAction(
          context,
          title: S.deleteBill,
          message: S.deleteBillQuestion,
          confirmLabel: S.delete,
        );
        if (!confirmed) return;
        final deleted = await controller.delete();
        if (deleted) Get.back<void>();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Polling stops while another page, such as the editor, covers this one.
    return RouteVisibility(
      onCovered: () => controller.setCovered(true),
      onUncovered: () => controller.setCovered(false),
      child: Scaffold(
        appBar: AppBar(
          title: Obx(() => Text(controller.bill.value?.title ?? '')),
          actions: [
            Obx(() {
              final bill = controller.bill.value;
              if (bill == null) return const SizedBox.shrink();
              return PopupMenuButton<_BillAction>(
                itemBuilder: (_) => [
                  const PopupMenuItem(value: _BillAction.edit, child: Text(S.editBill)),
                  PopupMenuItem(value: _BillAction.status, child: Text(bill.isOpen ? S.closeBill : S.reopenBill)),
                  const PopupMenuItem(value: _BillAction.newLink, child: Text(S.newLink)),
                  const PopupMenuItem(value: _BillAction.delete, child: Text(S.deleteBill)),
                ],
                onSelected: (action) => unawaited(_onAction(context, bill, action)),
              );
            }),
          ],
        ),
        body: Obx(() {
          if (controller.loading.value) return const SkeletonList(header: true, count: 3);
          final bill = controller.bill.value;
          final error = controller.error.value;
          if (bill == null) return ErrorRetry(message: error ?? S.somethingWentWrong, onRetry: controller.retry);
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
      ),
    );
  }
}

/// The QR code guests scan, with buttons to share or copy the link.
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
              // Black on white in either theme, because cameras read that best. High error correction
              // leaves room for the logo in the middle and still scans in dim light.
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
                      onPressed: () => unawaited(_share(buttonContext)),
                      icon: const Icon(Icons.ios_share),
                      label: const Text(S.shareLink),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: () => unawaited(controller.copyLink()),
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

/// What the guests owe the host and how much of it has come in, with a progress bar.
class _CollectedHero extends StatelessWidget {
  const _CollectedHero({required this.bill});

  final Bill bill;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background = dark ? Brand.emeraldBright : Brand.emerald;
    final foreground = dark ? Brand.ink : Colors.white;
    String money(int cents) => formatCents(cents, currency: bill.currency);
    // Only a ratio for the bar. Both amounts come from the server.
    final progress = bill.owedCents == 0 ? 0.0 : (bill.paidCents / bill.owedCents).clamp(0.0, 1.0);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: ShapeDecoration(
        color: background,
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(28)),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -36,
            top: -28,
            child: CustomPaint(
              size: const Size.square(190),
              painter: NetZeroMarkPainter(shape: MarkShape.none, foreground: foreground.withValues(alpha: 0.09)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(S.collected, style: text.titleSmall?.copyWith(color: foreground.withValues(alpha: 0.8))),
                const SizedBox(height: 6),
                Text(
                  money(bill.paidCents),
                  style: text.displaySmall?.copyWith(
                    color: foreground,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  '/ ${money(bill.owedCents)}',
                  style: text.titleMedium?.copyWith(color: foreground.withValues(alpha: 0.8)),
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 10,
                    color: foreground,
                    backgroundColor: foreground.withValues(alpha: 0.2),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${S.total}: ${money(bill.totalCents)}',
                  style: text.bodyMedium?.copyWith(color: foreground, fontWeight: FontWeight.w600),
                ),
                if (bill.unclaimedCents > 0)
                  Text(
                    '${S.unclaimed}: ${money(bill.unclaimedCents)}',
                    style: text.bodyMedium?.copyWith(color: foreground, fontWeight: FontWeight.w800),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The host's own items. Ticking one shares it with the guests who ticked it too.
class _MyItems extends StatelessWidget {
  const _MyItems({required this.bill, required this.controller});

  final Bill bill;
  final BillDetailController controller;

  @override
  Widget build(BuildContext context) => Obx(() => _build(context));

  Widget _build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // Includes ticks that are still on their way to the server.
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
                onChanged: bill.isOpen ? (_) => unawaited(controller.toggleMine(item.id)) : null,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(item.name),
                subtitle: Text(_claimedBy(item)),
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

  String _claimedBy(BillItem item) {
    if (item.claimedBy.isEmpty) return S.nobodyClaimed;
    final names = item.claimedBy.map((guestId) => guestId == Bill.hostGuestId ? S.you : bill.nameOf(guestId));
    return names.join(', ');
  }
}

/// Everyone who joined, what they owe, whether they paid, and a menu to mark paid or remove them.
class _Guests extends StatelessWidget {
  const _Guests({required this.bill, required this.controller});

  final Bill bill;
  final BillDetailController controller;

  Future<void> _confirmRemove(BuildContext context, BillGuest guest) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(S.removeGuestQuestion(guest.name)),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text(S.cancel)),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text(S.remove)),
        ],
      ),
    );
    if (confirmed == true) await controller.removeGuest(guest.id);
  }

  Future<void> _onAction(BuildContext context, BillGuest guest, _GuestAction action) async {
    switch (action) {
      case _GuestAction.markPaid:
        await controller.setPaid(guest, true);
      case _GuestAction.markUnpaid:
        await controller.setPaid(guest, false);
      case _GuestAction.remove:
        await _confirmRemove(context, guest);
    }
  }

  // "Paid", or the difference when the guest changed their items after being marked paid.
  Widget? _guestStatus(BillGuest guest, ColorScheme colors) {
    String money(int cents) => formatCents(cents, currency: bill.currency);
    if (guest.paidCents == 0) return null;
    if (guest.dueCents > 0) {
      return Text(
        '${S.paidShort(money(guest.paidCents))} · ${S.stillOwes(money(guest.dueCents))}',
        style: TextStyle(color: colors.error, fontWeight: FontWeight.w600),
      );
    }
    if (guest.dueCents < 0) {
      return Text(
        '${S.paidShort(money(guest.paidCents))} · ${S.paidTooMuch(money(-guest.dueCents))}',
        style: TextStyle(color: colors.tertiary, fontWeight: FontWeight.w600),
      );
    }
    return Text(
      S.paidBadge,
      style: TextStyle(color: colors.primary, fontWeight: FontWeight.w600),
    );
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
            for (final guest in guests)
              ListTile(
                leading: Initials(guest.name),
                title: Text(guest.name),
                subtitle: _guestStatus(guest, colors),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MoneyText(guest.totalCents, currency: bill.currency, style: text.titleSmall),
                    if (controller.isBusy(guest.id))
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    else
                      PopupMenuButton<_GuestAction>(
                        itemBuilder: (_) => [
                          if (!guest.paid) const PopupMenuItem(value: _GuestAction.markPaid, child: Text(S.markPaid)),
                          if (guest.paidCents > 0)
                            const PopupMenuItem(value: _GuestAction.markUnpaid, child: Text(S.markUnpaid)),
                          const PopupMenuItem(value: _GuestAction.remove, child: Text(S.remove)),
                        ],
                        onSelected: (action) => unawaited(_onAction(context, guest, action)),
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
