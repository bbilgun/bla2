import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app/brand.dart';
import '../app/routes.dart';
import '../app/strings.dart';
import '../app/theme.dart';
import '../controllers/group_detail_controller.dart';
import '../domain/money.dart';
import '../models/models.dart';
import 'widgets.dart';

class GroupDetailPage extends GetView<GroupDetailController> {
  const GroupDetailPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Obx(() => Text(controller.group.value?.name ?? '')),
        actions: [
          IconButton(
            tooltip: S.addMember,
            icon: const Icon(Icons.person_add_alt_1_outlined),
            onPressed: () => _showAddMember(context),
          ),
        ],
      ),
      floatingActionButton: Obx(
        () => controller.group.value == null
            ? const SizedBox.shrink()
            : FloatingActionButton.extended(
                onPressed: () async {
                  final added = await Get.toNamed(Routes.addExpensePath(controller.groupId));
                  if (added == true) await controller.refreshAfterWrite();
                },
                icon: const Icon(Icons.add),
                label: const Text(S.addExpense),
              ),
      ),
      body: Obx(() {
        if (controller.loading.value) return const SkeletonList(header: true, count: 4);
        final error = controller.error.value;
        final group = controller.group.value;
        if (error != null || group == null) {
          return ErrorRetry(message: error ?? S.couldNotLoadGroup, onRetry: controller.load);
        }
        final expenses = controller.expenses;
        final hasMore = controller.hasMore;
        final loadingMore = controller.loadingMore.value;
        return RefreshIndicator(
          onRefresh: controller.refreshAfterWrite,
          // Slivers: expense rows are built lazily as they scroll into view, so a group with hundreds of
          // expenses opens as fast as one with five. The next page loads on its own near the bottom.
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                sliver: SliverList.list(
                  children: [
                    _BalanceHero(controller: controller),
                    const SizedBox(height: 12),
                    _MemberBalances(controller: controller),
                    const SizedBox(height: 28),
                    const SectionTitle(S.expenses),
                    if (expenses.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Center(child: Text(S.noExpensesYet)),
                      ),
                  ],
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList.separated(
                  itemCount: expenses.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    if (hasMore && i == expenses.length - 1) {
                      WidgetsBinding.instance.addPostFrameCallback((_) => controller.loadMore());
                    }
                    return _ExpenseTile(expense: expenses[i], group: group, me: controller.myUserId);
                  },
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 104),
                sliver: SliverToBoxAdapter(
                  child: !hasMore
                      ? const SizedBox.shrink()
                      : Center(
                          child: loadingMore
                              ? const SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2.5))
                              : TextButton(onPressed: controller.loadMore, child: const Text(S.loadMore)),
                        ),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }

  Future<void> _showAddMember(BuildContext context) async {
    final email = TextEditingController();
    String? error;
    var saving = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          Future<void> submit() async {
            setState(() {
              saving = true;
              error = null;
            });
            final message = await controller.addMember(email.text);
            if (!ctx.mounted) return;
            if (message == null) {
              Navigator.of(ctx).pop();
            } else {
              setState(() {
                saving = false;
                error = message;
              });
            }
          }

          return AlertDialog(
            title: const Text(S.addMember),
            content: TextField(
              controller: email,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: S.memberEmail,
                helperText: S.addMemberHelper,
                helperMaxLines: 2,
                errorText: error,
                errorMaxLines: 3,
              ),
              onSubmitted: (_) => submit(),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text(S.cancel)),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(88, 40)),
                onPressed: saving ? null : submit,
                child: const Text(S.add),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The big colored card on top: green when you get money back, red when you owe, ink when square.
class _BalanceHero extends StatelessWidget {
  const _BalanceHero({required this.controller});

  final GroupDetailController controller;

  // Own Obx: the page's Obx doesn't track what this build() reads.
  @override
  Widget build(BuildContext context) => Obx(() => _build(context));

  Widget _build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final net = controller.myNetCents;
    final (bg, fg) = net > 0
        ? (dark ? Brand.emeraldBright : Brand.emerald, dark ? Brand.ink : Colors.white)
        : net < 0
        ? (dark ? const Color(0xFFFF8A8C) : Brand.red, dark ? Brand.ink : Colors.white)
        : (dark ? const Color(0xFF1D2622) : Brand.ink, Colors.white);
    final headline = net == 0
        ? S.yourBalance
        : net > 0
        ? S.youGetBack
        : S.youOwe;

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: ShapeDecoration(
        color: bg,
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(28)),
      ),
      child: Stack(
        children: [
          // The logo's sliced zero as a watermark.
          Positioned(
            right: -36,
            top: -28,
            child: CustomPaint(
              size: const Size.square(190),
              painter: NetZeroMarkPainter(shape: MarkShape.none, foreground: fg.withValues(alpha: 0.09)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(headline, style: text.titleSmall?.copyWith(color: fg.withValues(alpha: 0.8))),
                const SizedBox(height: 6),
                Text(
                  net == 0 ? S.allSquare : formatCents(net.abs(), currency: controller.currency),
                  style: text.displaySmall?.copyWith(color: fg, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
                const SizedBox(height: 18),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: fg,
                    foregroundColor: bg,
                    disabledBackgroundColor: fg.withValues(alpha: 0.14),
                    disabledForegroundColor: fg.withValues(alpha: 0.7),
                  ),
                  onPressed: controller.isSettled ? null : () => Get.toNamed(Routes.settleUpPath(controller.groupId)),
                  child: Text(controller.isSettled ? S.nothingToSettle : S.settleUp),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberBalances extends StatelessWidget {
  const _MemberBalances({required this.controller});

  final GroupDetailController controller;

  @override
  Widget build(BuildContext context) => Obx(() => _build(context));

  Widget _build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final balances = controller.balances.value?.balances ?? const <MemberBalance>[];
    // The server labels ex-members in English; the group's own lookup gives the Mongolian label.
    String nameOf(MemberBalance b) => controller.group.value?.nameOf(b.userId) ?? b.name;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: [
            for (final (i, b) in balances.indexed) ...[
              if (i > 0) const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Initials(nameOf(b), radius: 16),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        b.userId == controller.myUserId ? S.youSuffix(nameOf(b)) : nameOf(b),
                        style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (b.netCents == 0)
                      Text(S.settled, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant))
                    else ...[
                      MoneyText(
                        b.netCents,
                        currency: controller.currency,
                        signed: true,
                        style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      Text(' ${b.netCents > 0 ? S.getsBack : S.owes}', style: text.bodySmall),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ExpenseTile extends StatelessWidget {
  const _ExpenseTile({required this.expense, required this.group, required this.me});

  final Expense expense;
  final Group group;
  final String me;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final payer = expense.paidBy == me ? S.you : group.nameOf(expense.paidBy);
    final myShare = expense.splits.where((s) => s.userId == me).fold(0, (a, s) => a + s.amountCents);
    // What this expense did to *my* balance, as the server computed it: paid minus my share.
    final effect = (expense.paidBy == me ? expense.amountCents : 0) - myShare;
    final colors = context.moneyColors;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Get.toNamed(Routes.expensePath(group.id, expense.id)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
          child: Row(
            children: [
              // Calendar chip: day big, month small.
              Container(
                width: 54,
                height: 54,
                decoration: ShapeDecoration(
                  color: scheme.surfaceContainerHigh,
                  shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('${expense.createdAt.toLocal().day}', style: text.titleMedium?.copyWith(height: 1.1)),
                    Text(S.month(expense.createdAt), style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            expense.description,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (expense.hasReceipt) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.receipt_long_outlined, size: 16, color: scheme.outline),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      S.paid(payer, formatCents(expense.amountCents, currency: group.currency)),
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (effect == 0)
                Text(S.notInvolved, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant))
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      effect > 0 ? S.youGetBack : S.youOwe,
                      style: text.labelSmall?.copyWith(color: effect > 0 ? colors.positive : colors.negative),
                    ),
                    MoneyText(
                      effect,
                      currency: group.currency,
                      signed: true,
                      style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800),
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
