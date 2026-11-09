// The group page: your balance, everyone's balances, pending invites and the expense list.
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

/// The choices in the app bar menu.
enum _GroupAction { members, rename, leave, delete }

/// One group: balances on top, then the expenses, newest first.
class GroupDetailPage extends GetView<GroupDetailController> {
  const GroupDetailPage({super.key});

  // Refetches whatever happened on the add expense page, because a save whose answer was lost
  // may still have gone through.
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
        final confirmed = await confirmAction(
          context,
          title: S.leaveGroup,
          message: S.leaveGroupQuestion,
          confirmLabel: S.leaveGroup,
        );
        if (!confirmed) return;
        final message = await controller.leave();
        if (message != null && context.mounted) await showMessage(context, title: S.leaveGroup, message: message);
      case _GroupAction.delete:
        final confirmed = await confirmAction(
          context,
          title: S.deleteGroup,
          message: S.deleteGroupQuestion,
          confirmLabel: S.delete,
        );
        if (!confirmed) return;
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
            onPressed: () => unawaited(_showInviteDialog(context, controller)),
          ),
          PopupMenuButton<_GroupAction>(
            onSelected: (action) => unawaited(_onAction(context, action)),
            itemBuilder: (_) => const [
              PopupMenuItem(value: _GroupAction.members, child: Text(S.members)),
              PopupMenuItem(value: _GroupAction.rename, child: Text(S.renameGroup)),
              PopupMenuItem(value: _GroupAction.leave, child: Text(S.leaveGroup)),
              PopupMenuItem(value: _GroupAction.delete, child: Text(S.deleteGroup)),
            ],
          ),
        ],
      ),
      floatingActionButton: Obx(() {
        if (controller.group.value == null) return const SizedBox.shrink();
        return FloatingActionButton.extended(
          onPressed: () => unawaited(_addExpense()),
          icon: const Icon(Icons.add),
          label: const Text(S.addExpense),
        );
      }),
      body: Obx(() {
        if (controller.loading.value) return const SkeletonList(header: true, count: 4);
        final error = controller.error.value;
        final group = controller.group.value;
        if (error != null || group == null) {
          return ErrorRetry(message: error ?? S.couldNotLoadGroup, onRetry: controller.retry);
        }
        final expenses = controller.expenses;
        final autoLoad = controller.shouldAutoLoad;
        return RefreshIndicator(
          onRefresh: controller.refreshAll,
          // Expense rows are built lazily as they scroll into view, so a long history opens quickly.
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
                  itemBuilder: (_, index) {
                    // Building the last row fetches the next page, after this frame.
                    if (autoLoad && index == expenses.length - 1) {
                      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(controller.loadMore()));
                    }
                    return _ExpenseTile(expense: expenses[index], group: group, me: controller.myUserId);
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

// Asks for an email to invite. The invitee sees the invite once they sign in with that address.
Future<void> _showInviteDialog(BuildContext context, GroupDetailController controller) => showDialog<void>(
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

/// Invites that haven't been accepted yet, each with a cancel button.
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

/// One pending invite: the address, when it was sent, and a cancel button.
class _InviteRow extends StatelessWidget {
  const _InviteRow({required this.controller, required this.invite});

  final GroupDetailController controller;
  final GroupInvite invite;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    leading: const Icon(Icons.mail_outline),
    title: Text(invite.email),
    subtitle: Text(S.date(invite.createdAt)),
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

/// The bottom sheet opened from the menu: members, with a remove button on everyone but the user,
/// and pending invites.
class _MembersSheet extends StatelessWidget {
  const _MembersSheet({required this.controller});

  final GroupDetailController controller;

  Future<void> _remove(BuildContext context, Member member) async {
    final confirmed = await confirmAction(
      context,
      title: S.removeMember,
      message: S.removeMemberQuestion(member.name),
      confirmLabel: S.removeMember,
    );
    if (!confirmed) return;
    final message = await controller.removeMember(member);
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
            for (final member in group.members) _memberRow(context, member),
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
                onPressed: () => unawaited(_showInviteDialog(context, controller)),
                icon: const Icon(Icons.person_add_alt_1_outlined),
                label: const Text(S.inviteByEmail),
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _memberRow(BuildContext context, Member member) {
    final isMe = member.userId == controller.myUserId;
    return ListTile(
      leading: Initials(member.name, radius: 16),
      title: Text(isMe ? S.youSuffix(member.name) : member.name),
      subtitle: Text(member.email),
      trailing: isMe
          ? null
          : IconButton(
              tooltip: S.removeMember,
              icon: const Icon(Icons.person_remove_outlined),
              onPressed: () => unawaited(_remove(context, member)),
            ),
    );
  }
}

/// The big colored card on top: green when the user gets money back, red when they owe, ink when square.
class _BalanceHero extends StatelessWidget {
  const _BalanceHero({required this.controller});

  final GroupDetailController controller;

  @override
  Widget build(BuildContext context) => Obx(() => _build(context));

  // Background and foreground colors for the user's balance.
  (Color, Color) _colors(int net, {required bool dark}) {
    final foreground = dark ? Brand.ink : Colors.white;
    if (net > 0) return (dark ? Brand.emeraldBright : Brand.emerald, foreground);
    if (net < 0) return (dark ? const Color(0xFFFF8A8C) : Brand.red, foreground);
    return (dark ? const Color(0xFF1D2622) : Brand.ink, Colors.white);
  }

  String _headline(int net) {
    if (net > 0) return S.youGetBack;
    if (net < 0) return S.youOwe;
    return S.yourBalance;
  }

  Widget _build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final net = controller.myNetCents;
    final (background, foreground) = _colors(net, dark: dark);
    final headline = _headline(net);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: ShapeDecoration(
        color: background,
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
              painter: NetZeroMarkPainter(shape: MarkShape.none, foreground: foreground.withValues(alpha: 0.09)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(headline, style: text.titleSmall?.copyWith(color: foreground.withValues(alpha: 0.8))),
                const SizedBox(height: 6),
                Text(
                  net == 0 ? S.allSquare : formatCents(net.abs(), currency: controller.currency),
                  style: text.displaySmall?.copyWith(
                    color: foreground,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 18),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: foreground,
                    foregroundColor: background,
                    disabledBackgroundColor: foreground.withValues(alpha: 0.14),
                    disabledForegroundColor: foreground.withValues(alpha: 0.7),
                  ),
                  // Still opens when settled, to show recorded payments and delete a mistaken one.
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

/// Every member's balance, with "gets back" or "owes".
class _MemberBalances extends StatelessWidget {
  const _MemberBalances({required this.controller});

  final GroupDetailController controller;

  @override
  Widget build(BuildContext context) => Obx(() => _build(context));

  Widget _build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final balances = controller.balances.value?.balances ?? const <MemberBalance>[];
    // The server labels former members in English, and the group's own lookup gives the Mongolian label.
    String nameOf(MemberBalance balance) => controller.group.value?.nameOf(balance.userId) ?? balance.name;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: [
            for (final (index, balance) in balances.indexed) ...[
              if (index > 0) const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Initials(nameOf(balance), radius: 16),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        balance.userId == controller.myUserId ? S.youSuffix(nameOf(balance)) : nameOf(balance),
                        style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (balance.netCents == 0)
                      Text(S.settled, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant))
                    else ...[
                      MoneyText(
                        balance.netCents,
                        currency: controller.currency,
                        signed: true,
                        style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      Text(' ${balance.netCents > 0 ? S.getsBack : S.owes}', style: text.bodySmall),
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

/// One expense: date chip, description, who paid, and what it did to the user's balance.
class _ExpenseTile extends StatelessWidget {
  const _ExpenseTile({required this.expense, required this.group, required this.me});

  final Expense expense;
  final Group group;

  /// The signed-in user's id.
  final String me;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final payer = expense.paidBy == me ? S.you : group.nameOf(expense.paidBy);
    // How this expense moved the user's balance: what they paid minus their share. Both come from the server.
    final myShare = expense.splits
        .where((split) => split.userId == me)
        .fold(0, (sum, split) => sum + split.amountCents);
    final myPayment = expense.paidBy == me ? expense.amountCents : 0;
    final effect = myPayment - myShare;
    final colors = context.moneyColors;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => unawaited(Get.toNamed<void>(Routes.expensePath(group.id, expense.id))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
          child: Row(
            children: [
              // Calendar chip with the day large and the month small.
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
