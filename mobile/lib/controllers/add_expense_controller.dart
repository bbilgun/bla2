import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../app/strings.dart';
import '../domain/money.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';

/// The add-expense form. It collects *intent* (who paid, who's in, how to split) and sends it;
/// the server computes every share. The getters below only drive hints like "$3.00 left to assign".
class AddExpenseController extends GetxController {
  AddExpenseController({required this.group, required String myUserId, required this._expenses, Uuid? uuid})
    : _uuid = uuid ?? const Uuid() {
    paidBy.value = group.members.any((m) => m.userId == myUserId) ? myUserId : group.members.first.userId;
    included.addAll(group.members.map((m) => m.userId));
    for (final m in group.members) {
      exactCtrls[m.userId] = _mirrored(exactText[m.userId] = ''.obs);
      percentCtrls[m.userId] = _mirrored(percentText[m.userId] = ''.obs);
    }
  }

  final Group group;
  final ExpensesRepository _expenses;
  final Uuid _uuid;

  // Text fields are mirrored into .obs strings so Obx can react to typing.
  final amountText = ''.obs;
  late final description = TextEditingController();
  late final amount = _mirrored(amountText);
  final exactText = <String, RxString>{};
  final percentText = <String, RxString>{};
  final exactCtrls = <String, TextEditingController>{};
  final percentCtrls = <String, TextEditingController>{};

  final splitType = SplitType.even.obs;
  final paidBy = ''.obs;
  final included = <String>{}.obs;

  final saving = false.obs;
  final error = RxnString();
  final fieldErrors = <String, String>{}.obs;

  /// The Idempotency-Key for the request currently being saved.
  /// Created on the first tap of Save, reused on every retry of the *same* request,
  /// and thrown away only once the server confirms the save. If the person edits the form,
  /// it's a different request, so it gets a new key.
  String? _pendingKey;
  String? _pendingBody;
  String? get pendingIdempotencyKey => _pendingKey;

  // ---- plain getters over .obs (never return a fresh .obs from a getter) ----

  int? get amountCents => tryParseCents(amountText.value);

  int get exactAssignedCents =>
      group.members.fold(0, (sum, m) => sum + (tryParseCents(exactText[m.userId]!.value) ?? 0));

  int get percentAssignedBp =>
      group.members.fold(0, (sum, m) => sum + (tryParseBasisPoints(percentText[m.userId]!.value) ?? 0));

  int? get exactRemainingCents => amountCents == null ? null : amountCents! - exactAssignedCents;

  int get percentRemainingBp => 10000 - percentAssignedBp;

  // ---- actions ----

  void toggleIncluded(String userId) => included.contains(userId) ? included.remove(userId) : included.add(userId);

  void splitPercentEvenly() {
    final n = group.members.length;
    for (final (i, m) in group.members.indexed) {
      // Display hint only: 10000 bp / n, with the leftover on the first rows. The server re-checks the sum.
      final bp = 10000 ~/ n + (i < 10000 % n ? 1 : 0);
      percentCtrls[m.userId]!.text = '${bp ~/ 100}.${(bp % 100).toString().padLeft(2, '0')}';
    }
  }

  /// The exact JSON the API validates, or null (with [fieldErrors] set) if the form is incomplete.
  Map<String, dynamic>? buildBody() {
    final errors = <String, String>{};
    final cents = amountCents;
    if (description.text.trim().isEmpty) errors['description'] = S.whatWasItFor;
    if (cents == null || cents <= 0) errors['amount'] = S.amountHint;

    Map<String, dynamic>? split;
    switch (splitType.value) {
      case SplitType.even:
        final ids = group.members.map((m) => m.userId).where(included.contains).toList();
        if (ids.isEmpty) errors['split'] = S.pickSomeone;
        split = {'type': 'EVEN', 'userIds': ids};
      case SplitType.exact:
        final shares = <Map<String, dynamic>>[];
        for (final m in group.members) {
          final text = exactText[m.userId]!.value.trim();
          if (text.isEmpty) continue;
          final v = tryParseCents(text);
          if (v == null || v < 0) {
            errors['split'] = S.checkAmountFor(m.name);
          } else if (v > 0) {
            shares.add({'userId': m.userId, 'amountCents': v});
          }
        }
        if (shares.isEmpty) errors['split'] ??= S.enterOneShare;
        if (cents != null && exactRemainingCents != 0) {
          errors['split'] ??= S.sharesMustAddUpTo(formatCents(cents, currency: group.currency));
        }
        split = {'type': 'EXACT', 'shares': shares};
      case SplitType.percent:
        final shares = <Map<String, dynamic>>[];
        for (final m in group.members) {
          final text = percentText[m.userId]!.value.trim();
          if (text.isEmpty) continue;
          final bp = tryParseBasisPoints(text);
          if (bp == null || bp < 0 || bp > 10000) {
            errors['split'] = S.checkPercentFor(m.name);
          } else if (bp > 0) {
            shares.add({'userId': m.userId, 'basisPoints': bp});
          }
        }
        if (percentAssignedBp != 10000) errors['split'] ??= S.percentMustBe100;
        split = {'type': 'PERCENT', 'shares': shares};
    }

    fieldErrors.assignAll(errors);
    if (errors.isNotEmpty) return null;
    return {'description': description.text.trim(), 'amountCents': cents, 'paidBy': paidBy.value, 'split': split};
  }

  /// Returns the created expense, or null if it didn't save (see [error] / [fieldErrors]).
  Future<Expense?> save() async {
    if (saving.value) return null;
    error.value = null;
    final body = buildBody();
    if (body == null) return null;

    final encoded = jsonEncode(body);
    if (encoded != _pendingBody) {
      _pendingKey = _uuid.v4();
      _pendingBody = encoded;
    }

    saving.value = true;
    try {
      final expense = await _expenses.create(group.id, body, idempotencyKey: _pendingKey!);
      _pendingKey = null;
      _pendingBody = null;
      return expense;
    } on GroupNotFoundException {
      rethrow;
    } on ApiException catch (e) {
      if (e.isNetwork) {
        // The server may or may not have saved it. Retrying with the same key is safe either way.
        error.value = S.saveOffline;
      } else {
        fieldErrors.assignAll(_fieldErrorsFrom(e));
        error.value = fieldErrors.isEmpty ? e.message : null;
      }
      return null;
    } finally {
      saving.value = false;
    }
  }

  /// Puts server validation errors next to the field they belong to.
  Map<String, String> _fieldErrorsFrom(ApiException e) {
    final out = <String, String>{};
    for (final MapEntry(:key, :value) in e.fieldErrors.entries) {
      final field = key.startsWith('split')
          ? 'split'
          : key == 'amountCents'
          ? 'amount'
          : key;
      out.putIfAbsent(field, () => value);
    }
    final byCode = switch (e.code) {
      'SPLIT_SUM_MISMATCH' ||
      'SPLIT_PERCENT_MISMATCH' ||
      'SPLIT_EMPTY' ||
      'SPLIT_USER_NOT_MEMBER' ||
      'INVALID_PERCENT' => 'split',
      'INVALID_AMOUNT' => 'amount',
      'PAYER_NOT_MEMBER' => 'paidBy',
      _ => null,
    };
    if (byCode != null) out.putIfAbsent(byCode, () => e.message);
    return out;
  }

  TextEditingController _mirrored(RxString target) {
    final c = TextEditingController();
    c.addListener(() => target.value = c.text);
    return c;
  }

  @override
  void onClose() {
    description.dispose();
    amount.dispose();
    for (final c in [...exactCtrls.values, ...percentCtrls.values]) {
      c.dispose();
    }
    super.onClose();
  }
}
