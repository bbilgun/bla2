import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app/brand.dart';
import '../app/notify.dart';
import '../app/routes.dart';
import '../app/strings.dart';
import '../app/theme.dart';
import '../controllers/group_detail_controller.dart';
import '../domain/money.dart';
import '../models/models.dart';
import 'widgets.dart';

enum _GroupAction { members, rename, leave, delete }

class GroupDetailPage extends GetView<GroupDetailController> {
  const GroupDetailPage({super.key});

  /// Whatever happened on the add-expense page (saved, backed out, offline), the list is refetched:
  /// a save whose answer was lost may still have gone through.
  Future<void> _addExpense() async {
    await Get.toNamed<Object?>(Routes.addExpensePath(controller.groupId));
    await controller.refreshAfterWrite();
  }

  Future<void> _onAction(BuildContext context, _GroupAction action) async {
    final group = controller.group.value;
    if (group == null) return;
    switch (action) {
      case _GroupAction.members:
        await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (_) => _MembersSheet(controller: controller),
        );
      case _GroupAction.rename:
        await showDialog<void>(
          context: context,
          builder: (_) => TextPromptDialog(
            title: S.renameGroup,
            label: S.groupName,
            submitLabel: S.save,
            initial: group.name,
            capitalization: TextCapitalization.sentences,
            onSubmit: controller.rename,
          ),
        );
      case _GroupAction.leave:
        final ok = await confirmAction(
          context,
          title: S.leaveGroup,
          message: S.leaveGroupQuestion,
          confirmLabel: S.leaveGroup,
        );
        if (!ok) return;
        final message = await controller.leave();
        if (message != null && context.mounted) await showMessage(context, title: S.leaveGroup, message: message);
      case _GroupAction.delete:
        final ok = await confirmAction(
          context,
          title: S.deleteGroup,
          message: S.deleteGroupQuestion,
          confirmLabel: S.delete,
        );
        if (!ok) return;
        final message = await controller.deleteGroup();
        if (message != null && context.mounted) await showMessage(context, title: S.deleteGroup, message: message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Obx(() => Text(controller.group.value?.name ?? '')),
        actions: [
          IconButton(
            tooltip: S.inviteByEmail,
            icon: const Icon(Icons.person_add_alt_1_outlined),
            onPressed: () => unawaited(showInviteDialog(context, controller)),
          ),
          PopupMenuButton<_GroupAction>(
            onSelected: (a) => unawaited(_onAction(context, a)),
            itemBuilder: (_) => const [
              PopupMenuItem(value: _GroupAction.members, child: Text(S.members)),
              PopupMenuItem(value: _GroupAction.rename, child: Text(S.renameGroup)),
              PopupMenuItem(value: _GroupAction.leave, child: Text(S.leaveGroup)),
              PopupMenuItem(value: _GroupAction.delete, child: Text(S.deleteGroup)),
            ],
          ),
        ],
      ),
      floatingActionButton: Obx(
        () => controller.group.value == null
            ? const SizedBox.shrink()
            : FloatingActionButton.extended(
                onPressed: () => unawaited(_addExpense()),
                icon: const Icon(Icons.add),
                label: const Text(S.addExpense),
              ),
      ),
      body: Obx(() {
        if (controller.loading.value) return const SkeletonList(header: true, count: 4);
        final error = controller.error.value;
        final group = controller.group.value;
        if (error != null || group == null) {
          return ErrorRetry(message: error ?? S.couldNotLoadGroup, onRetry: controller.retry);
        }
        final expenses = controller.expenses;
        // After a failed page this stays false until "load more" is tapped: no retry loop.
        final autoLoad = controller.shouldAutoLoad;
        return RefreshIndicator(
          onRefresh: controller.refreshAll,
          // Slivers: expense rows are built lazily as they scroll into view, so a group with hundreds of
          // expenses opens as fast as one with five. The next page loads on its own near the bottom.
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                sliver: SliverList.list(
                  children: [
                    _BalanceHero(controller: controller),
                    const SizedBox(height: 12),
                    _MemberBalances(controller: controller),
                    if (group.invites.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _PendingInvites(controller: controller, invites: group.invites),
                    ],
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
                    if (autoLoad && i == expenses.length - 1) {
                      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(controller.loadMore()));
                    }
                    return _ExpenseTile(expense: expenses[i], group: group, me: controller.myUserId);
                  },
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 104),
                sliver: SliverToBoxAdapter(
                  child: LoadMoreFooter(
                    hasMore: controller.hasMore,
                    loading: controller.loadingMore,
                    onLoadMore: () => unawaited(controller.loadMore()),
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

/// "Invite by email": the person sees the invite once they sign in with that address.
Future<void> showInviteDialog(BuildContext context, GroupDetailController controller) => showDialog<void>(
  context: context,
  builder: (_) => TextPromptDialog(
    title: S.inviteByEmail,
    label: S.memberEmail,
    helper: S.inviteHelper,
    submitLabel: S.invite,
    keyboardType: TextInputType.emailAddress,
    onSubmit: (email) async {
      final message = await controller.invite(email);
      if (message == null) notify(S.inviteSent(email.trim()));
      return message;
    },
  ),
);

/// Invited people who haven't joined yet, each with "cancel".
class _PendingInvites extends StatelessWidget {
  const _PendingInvites({required this.controller, required this.invites});

  final GroupDetailController controller;
  final List<GroupInvite> invites;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(S.pendingInvites, style: text.titleSmall),
            ),
            for (final invite in invites) _InviteRow(controller: controller, invite: invite),
          ],
        ),
      ),
    );
  }
}

