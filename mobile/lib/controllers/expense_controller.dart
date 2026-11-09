import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';

import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';
import 'group_detail_controller.dart';

/// One expense and its receipt photo.
class ExpenseController extends GetxController {
  ExpenseController(this.detail, this.expenseId, this._receipts, {ImagePicker? picker})
    : _picker = picker ?? ImagePicker();

  final GroupDetailController detail;
  final String expenseId;
  final ReceiptsRepository _receipts;
  final ImagePicker _picker;

  final receiptUrl = RxnString();
  final loadingReceipt = false.obs;
  final uploading = false.obs;
  final error = RxnString();

  Expense? get expense => detail.expenses.firstWhereOrNull((e) => e.id == expenseId);

  @override
  void onInit() {
    super.onInit();
    if (expense?.hasReceipt ?? false) loadReceipt();
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

  /// Pick a photo, ask Lambda for a presigned PUT, upload straight to S3, then show it.
  Future<void> attachReceipt(ImageSource source) async {
    final file = await _picker.pickImage(source: source, maxWidth: 2000, imageQuality: 80);
    if (file == null) return;
    uploading.value = true;
    error.value = null;
    try {
      final bytes = await file.readAsBytes();
      final name = file.name.toLowerCase();
      final contentType = name.endsWith('.png')
          ? 'image/png'
          : name.endsWith('.heic')
          ? 'image/heic'
          : 'image/jpeg';
      await _receipts.upload(detail.groupId, expenseId, bytes, contentType: contentType);
      detail.markReceiptAttached(expenseId);
      await loadReceipt();
    } on ApiException catch (e) {
      error.value = e.message;
    } finally {
      uploading.value = false;
    }
  }
}
