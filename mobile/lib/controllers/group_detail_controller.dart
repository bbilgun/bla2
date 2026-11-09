import 'package:get/get.dart';

import '../app/routes.dart';
import '../app/strings.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';

/// One group: its members, balances and expense history.
/// The add-expense, expense and settle-up pages reuse this controller while it's on the stack.
class GroupDetailController extends GetxController {
  GroupDetailController(this.groupId, this._groups, this._expenses);

  final String groupId;
  final GroupsRepository _groups;
  final ExpensesRepository _expenses;

  final group = Rxn<Group>();
  final balances = Rxn<Balances>();
  final expenses = <Expense>[].obs;
  final loading = true.obs;
  final loadingMore = false.obs;
  final error = RxnString();
  String? _cursor;
  final _hasMore = false.obs;

  String get myUserId => Get.find<AuthService>().userId ?? '';

  // Plain getters over .obs. Obx tracks the .obs these read, so the UI updates when they change.
  // (A getter that *returns* a new .obs, like `RxInt get x => (a + b).obs`, is never tracked.)
  String get currency => group.value?.currency ?? 'USD';
  int get myNetCents => balances.value?.netOf(myUserId) ?? 0;
  bool get hasMore => _hasMore.value;
  bool get isSettled => balances.value?.transfers.isEmpty ?? true;

  @override
  void onInit() {
    super.onInit();
    load();
  }

  Future<void> load() async {
    error.value = null;
    try {
      final results = await Future.wait([_groups.get(groupId), _groups.balances(groupId), _expenses.list(groupId)]);
      group.value = results[0] as Group;
      balances.value = results[1] as Balances;
      _applyFirstPage(results[2] as ExpensePage);
    } on GroupNotFoundException {
      _leave();
    } on ApiException catch (e) {
      error.value = e.message;
    } finally {
      loading.value = false;
    }
  }

  /// After any write, reload from the server instead of patching numbers locally:
  /// the server is the only authority on balances.
  Future<void> refreshAfterWrite() async {
    try {
      final results = await Future.wait([_groups.balances(groupId), _expenses.list(groupId)]);
      balances.value = results[0] as Balances;
      _applyFirstPage(results[1] as ExpensePage);
    } on GroupNotFoundException {
      _leave();
    } on ApiException catch (e) {
      Get.snackbar(S.couldNotRefresh, e.message, snackPosition: SnackPosition.BOTTOM);
    }
  }

  Future<void> loadMore() async {
    final cursor = _cursor;
    if (cursor == null || loadingMore.value) return;
    loadingMore.value = true;
    try {
      final page = await _expenses.list(groupId, cursor: cursor);
      expenses.addAll(page.items);
      _cursor = page.nextCursor;
      _hasMore.value = page.nextCursor != null;
    } on GroupNotFoundException {
      _leave();
    } on ApiException catch (e) {
      Get.snackbar(S.couldNotLoadMore, e.message, snackPosition: SnackPosition.BOTTOM);
    } finally {
      loadingMore.value = false;
    }
  }

  /// Returns an error message, or null on success.
  Future<String?> addMember(String email) async {
    try {
      group.value = await _groups.addMember(groupId, email.trim());
      balances.value = await _groups.balances(groupId);
      return null;
    } on GroupNotFoundException {
      _leave();
      return null;
    } on ApiException catch (e) {
      return e.fieldErrors['email'] ?? e.message;
    }
  }

  void markReceiptAttached(String expenseId) {
    final i = expenses.indexWhere((e) => e.id == expenseId);
    if (i >= 0) expenses[i] = expenses[i].copyWith(hasReceipt: true);
  }

  void _applyFirstPage(ExpensePage page) {
    expenses.assignAll(page.items);
    _cursor = page.nextCursor;
    _hasMore.value = page.nextCursor != null;
  }

  /// GROUP_NOT_FOUND: removed from the group, or it never existed. Either way, back to the list.
  void _leave() {
    Get.offAllNamed(Routes.groups);
    Get.snackbar(S.groupUnavailable, S.noLongerMember, snackPosition: SnackPosition.BOTTOM);
  }
}