class _InviteRow extends StatelessWidget {
  const _InviteRow({required this.controller, required this.invite});

  final GroupDetailController controller;
  final GroupInvite invite;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    leading: const Icon(Icons.mail_outline),
    title: Text(invite.email),
    subtitle: Text(shortDate(invite.createdAt)),
    trailing: IconButton(
      tooltip: S.cancelInvite,
      icon: const Icon(Icons.close),
      onPressed: () async {
        final message = await controller.cancelInvite(invite);
        if (message != null) notify(S.actionFailed, message);
      },
    ),
  );
}

/// Members (remove someone else) and pending invites (cancel), from the menu.
class _MembersSheet extends StatelessWidget {
  const _MembersSheet({required this.controller});

  final GroupDetailController controller;

  Future<void> _remove(BuildContext context, Member m) async {
    final ok = await confirmAction(
      context,
      title: S.removeMember,
      message: S.removeMemberQuestion(m.name),
      confirmLabel: S.removeMember,
    );
    if (!ok) return;
    final message = await controller.removeMember(m);
    if (message != null && context.mounted) await showMessage(context, title: S.removeMember, message: message);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Obx(() {
        final group = controller.group.value;
        if (group == null) return const SizedBox.shrink();
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(S.members, style: text.titleLarge),
            ),
            for (final m in group.members)
              ListTile(
                leading: Initials(m.name, radius: 16),
                title: Text(m.userId == controller.myUserId ? S.youSuffix(m.name) : m.name),
                subtitle: Text(m.email),
                trailing: m.userId == controller.myUserId
                    ? null
                    : IconButton(
                        tooltip: S.removeMember,
                        icon: const Icon(Icons.person_remove_outlined),
                        onPressed: () => unawaited(_remove(context, m)),
                      ),
              ),
            if (group.invites.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(S.pendingInvites, style: text.titleSmall),
              ),
              for (final invite in group.invites) _InviteRow(controller: controller, invite: invite),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: OutlinedButton.icon(
                onPressed: () => unawaited(showInviteDialog(context, controller)),
                icon: const Icon(Icons.person_add_alt_1_outlined),
                label: const Text(S.inviteByEmail),
              ),
            ),
          ],
        );
      }),
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
                  // Settled: still opens, for the history of recorded payments (and deleting a mistaken one).
                  onPressed: () => unawaited(Get.toNamed<void>(Routes.settleUpPath(controller.groupId))),
                  child: Text(controller.isSettled ? S.paymentHistory : S.settleUp),
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
        onTap: () => unawaited(Get.toNamed<void>(Routes.expensePath(group.id, expense.id))),
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
