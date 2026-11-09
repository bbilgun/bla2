import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app/strings.dart';
import '../controllers/add_expense_controller.dart';
import '../domain/money.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import 'widgets.dart';

/// Adds an expense, or edits one (the controller's `existing`). Returns the saved [Expense] to the
/// page that opened it; anything else (backed out, changed by someone else) means "reload".
class AddExpensePage extends GetView<AddExpenseController> {
  const AddExpensePage({super.key});

  Future<void> _save(BuildContext context) async {
    try {
      final expense = await controller.save();
      if (expense != null) {
        Get.back<Object?>(result: expense);
      } else if (controller.outdated && context.mounted) {
        // Someone else changed (or deleted) it meanwhile: say so, then go back so it's reloaded.
        await showMessage(context, title: S.expenseChangedTitle, message: controller.error.value ?? S.expenseChanged);
        Get.back<Object?>(result: false);
      }
    } on GroupNotFoundException {
      Get.back<Object?>(result: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = controller.group;
    final currency = group.currency;
    final text = Theme.of(context).textTheme;
    return FormPopScope(
      saving: () => controller.saving.value,
      isDirty: () => controller.isDirty,
      child: Scaffold(
        appBar: AppBar(title: Text(controller.isEditing ? S.editExpense : S.addExpense)),
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
                  keyboardType: TextInputType.numberWithOptions(decimal: hasMinorUnits(currency)),
                  decoration: InputDecoration(
                    labelText: S.amount,
                    prefixText: symbolAfterAmount(currency) ? null : '${currencySymbol(currency)} ',
                    suffixText: symbolAfterAmount(currency) ? currencySymbol(currency) : null,
                    hintText: amountPlaceholder(currency),
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
                  onPressed: controller.saving.value ? null : () => unawaited(_save(context)),
                  child: controller.saving.value
                      ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text(S.save),
                ),
              ),
            ],
          ),
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
                  child: Semantics(
                    label: S.exactShareFor(m.name),
                    child: TextField(
                      controller: controller.exactCtrls[m.userId],
                      keyboardType: TextInputType.numberWithOptions(decimal: hasMinorUnits(currency)),
                      textAlign: TextAlign.end,
                      decoration: InputDecoration(hintText: amountPlaceholder(currency), isDense: true),
                    ),
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
        if (controller.mustReenterPercents)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(S.reenterPercents, style: Theme.of(context).textTheme.bodySmall),
          ),
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
                  child: Semantics(
                    label: S.percentShareFor(m.name),
                    child: TextField(
                      controller: controller.percentCtrls[m.userId],
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      textAlign: TextAlign.end,
                      decoration: const InputDecoration(hintText: '0.00', suffixText: '%', isDense: true),
                    ),
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
