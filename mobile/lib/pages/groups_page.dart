import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app/brand.dart';
import '../app/routes.dart';
import '../app/strings.dart';
import '../controllers/groups_controller.dart';
import '../models/models.dart';
import 'widgets.dart';

class GroupsPage extends GetView<GroupsController> {
  const GroupsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const NetZeroLogo(),
        actions: [
          Obx(() {
            final me = controller.me.value;
            return PopupMenuButton<String>(
              icon: me == null ? const Icon(Icons.account_circle_outlined) : Initials(me.name, radius: 15),
              itemBuilder: (_) => [
                if (me != null) PopupMenuItem(enabled: false, child: Text('${me.name}\n${me.email}')),
                const PopupMenuItem(value: 'signout', child: Text(S.signOut)),
              ],
              onSelected: (v) => v == 'signout' ? controller.signOut() : null,
            );
          }),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateGroup(context),
        icon: const Icon(Icons.add),
        label: const Text(S.newGroup),
      ),
      body: Obx(() {
        if (controller.loading.value) return const SkeletonList();
        final error = controller.error.value;
        if (error != null) return ErrorRetry(message: error, onRetry: controller.load);
        if (controller.groups.isEmpty) return const _EmptyGroups();
        return RefreshIndicator(
          onRefresh: controller.load,
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            itemCount: controller.groups.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, i) => _GroupTile(controller.groups[i]),
          ),
        );
      }),
    );
  }

  Future<void> _showCreateGroup(BuildContext context) async {
    final name = TextEditingController();
    var currency = 'MNT';
    String? error;
    var saving = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          Future<void> submit() async {
            if (name.text.trim().isEmpty) return setState(() => error = S.giveGroupName);
            setState(() => saving = true);
            Navigator.of(ctx).pop();
            final message = await controller.create(name.text, currency);
            if (message != null) Get.snackbar(S.couldNotCreateGroup, message, snackPosition: SnackPosition.BOTTOM);
          }

          return AlertDialog(
            title: const Text(S.newGroup),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: S.groupName, hintText: S.groupNameHint, errorText: error),
                  onSubmitted: (_) => submit(),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: currency,
                  decoration: const InputDecoration(labelText: S.currency),
                  items: const [
                    'MNT',
                    'USD',
                    'EUR',
                    'GBP',
                    'KRW',
                    'CNY',
                  ].map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                  onChanged: (v) => currency = v ?? 'MNT',
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text(S.cancel)),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(88, 40)),
                onPressed: saving ? null : submit,
                child: const Text(S.create),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _GroupTile extends StatelessWidget {
  const _GroupTile(this.group);

  final Group group;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final names = group.members.map((m) => m.name.split(' ').first).join(', ');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Get.toNamed(Routes.groupPath(group.id)),
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
