import 'dart:async';

import 'package:get/get.dart';

import '../app/notify.dart';
import '../app/routes.dart';
import '../app/strings.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';
import 'paging.dart';

/// The "Тооцоо" tab: the host's bills, newest first, a page at a time.
class BillsController extends GetxController {
  BillsController(this._bills);

  final BillsRepository _bills;

  late final list = CursorList<BillSummary>((cursor) => _bills.list(cursor: cursor));
  RxList<BillSummary> get bills => list.items;
  final loading = true.obs;
  final error = RxnString();

  @override
  void onInit() {
    super.onInit();
    unawaited(load());
  }

  Future<void> load() async {
    error.value = null;
    try {
      await list.reload();
    } on ApiException catch (e) {
      if (bills.isEmpty) {
        error.value = e.message;
      } else {
        notify(S.couldNotRefresh, e.message);
      }
    } finally {
      loading.value = false;
    }
  }

  /// "Try again": show the skeleton, not a flash of the empty state.
  Future<void> retry() {
    loading.value = true;
    return load();
  }

  Future<void> loadMore() async {
    try {
      await list.loadMore();
    } on ApiException catch (e) {
      notify(S.couldNotLoadMore, e.message);
    }
  }

  /// New bill -> straight to its QR. The list reloads when the person comes back, saved or not.
  Future<void> create() async {
    final created = await Get.toNamed<Object?>(Routes.newBill);
    unawaited(load());
    if (created is Bill) await open(created.id);
  }

  Future<void> open(String id) async {
    await Get.toNamed<void>(Routes.billPath(id));
    await load();
  }
}
