import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app/brand.dart';
import '../app/routes.dart';
import '../app/strings.dart';
import '../controllers/groups_controller.dart';
import '../controllers/invites_controller.dart';
import '../domain/money.dart';
import '../models/models.dart';
import 'widgets.dart';

class GroupsPage extends GetView<GroupsController> {
  const GroupsPage({super.key});

  InvitesController get _invites => Get.find<InvitesController>();

  Future<void> _refresh() => Future.wait([controller.load(), _invites.load()]);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const NetZeroLogo(),
        actions: [
          Obx(() => AccountButton(name: controller.me.value?.name)),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => unawaited(_showCreateGroup(context)),
        icon: const Icon(Icons.add),
        label: const Text(S.newGroup),
      ),
      body: Obx(() {
        if (controller.loading.value) return const SkeletonList();
        final error = controller.error.value;
        if (error != null) return ErrorRetry(message: error, onRetry: controller.retry);
        final groups = controller.groups;
        final invites = [for (final i in _invites.invites) _InviteCard(i, controller: _invites, groups: controller)];
        if (groups.isEmpty) {
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ScrollableEmpty(header: invites, child: const _EmptyGroups()),
          );
        }
        final list = controller.list;
        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              ...invites,
              for (final (i, g) in groups.indexed) ...[
                if (i > 0) const SizedBox(height: 10),
                _GroupTile(g, onBuilt: i == groups.length - 1 && list.shouldAutoLoad ? controller.loadMore : null),
              ],
              LoadMoreFooter(hasMore: list.hasMore, loading: list.loadingMore, onLoadMore: controller.loadMore),
            ],
          ),
        );
      }),
    );
  }

  Future<void> _showCreateGroup(BuildContext context) async {
    final created = await showDialog<({String name, String currency})>(
      context: context,
      builder: (_) => const _CreateGroupDialog(),
    );
    if (created == null) return;
    final message = await controller.create(created.name, created.currency);
    if (message != null) Get.snackbar(S.couldNotCreateGroup, message, snackPosition: SnackPosition.BOTTOM);
  }
}

/// Name and currency for a new group. Owns (and disposes) its text controller.
class _CreateGroupDialog extends StatefulWidget {
  const _CreateGroupDialog();

  @override
  State<_CreateGroupDialog> createState() => _CreateGroupDialogState();
}

class _CreateGroupDialogState extends State<_CreateGroupDialog> {
  final _name = TextEditingController();
  var _currency = currencies.first.code;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return setState(() => _error = S.giveGroupName);
    if (name.length > 80) return setState(() => _error = S.groupNameTooLong);
    Navigator.of(context).pop((name: name, currency: _currency));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text(S.newGroup),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _name,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: S.groupName, hintText: S.groupNameHint, errorText: _error),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _currency,
          decoration: const InputDecoration(labelText: S.currency),
          items: [for (final c in currencyCodes) DropdownMenuItem(value: c, child: Text(c))],
          onChanged: (v) => _currency = v ?? _currency,
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text(S.cancel)),
      FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size(88, 40)),
        onPressed: _submit,
        child: const Text(S.create),
      ),
    ],
  );
}

/// An invite to me: join, or decline.
class _InviteCard extends StatelessWidget {
  const _InviteCard(this.invite, {required this.controller, required this.groups});

  final PendingInvite invite;
  final InvitesController controller;
  final GroupsController groups;

  Future<void> _accept() async {
    final group = await controller.accept(invite);
    if (group == null) {
      // INVITE_NOT_FOUND can mean an earlier accept went through: the group may be in the list now.
      unawaited(groups.refreshQuietly());
      return;
    }
    groups.joined(group);
    unawaited(Get.toNamed<void>(Routes.groupPath(group.id)));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        color: scheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Initials(invite.groupName, radius: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(S.invitesTitle, style: text.labelSmall?.copyWith(color: scheme.onPrimaryContainer)),
                        Text(invite.groupName, style: text.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text(
                          S.inviteMeta(invite.invitedByName, invite.memberCount),
                          style: text.bodySmall?.copyWith(color: scheme.onPrimaryContainer),
                        ),
                      ],
                    ),
                  ),
                  _Pill(invite.currency),
                ],
              ),
              Obx(() {
                final busy = controller.isBusy(invite);
                return Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: busy ? null : () => unawaited(controller.decline(invite)),
                      child: const Text(S.decline),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size(88, 40)),
                      onPressed: busy ? null : () => unawaited(_accept()),
                      child: const Text(S.accept),
                    ),
                  ],
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupTile extends StatelessWidget {
  const _GroupTile(this.group, {this.onBuilt});

  final Group group;

  /// The last row asks for the next page once it's on screen.
  final VoidCallback? onBuilt;

  @override
  Widget build(BuildContext context) {
    final built = onBuilt;
    if (built != null) WidgetsBinding.instance.addPostFrameCallback((_) => built());
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final names = group.members.map((m) => m.name.split(' ').first).join(', ');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => unawaited(Get.toNamed<void>(Routes.groupPath(group.id))),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Initials(group.name, radius: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(group.name, style: text.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      names,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _Pill(group.currency),
              Icon(Icons.chevron_right, color: scheme.outline),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: ShapeDecoration(
        color: scheme.surfaceContainerHigh,
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700)),
    );
  }
}

class _EmptyGroups extends StatelessWidget {
  const _EmptyGroups();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const NetZeroMark(size: 64),
            const SizedBox(height: 16),
            Text(S.noGroupsYet, style: text.titleLarge),
            const SizedBox(height: 8),
            Text(S.noGroupsHint, textAlign: TextAlign.center, style: text.bodyMedium),
          ],
        ),
      ),
    );
  }
}
