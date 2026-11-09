import 'package:get/get.dart';

import '../app/routes.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';

/// The "Тооцоо" tab: the host's bills, newest first.
class BillsController extends GetxController {
  BillsController(this._bills);

  final BillsRepository _bills;

  final bills = <BillSummary>[].obs;
  final loading = true.obs;
  final error = RxnString();

  @override
  void onInit() {
    super.onInit();
    load();
  }

  Future<void> load() async {
    error.value = null;
    try {
      bills.assignAll(await _bills.list());
    } on ApiException catch (e) {
      error.value = e.message;
    } finally {
      loading.value = false;
    }
  }

  /// New bill -> straight to its QR. The list reloads when the person comes back.
  Future<void> create() async {
    final created = await Get.toNamed(Routes.newBill);
    load();
    if (created is Bill) await open(created.id);
  }

  Future<void> open(String id) async {
    await Get.toNamed(Routes.billPath(id));
    load();
  }
}
