import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app/strings.dart';
import '../controllers/add_expense_controller.dart';
import '../domain/money.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import 'widgets.dart';

class AddExpensePage extends GetView<AddExpenseController> {
  const AddExpensePage({super.key});

  Future<void> _save() async {
    try {
      final expense = await controller.save();
      if (expense != null) Get.back(result: true);
    } on GroupNotFoundException {
      Get.back(result: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = controller.group;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text(S.addExpense)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Obx(
              () => TextField(
                controller: controller.description,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: S.description,
                  hintText: S.descriptionHint,
                  errorText: controller.fieldErrors['description'],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Obx(
              () => TextField(
                controller: controller.amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: S.amount,
                  prefixText: symbolAfterAmount(group.currency) ? null : '${currencySymbol(group.currency)} ',
                  suffixText: symbolAfterAmount(group.currency) ? currencySymbol(group.currency) : null,
                  hintText: '0.00',
                  errorText: controller.fieldErrors['amount'],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Obx(
              () => DropdownButtonFormField<String>(
                initialValue: controller.paidBy.value,
                decoration: InputDecoration(labelText: S.paidBy, errorText: controller.fieldErrors['paidBy']),
                items: [for (final m in group.members) DropdownMenuItem(value: m.userId, child: Text(m.name))],
                onChanged: (v) => controller.paidBy.value = v ?? controller.paidBy.value,
              ),
            ),
            const SizedBox(height: 24),
            Text(S.split, style: text.titleMedium),
            const SizedBox(height: 8),
            Obx(
              () => SegmentedButton<SplitType>(
                segments: [for (final t in SplitType.values) ButtonSegment(value: t, label: Text(t.label))],
                selected: {controller.splitType.value},
                onSelectionChanged: (s) {
                  controller.splitType.value = s.first;
                  controller.fieldErrors.remove('split');
                },
              ),
            ),
            const SizedBox(height: 12),
            Obx(
              () => switch (controller.splitType.value) {
                SplitType.even => _EvenSplit(controller: controller),
                SplitType.exact => _ExactSplit(controller: controller),
                SplitType.percent => _PercentSplit(controller: controller),
              },
            ),
            Obx(() {
              final e = controller.fieldErrors['split'];
              return e == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(e, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    );
            }),
            const SizedBox(height: 20),
            Obx(() => InlineError(controller.error.value)),
            const SizedBox(height: 12),
            Obx(
              () => FilledButton(
                onPressed: controller.saving.value ? null : _save,
                child: controller.saving.value
                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text(S.save),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EvenSplit extends StatelessWidget {
  const _EvenSplit({required this.controller});

  final AddExpenseController controller;

  // Own Obx: the parent Obx only tracks .obs read in its own builder, not in this build().
  @override
  Widget build(BuildContext context) {
    return Obx(
      () => Column(
        children: [
          for (final m in controller.group.members)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: controller.included.contains(m.userId),
              onChanged: (_) => controller.toggleIncluded(m.userId),
              secondary: Initials(m.name, radius: 16),
              title: Text(m.name),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(S.evenSplitNote, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _ExactSplit extends StatelessWidget {
  const _ExactSplit({required this.controller});

  final AddExpenseController controller;

  @override
  Widget build(BuildContext context) {
    final currency = controller.group.currency;
    return Column(
      children: [
        for (final m in controller.group.members)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Initials(m.name, radius: 16),
                const SizedBox(width: 12),
                Expanded(child: Text(m.name)),
                SizedBox(
                  width: 130,
                  child: TextField(
                    controller: controller.exactCtrls[m.userId],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.end,
                    decoration: const InputDecoration(hintText: '0.00', isDense: true),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: Obx(() {
            final remaining = controller.exactRemainingCents;
            return Text(
              remaining == null
                  ? S.enterTotalFirst
                  : remaining == 0
                  ? S.allAssigned
                  : remaining > 0
                  ? S.leftToAssign(formatCents(remaining, currency: currency))
                  : S.tooMuch(formatCents(-remaining, currency: currency)),
              style: Theme.of(context).textTheme.bodySmall,
            );
          }),
        ),
      ],
    );
  }
}

class _PercentSplit extends StatelessWidget {
  const _PercentSplit({required this.controller});

  final AddExpenseController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final m in controller.group.members)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Initials(m.name, radius: 16),
                const SizedBox(width: 12),
                Expanded(child: Text(m.name)),
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: controller.percentCtrls[m.userId],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.end,
                    decoration: const InputDecoration(hintText: '0.00', suffixText: '%', isDense: true),
                  ),
                ),
              ],
            ),
          ),
        Row(
          children: [
            TextButton(onPressed: controller.splitPercentEvenly, child: const Text(S.splitEvenly)),
            const Spacer(),
            Obx(() {
              final left = controller.percentRemainingBp;
              return Text(
                left == 0
                    ? S.percentAssigned
                    : (left > 0 ? S.leftToAssign(formatBasisPoints(left)) : S.tooMuch(formatBasisPoints(-left))),
                style: Theme.of(context).textTheme.bodySmall,
              );
            }),
          ],
        ),
      ],
    );
  }
}
