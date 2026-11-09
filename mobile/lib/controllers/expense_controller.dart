// The expense detail page.
import 'dart:async';

import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';

import '../app/notify.dart';
import '../app/routes.dart';
import '../app/strings.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';
import '../services/photo_picker.dart';
import 'group_detail_controller.dart';

/// One expense: its splits and receipt photo, and editing or deleting it.
class ExpenseController extends GetxController {
  ExpenseController(this.detail, this.expenseId, this._receipts, this._expenses, {PhotoPicker? picker})
    : _picker = picker ?? PhotoPicker();

  /// The group page underneath, which owns the expense list.
  final GroupDetailController detail;
  final String expenseId;
  final ReceiptsRepository _receipts;
  final ExpensesRepository _expenses;
  final PhotoPicker _picker;

  /// Download URL of the receipt photo, once fetched.
  final receiptUrl = RxnString();

  /// True while the receipt URL is being fetched.
  final loadingReceipt = false.obs;

  /// True while a receipt photo uploads.
  final uploading = false.obs;

  /// True while the delete request runs.
  final deleting = false.obs;

  /// The last failure, shown on the page.
  final error = RxnString();

  // The newest version we've seen, for when it isn't among the group's loaded pages.
  final _latest = Rxn<Expense>();

  /// The expense, or null once it has been deleted.
  Expense? get expense => _findLoaded() ?? _latest.value;

  @override
  void onInit() {
    super.onInit();
    _latest.value = _findLoaded();
    if (expense?.hasReceipt ?? false) unawaited(loadReceipt());
  }

  Expense? _findLoaded() => detail.expenses.firstWhereOrNull((loaded) => loaded.id == expenseId);

  void _apply(Expense updated) {
    _latest.value = updated;
    detail.replaceExpense(updated);
  }

  /// Fetches a download URL for the receipt photo.
  Future<void> loadReceipt() async {
    loadingReceipt.value = true;
    try {
      receiptUrl.value = await _receipts.viewUrl(detail.groupId, expenseId);
    } on ApiException catch (e) {
      if (e.code != 'RECEIPT_NOT_FOUND') error.value = e.message;
    } finally {
      loadingReceipt.value = false;
    }
  }

  /// Opens the form in edit mode. If it saved, the server's version replaces ours and the balances
  /// reload. After backing out, a conflict or a network failure, we reload from the server instead.
  Future<void> edit() async {
    final result = await Get.toNamed<Object?>(Routes.editExpensePath(detail.groupId, expenseId));
    if (result is Expense) {
      _apply(result);
      notify(S.expenseSaved);
      await detail.refreshBalances();
    } else {
      await reload();
    }
  }

  /// Refreshes the group's balances and first page, then finds this expense's newest version, or
  /// learns that it's gone.
  Future<void> reload() async {
    await detail.refreshAfterWrite();
    if (detail.expenses.any((loaded) => loaded.id == expenseId)) return;
    try {
      final found = await detail.findExpense(expenseId);
      if (found != null) {
        _apply(found);
      } else {
        _latest.value = null;
      }
    } on ApiException {
      // Keep showing what we have. The group page is already up to date.
    }
  }

  /// Deletes the expense. Returns true once it's gone, and the page then closes.
  Future<bool> delete() async {
    if (deleting.value) return false;
    deleting.value = true;
    error.value = null;
    try {
      await _expenses.delete(detail.groupId, expenseId);
    } on GroupNotFoundException {
      detail.groupGone();
      return false;
    } on ApiException catch (e) {
      // Someone else already deleted it, which is what we wanted.
      if (e.code != 'EXPENSE_NOT_FOUND') {
        error.value = e.message;
        return false;
      }
    } finally {
      deleting.value = false;
    }
    detail.removeExpense(expenseId);
    _latest.value = null;
    notify(S.expenseDeleted);
    unawaited(detail.refreshAfterWrite());
    return true;
  }

  /// Lets the user pick a photo, uploads it as the receipt, then shows it.
  Future<void> attachReceipt(ImageSource source) async {
    error.value = null;
    final PickedPhoto? photo;
    try {
      photo = await _picker.pick(source);
    } on PhotoPickException catch (e) {
      error.value = e.message;
      return;
    }
    if (photo == null) return;
    uploading.value = true;
    try {
      final updated = await _receipts.upload(detail.groupId, expenseId, photo.bytes, contentType: photo.contentType);
      _apply(updated);
      await loadReceipt();
    } on ApiException catch (e) {
      error.value = e.message;
    } finally {
      uploading.value = false;
    }
  }
}
