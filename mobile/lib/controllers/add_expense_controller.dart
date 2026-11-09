import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../app/strings.dart';
import '../domain/money.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';

/// The add-expense form, also used to edit one ([existing]). It collects *intent* (who paid, who's in,
/// how to split) and sends it; the server computes every share. The getters below only drive hints
/// like "$3.00 left to assign".
class AddExpenseController extends GetxController {
  AddExpenseController({
    required this.group,
    required String myUserId,
    required this._expenses,
    this.existing,
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid() {
    paidBy.value = group.isMember(myUserId) ? myUserId : group.members.first.userId;
    included.addAll(group.members.map((m) => m.userId));
    for (final m in group.members) {
      exactCtrls[m.userId] = _mirrored(exactText[m.userId] = ''.obs);
      percentCtrls[m.userId] = _mirrored(percentText[m.userId] = ''.obs);
    }
    final e = existing;
    if (e != null) _fill(e);
    _savedSnapshot = _snapshot();
  }

  final Group group;
  final ExpensesRepository _expenses;
  final Uuid _uuid;

  /// The expense being edited; null when adding.
  final Expense? existing;
  bool get isEditing => existing != null;

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

  /// Editing: someone else saved a newer version (EXPENSE_CHANGED) or deleted it. The page says so
  /// and goes back, and the expense is reloaded.
  bool outdated = false;

  /// The Idempotency-Key for the request currently being saved.
  /// Created on the first tap of Save, reused on every retry of the *same* request,
  /// and thrown away only once the server confirms the save. If the person edits the form,
  /// it's a different request, so it gets a new key. (Edits need none: they compare `version`.)
  String? _pendingKey;
  String? _pendingBody;
  String? get pendingIdempotencyKey => _pendingKey;

  String get currency => group.currency;

  /// Percent splits come back from the server as amounts only, so editing one asks for the percents again.
  bool get mustReenterPercents => existing?.splitType == SplitType.percent;

  void _fill(Expense e) {
    description.text = e.description;
    amount.text = centsToInput(e.amountCents, currency: currency);
    if (group.isMember(e.paidBy)) paidBy.value = e.paidBy;
    splitType.value = e.splitType;
    switch (e.splitType) {
      case SplitType.even:
        included.assignAll(e.splits.map((s) => s.userId).where(group.isMember));
      case SplitType.exact:
        for (final s in e.splits) {
          exactCtrls[s.userId]?.text = centsToInput(s.amountCents, currency: currency);
        }
      case SplitType.percent:
        break; // see mustReenterPercents
    }
  }

  // ---- unsaved changes ----

  late String _savedSnapshot;

  String _snapshot() => jsonEncode({
    'description': description.text,
    'amount': amountText.value,
    'paidBy': paidBy.value,
    'split': splitType.value.wire,
    'included': [for (final m in group.members) included.contains(m.userId)],
    'exact': [for (final m in group.members) exactText[m.userId]!.value],
    'percent': [for (final m in group.members) percentText[m.userId]!.value],
  });

  /// Something was typed or changed since the form opened: leaving asks first.
  bool get isDirty => _snapshot() != _savedSnapshot;

  // ---- plain getters over .obs (never return a fresh .obs from a getter) ----

  int? get amountCents => tryParseCents(amountText.value, currency: currency);

  int get exactAssignedCents =>
      group.members.fold(0, (sum, m) => sum + (tryParseCents(exactText[m.userId]!.value, currency: currency) ?? 0));

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
      percentCtrls[m.userId]!.text = basisPointsToInput(10000 ~/ n + (i < 10000 % n ? 1 : 0));
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
          final v = tryParseCents(text, currency: currency);
          if (v == null || v < 0) {
            errors['split'] = S.checkAmountFor(m.name);
          } else if (v > 0) {
            shares.add({'userId': m.userId, 'amountCents': v});
          }
        }
        if (shares.isEmpty) errors['split'] ??= S.enterOneShare;
        if (cents != null && exactRemainingCents != 0) {
          errors['split'] ??= S.sharesMustAddUpTo(formatCents(cents, currency: currency));
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

  /// Returns the saved expense, or null if it didn't save (see [error] / [fieldErrors] / [outdated]).
  Future<Expense?> save() async {
    if (saving.value) return null;
    error.value = null;
    final body = buildBody();
    if (body == null) return null;

    final editing = existing;
    if (editing == null) {
      final encoded = jsonEncode(body);
      if (encoded != _pendingBody) {
        _pendingKey = _uuid.v4();
        _pendingBody = encoded;
      }
    }

    saving.value = true;
    try {
      final Expense saved;
      if (editing != null) {
        // A retry of the same edit is safe: the server answers 200 if the stored content already matches.
        saved = await _expenses.update(group.id, editing.id, body, version: editing.version);
      } else {
        saved = await _expenses.create(group.id, body, idempotencyKey: _pendingKey!);
        _pendingKey = null;
        _pendingBody = null;
      }
      _savedSnapshot = _snapshot();
      return saved;
    } on GroupNotFoundException {
      rethrow;
    } on ApiException catch (e) {
      if (editing != null && (e.code == 'EXPENSE_CHANGED' || e.code == 'EXPENSE_NOT_FOUND')) {
        outdated = true;
        error.value = e.message;
      } else if (e.isNetwork) {
        // The server may or may not have saved it. Retrying (same key, or same version) is safe either way.
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
