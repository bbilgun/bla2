// The add expense form, which also edits an existing expense.
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../app/strings.dart';
import '../domain/money.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';

/// Collects who paid, who's in and how to split, and sends that to the server, which works out every
/// share. The totals here only drive hints like "$3.00 left to assign". Pass [existing] to edit.
class AddExpenseController extends GetxController {
  AddExpenseController({
    required this.group,
    required String myUserId,
    required this._expenses,
    this.existing,
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid() {
    paidBy.value = group.isMember(myUserId) ? myUserId : group.members.first.userId;
    included.addAll(group.members.map((member) => member.userId));
    for (final member in group.members) {
      final exact = ''.obs;
      final percent = ''.obs;
      _exactText[member.userId] = exact;
      _percentText[member.userId] = percent;
      exactFields[member.userId] = _mirrored(exact);
      percentFields[member.userId] = _mirrored(percent);
    }
    final expense = existing;
    if (expense != null) _fill(expense);
    _savedSnapshot = _snapshot();
  }

  /// The group the expense belongs to.
  final Group group;
  final ExpensesRepository _expenses;
  final Uuid _uuid;

  /// The expense being edited, or null when adding.
  final Expense? existing;

  /// Whether the form edits an existing expense.
  bool get isEditing => existing != null;

  // Each text field writes into an RxString as the user types, so Obx can react to it.
  final _amountText = ''.obs;
  final _exactText = <String, RxString>{};
  final _percentText = <String, RxString>{};

  /// The description field.
  late final description = TextEditingController();

  /// The total amount field.
  late final amount = _mirrored(_amountText);

  /// Exact share fields, by member id.
  final exactFields = <String, TextEditingController>{};

  /// Percentage fields, by member id.
  final percentFields = <String, TextEditingController>{};

  /// How the expense is split.
  final splitType = SplitType.even.obs;

  /// User id of whoever paid. Defaults to the signed-in user.
  final paidBy = ''.obs;

  /// Members included in an even split.
  final included = <String>{}.obs;

  /// True while the save request runs.
  final saving = false.obs;

  /// A failure to show above the Save button.
  final error = RxnString();

  /// Validation messages by field: `description`, `amount`, `paidBy` or `split`.
  final fieldErrors = <String, String>{}.obs;

  /// Set when editing fails because someone else changed or deleted the expense. The page then says
  /// so and goes back, and the expense is reloaded.
  bool outdated = false;

  // The Idempotency-Key for the create request being saved, and the body it was made for. The key is
  // reused on every retry of the same body and dropped once the server confirms. Edits don't use one,
  // because the server checks `version` instead.
  String? _pendingKey;
  String? _pendingBody;

  /// The Idempotency-Key a retry would reuse, or null when nothing is waiting.
  String? get pendingIdempotencyKey => _pendingKey;

  /// The group's currency.
  String get currency => group.currency;

  /// The server only stores amounts for a percent split, so editing one asks for the percentages again.
  bool get mustReenterPercents => existing?.splitType == SplitType.percent;

  void _fill(Expense expense) {
    description.text = expense.description;
    amount.text = centsToInput(expense.amountCents, currency: currency);
    if (group.isMember(expense.paidBy)) paidBy.value = expense.paidBy;
    splitType.value = expense.splitType;
    switch (expense.splitType) {
      case SplitType.even:
        included.assignAll(expense.splits.map((split) => split.userId).where(group.isMember));
      case SplitType.exact:
        for (final split in expense.splits) {
          exactFields[split.userId]?.text = centsToInput(split.amountCents, currency: currency);
        }
      case SplitType.percent:
        // Left empty on purpose. See mustReenterPercents.
        break;
    }
  }

  // Unsaved changes

  late String _savedSnapshot;

  String _snapshot() => jsonEncode({
    'description': description.text,
    'amount': _amountText.value,
    'paidBy': paidBy.value,
    'split': splitType.value.wire,
    'included': [for (final member in group.members) included.contains(member.userId)],
    'exact': [for (final member in group.members) _exactText[member.userId]!.value],
    'percent': [for (final member in group.members) _percentText[member.userId]!.value],
  });

  /// Whether anything changed since the form opened or last saved. Leaving then asks first.
  bool get isDirty => _snapshot() != _savedSnapshot;

  // Hints

  /// The total as typed, in minor units, or null if it isn't a valid amount.
  int? get amountCents => tryParseCents(_amountText.value, currency: currency);

  /// The sum of the exact shares typed so far.
  int get exactAssignedCents {
    var sum = 0;
    for (final member in group.members) {
      sum += tryParseCents(_exactText[member.userId]!.value, currency: currency) ?? 0;
    }
    return sum;
  }

  /// The sum of the percentages typed so far, in basis points.
  int get percentAssignedBp {
    var sum = 0;
    for (final member in group.members) {
      sum += tryParseBasisPoints(_percentText[member.userId]!.value) ?? 0;
    }
    return sum;
  }

  /// What's left to assign with exact shares, or null while the total isn't valid.
  int? get exactRemainingCents {
    final total = amountCents;
    if (total == null) return null;
    return total - exactAssignedCents;
  }

  /// What's left to assign with percentages, in basis points.
  int get percentRemainingBp => 10000 - percentAssignedBp;

  // Actions

  /// Adds or removes a member from an even split.
  void toggleIncluded(String userId) {
    if (included.contains(userId)) {
      included.remove(userId);
    } else {
      included.add(userId);
    }
  }

  /// Fills the percentage fields with an even split. The leftover hundredths go to the first rows.
  void splitPercentEvenly() {
    final count = group.members.length;
    final base = 10000 ~/ count;
    final leftover = 10000 % count;
    for (final (index, member) in group.members.indexed) {
      final share = index < leftover ? base + 1 : base;
      percentFields[member.userId]!.text = basisPointsToInput(share);
    }
  }

  /// Builds the JSON the API expects, or returns null and sets [fieldErrors] when the form is incomplete.
  Map<String, dynamic>? buildBody() {
    final errors = <String, String>{};
    final cents = amountCents;
    if (description.text.trim().isEmpty) errors['description'] = S.whatWasItFor;
    if (cents == null || cents <= 0) errors['amount'] = S.amountHint;

    final Map<String, dynamic> split;
    switch (splitType.value) {
      case SplitType.even:
        split = _evenSplit(errors);
      case SplitType.exact:
        split = _exactSplit(errors, cents);
      case SplitType.percent:
        split = _percentSplit(errors);
    }

    fieldErrors.assignAll(errors);
    if (errors.isNotEmpty) return null;
    return {'description': description.text.trim(), 'amountCents': cents, 'paidBy': paidBy.value, 'split': split};
  }

  Map<String, dynamic> _evenSplit(Map<String, String> errors) {
    final userIds = group.members.map((member) => member.userId).where(included.contains).toList();
    if (userIds.isEmpty) errors['split'] = S.pickSomeone;
    return {'type': 'EVEN', 'userIds': userIds};
  }

  Map<String, dynamic> _exactSplit(Map<String, String> errors, int? total) {
    final shares = <Map<String, dynamic>>[];
    for (final member in group.members) {
      final text = _exactText[member.userId]!.value.trim();
      if (text.isEmpty) continue;
      final share = tryParseCents(text, currency: currency);
      if (share == null || share < 0) {
        errors['split'] = S.checkAmountFor(member.name);
      } else if (share > 0) {
        shares.add({'userId': member.userId, 'amountCents': share});
      }
    }
    if (shares.isEmpty) errors['split'] ??= S.enterOneShare;
    if (total != null && exactRemainingCents != 0) {
      errors['split'] ??= S.sharesMustAddUpTo(formatCents(total, currency: currency));
    }
    return {'type': 'EXACT', 'shares': shares};
  }

  Map<String, dynamic> _percentSplit(Map<String, String> errors) {
    final shares = <Map<String, dynamic>>[];
    for (final member in group.members) {
      final text = _percentText[member.userId]!.value.trim();
      if (text.isEmpty) continue;
      final basisPoints = tryParseBasisPoints(text);
      if (basisPoints == null || basisPoints < 0 || basisPoints > 10000) {
        errors['split'] = S.checkPercentFor(member.name);
      } else if (basisPoints > 0) {
        shares.add({'userId': member.userId, 'basisPoints': basisPoints});
      }
    }
    if (percentAssignedBp != 10000) errors['split'] ??= S.percentMustBe100;
    return {'type': 'PERCENT', 'shares': shares};
  }

  /// Saves the form. Returns the saved expense, or null if it didn't save, with the reason in
  /// [error], [fieldErrors] or [outdated].
  ///
  /// A new expense gets an Idempotency-Key on the first tap of Save. Tapping again with the same form
  /// reuses it, so a save whose answer was lost can't create a second expense. Changing the form
  /// makes it a different request with a new key.
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
        // Retrying the same edit is safe, because the server accepts it if the stored content already matches.
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
      final changedElsewhere = e.code == 'EXPENSE_CHANGED' || e.code == 'EXPENSE_NOT_FOUND';
      if (editing != null && changedElsewhere) {
        outdated = true;
        error.value = e.message;
      } else if (e.isNetwork) {
        // The server may or may not have saved it. Tapping Save again is safe either way.
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

  // Moves server validation errors next to the form field they belong to.
  Map<String, String> _fieldErrorsFrom(ApiException e) {
    final errors = <String, String>{};
    for (final MapEntry(key: path, value: message) in e.fieldErrors.entries) {
      errors.putIfAbsent(_formFieldFor(path), () => message);
    }
    final fieldForCode = switch (e.code) {
      'SPLIT_SUM_MISMATCH' ||
      'SPLIT_PERCENT_MISMATCH' ||
      'SPLIT_EMPTY' ||
      'SPLIT_USER_NOT_MEMBER' ||
      'INVALID_PERCENT' => 'split',
      'INVALID_AMOUNT' => 'amount',
      'PAYER_NOT_MEMBER' => 'paidBy',
      _ => null,
    };
    if (fieldForCode != null) errors.putIfAbsent(fieldForCode, () => e.message);
    return errors;
  }

  // The form field a server field path belongs to, such as "split.shares.0.userId" to "split".
  static String _formFieldFor(String path) {
    if (path.startsWith('split')) return 'split';
    if (path == 'amountCents') return 'amount';
    return path;
  }

  TextEditingController _mirrored(RxString target) {
    final field = TextEditingController();
    field.addListener(() => target.value = field.text);
    return field;
  }

  @override
  void onClose() {
    description.dispose();
    amount.dispose();
    for (final field in [...exactFields.values, ...percentFields.values]) {
      field.dispose();
    }
    super.onClose();
  }
}
