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

  final GroupDetailController detail;
  final String expenseId;
  final ReceiptsRepository _receipts;
  final ExpensesRepository _expenses;
  final PhotoPicker _picker;

  final receiptUrl = RxnString();
  final loadingReceipt = false.obs;
  final uploading = false.obs;
  final deleting = false.obs;
  final error = RxnString();

  /// The newest version we've seen, for when it isn't among the group's loaded pages.
  final _latest = Rxn<Expense>();

  Expense? get expense => detail.expenses.firstWhereOrNull((e) => e.id == expenseId) ?? _latest.value;

  @override
  void onInit() {
    super.onInit();
    _latest.value = detail.expenses.firstWhereOrNull((e) => e.id == expenseId);
    if (expense?.hasReceipt ?? false) unawaited(loadReceipt());
  }

  void _apply(Expense updated) {
    _latest.value = updated;
    detail.replaceExpense(updated);
  }

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

  /// Opens the form in edit mode. Saved: the server's version replaces ours and balances reload.
  /// Anything else (backed out, changed by someone else, offline): reload from the server.
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

  /// Group balances, the first page, and this expense's newest version (or that it's gone).
  Future<void> reload() async {
    await detail.refreshAfterWrite();
    if (detail.expenses.any((e) => e.id == expenseId)) return;
    try {
      final found = await detail.findExpense(expenseId);
      if (found != null) {
        _apply(found);
      } else {
        _latest.value = null;
      }
    } on ApiException {
      // Keep showing what we have; the group page is already up to date.
    }
  }

  /// Returns true once it's deleted (the page then closes).
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
      // Not found: someone else deleted it already, which is what we wanted.
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

  /// Pick a photo, ask Lambda for a presigned POST, upload straight to S3, confirm, then show it.
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
      _apply(await _receipts.upload(detail.groupId, expenseId, photo.bytes, contentType: photo.contentType));
      await loadReceipt();
    } on ApiException catch (e) {
      error.value = e.message;
    } finally {
      uploading.value = false;
    }
  }
}
