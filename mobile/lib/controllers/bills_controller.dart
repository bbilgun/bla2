// The bills tab on the home page.
import 'dart:async';

import 'package:get/get.dart';

import '../app/notify.dart';
import '../app/routes.dart';
import '../app/strings.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';
import 'paging.dart';

/// The bills the user hosts, newest first, a page at a time.
class BillsController extends GetxController {
  BillsController(this._bills);

  final BillsRepository _bills;

  /// The paged list behind [bills].
  late final list = CursorList<BillSummary>((cursor) => _bills.list(cursor: cursor));

  /// The bills loaded so far.
  RxList<BillSummary> get bills => list.items;

  /// True until the first load finishes, and again while "try again" reloads.
  final loading = true.obs;

  /// Why the first page couldn't load. Shown instead of the list.
  final error = RxnString();

  @override
  void onInit() {
    super.onInit();
    unawaited(load());
  }

  /// Loads the first page. If bills are already on screen, a failure is a snackbar, not an error page.
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

  /// "Try again" on the error page. It shows the loading skeleton rather than a flash of the empty state.
  Future<void> retry() {
    loading.value = true;
    return load();
  }

  /// Appends the next page.
  Future<void> loadMore() async {
    try {
      await list.loadMore();
    } on ApiException catch (e) {
      notify(S.couldNotLoadMore, e.message);
    }
  }

  /// Opens the bill editor. A saved bill goes straight to its QR page. The list reloads either way.
  Future<void> create() async {
    final created = await Get.toNamed<Object?>(Routes.newBill);
    unawaited(load());
    if (created is Bill) await open(created.id);
  }

  /// Opens a bill, and reloads the list when the user comes back.
  Future<void> open(String id) async {
    await Get.toNamed<void>(Routes.billPath(id));
    await load();
  }
}
