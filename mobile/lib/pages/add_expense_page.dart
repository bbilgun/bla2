// The add expense form, also used for editing an expense.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app/strings.dart';
import '../controllers/add_expense_controller.dart';
import '../domain/money.dart';
import '../models/models.dart';
import '../services/api_exception.dart';
import 'widgets.dart';

/// Adds an expense, or edits the controller's `existing` one. Pops with the saved [Expense].
/// Popping with anything else, after backing out or a conflict, tells the opener to reload.
class AddExpensePage extends GetView<AddExpenseController> {
  const AddExpensePage({super.key});

  Future<void> _save(BuildContext context) async {
    try {
      final expense = await controller.save();
      if (expense != null) {
        Get.back<Object?>(result: expense);
      } else if (controller.outdated && context.mounted) {
        // Someone else changed or deleted it meanwhile. Say so, then go back so it's reloaded.
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
                  items: [
                    for (final member in group.members)
                      DropdownMenuItem(value: member.userId, child: Text(member.name)),
                  ],
                  onChanged: (userId) => controller.paidBy.value = userId ?? controller.paidBy.value,
                ),
              ),
              const SizedBox(height: 24),
              Text(S.split, style: text.titleMedium),
              const SizedBox(height: 8),
              Obx(
                () => SegmentedButton<SplitType>(
                  segments: [for (final type in SplitType.values) ButtonSegment(value: type, label: Text(type.label))],
                  selected: {controller.splitType.value},
                  onSelectionChanged: (selected) {
                    controller.splitType.value = selected.first;
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
                final splitError = controller.fieldErrors['split'];
                if (splitError == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(splitError, style: TextStyle(color: Theme.of(context).colorScheme.error)),
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

/// A checkbox per member for an even split.
class _EvenSplit extends StatelessWidget {
  const _EvenSplit({required this.controller});

  final AddExpenseController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => Column(
        children: [
          for (final member in controller.group.members)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: controller.included.contains(member.userId),
              onChanged: (_) => controller.toggleIncluded(member.userId),
              secondary: Initials(member.name, radius: 16),
              title: Text(member.name),
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

/// An amount field per member for an exact split, with what's left to assign.
class _ExactSplit extends StatelessWidget {
  const _ExactSplit({required this.controller});

  final AddExpenseController controller;

  @override
  Widget build(BuildContext context) {
    final currency = controller.group.currency;
    return Column(
      children: [
        for (final member in controller.group.members)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Initials(member.name, radius: 16),
                const SizedBox(width: 12),
                Expanded(child: Text(member.name)),
                SizedBox(
                  width: 130,
                  child: Semantics(
                    label: S.exactShareFor(member.name),
                    child: TextField(
                      controller: controller.exactFields[member.userId],
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
          child: Obx(
            () => Text(_remainingLabel(controller.exactRemainingCents), style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
      ],
    );
  }

  String _remainingLabel(int? remaining) {
    final currency = controller.group.currency;
    if (remaining == null) return S.enterTotalFirst;
    if (remaining == 0) return S.allAssigned;
    if (remaining > 0) return S.leftToAssign(formatCents(remaining, currency: currency));
    return S.tooMuch(formatCents(-remaining, currency: currency));
  }
}

/// A percentage field per member, with a button to split evenly and what's left to assign.
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
        for (final member in controller.group.members)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Initials(member.name, radius: 16),
                const SizedBox(width: 12),
                Expanded(child: Text(member.name)),
                SizedBox(
                  width: 110,
                  child: Semantics(
                    label: S.percentShareFor(member.name),
                    child: TextField(
                      controller: controller.percentFields[member.userId],
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
            Obx(
              () => Text(_remainingLabel(controller.percentRemainingBp), style: Theme.of(context).textTheme.bodySmall),
            ),
          ],
        ),
      ],
    );
  }

  String _remainingLabel(int remaining) {
    if (remaining == 0) return S.percentAssigned;
    if (remaining > 0) return S.leftToAssign(formatBasisPoints(remaining));
    return S.tooMuch(formatBasisPoints(-remaining));
  }
}
