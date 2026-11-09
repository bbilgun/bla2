import 'dart:async';

import 'package:get/get.dart';

import '../app/notify.dart';
import '../app/routes.dart';
import '../app/strings.dart';
import '../domain/validators.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import 'paging.dart';

/// One group: its members, invites, balances and expense history.
/// The add-expense, expense and settle-up pages reuse this controller while it's on the stack.
class GroupDetailController extends GetxController {
  GroupDetailController(this.groupId, this._groups, this._expenses, {String Function()? myUserId})
    : _myUserId = myUserId ?? (() => Get.find<AuthService>().userId ?? '');

  final String groupId;
  final GroupsRepository _groups;
  final ExpensesRepository _expenses;
  final String Function() _myUserId;

  final group = Rxn<Group>();
  final balances = Rxn<Balances>();
  late final _list = CursorList<Expense>((cursor) => _expenses.list(groupId, cursor: cursor));
  final loading = true.obs;
  final error = RxnString();

  /// Bumped by every full refresh, so an older refresh that answers late can't overwrite a newer one.
  int _refreshes = 0;

  String get myUserId => _myUserId();

  // Plain getters over .obs. Obx tracks the .obs these read, so the UI updates when they change.
  // (A getter that *returns* a new .obs, like `RxInt get x => (a + b).obs`, is never tracked.)
  RxList<Expense> get expenses => _list.items;
  String get currency => group.value?.currency ?? 'USD';
  int get myNetCents => balances.value?.netOf(myUserId) ?? 0;
  bool get hasMore => _list.hasMore;
  bool get loadingMore => _list.loadingMore;
  bool get loadMoreFailed => _list.loadMoreFailed;

  /// The expense list may fetch the next page on its own. False after a failure, until "load more".
  bool get shouldAutoLoad => _list.shouldAutoLoad;
  bool get isSettled => balances.value?.transfers.isEmpty ?? true;

  @override
  void onInit() {
    super.onInit();
    unawaited(load());
  }

  /// Group, balances and the first page of expenses.
  Future<void> load() async {
    error.value = null;
    final gen = ++_refreshes;
    try {
      final results = await Future.wait<Object>([
        _groups.get(groupId),
        _groups.balances(groupId),
        _expenses.list(groupId),
      ]);
      if (gen != _refreshes) return;
      group.value = results[0] as Group;
      balances.value = results[1] as Balances;
      _list.setFirstPage(results[2] as ExpensePage);
    } on GroupNotFoundException {
      groupGone();
    } on ApiException catch (e) {
      if (gen != _refreshes) return;
      if (group.value == null) {
        error.value = e.message;
      } else {
        notify(S.couldNotRefresh, e.message);
      }
    } finally {
      loading.value = false;
    }
  }

  /// "Try again": show the skeleton while it loads.
  Future<void> retry() {
    loading.value = true;
    return load();
  }

  /// Pull-to-refresh: everything, members and invites included.
  Future<void> refreshAll() => load();

  /// After any write, reload from the server instead of patching numbers locally:
  /// the server is the only authority on balances. A "load more" still in flight is discarded.
  Future<void> refreshAfterWrite() async {
    final gen = ++_refreshes;
    try {
      final results = await Future.wait<Object>([_groups.balances(groupId), _expenses.list(groupId)]);
      if (gen != _refreshes) return;
      balances.value = results[0] as Balances;
      _list.setFirstPage(results[1] as ExpensePage);
    } on GroupNotFoundException {
      groupGone();
    } on ApiException catch (e) {
      if (gen == _refreshes) notify(S.couldNotRefresh, e.message);
    }
  }

  Future<void> refreshBalances() async {
    try {
      balances.value = await _groups.balances(groupId);
    } on GroupNotFoundException {
      groupGone();
    } on ApiException catch (e) {
      notify(S.couldNotRefresh, e.message);
    }
  }

  /// The next page. A failure stops the automatic loading until this is called again (the button).
  Future<void> loadMore() async {
    try {
      await _list.loadMore();
    } on GroupNotFoundException {
      groupGone();
    } on ApiException catch (e) {
      notify(S.couldNotLoadMore, e.message);
    }
  }

  // ---------------------------------------------------------------- expenses

  /// The server's new version of an expense (edited, receipt attached), in place in the list.
  void replaceExpense(Expense updated) {
    final i = expenses.indexWhere((e) => e.id == updated.id);
    if (i >= 0) expenses[i] = updated;
  }

  void removeExpense(String expenseId) => _list.removeWhere((e) => e.id == expenseId);

  /// The latest version of one expense, looked up page by page (there's no single-expense route).
  /// Null if it's gone (deleted) or very old.
  Future<Expense?> findExpense(String expenseId, {int maxPages = 10}) async {
    String? cursor;
    for (var i = 0; i < maxPages; i++) {
      final page = await _expenses.list(groupId, cursor: cursor, limit: 50);
      final found = page.items.firstWhereOrNull((e) => e.id == expenseId);
      if (found != null) return found;
      cursor = page.nextCursor;
      if (cursor == null) return null;
    }
    return null;
  }

  // ---------------------------------------------------------------- members and invites
  // Each returns an error message to show, or null on success.

  Future<String?> invite(String email) async {
    final address = email.trim();
    if (!isValidEmail(address)) return S.enterValidEmail;
    return _groupWrite(() => _groups.invite(groupId, address), field: 'email');
  }

  Future<String?> cancelInvite(GroupInvite invite) async {
    try {
      group.value = await _groups.cancelInvite(groupId, invite.id);
      return null;
    } on GroupNotFoundException {
      groupGone();
      return null;
    } on ApiException catch (e) {
      if (e.code != 'INVITE_NOT_FOUND') return e.message;
      unawaited(refreshAll()); // accepted or cancelled meanwhile: show the group as it is now
      return null;
    }
  }

  Future<String?> removeMember(Member member) async {
    final message = await _groupWrite(
      () => _groups.removeMember(groupId, member.userId),
      balanceBlocked: S.removeBlocked,
    );
    if (message == null) await refreshBalances();
    return message;
  }

  Future<String?> rename(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return S.giveGroupName;
    if (trimmed.length > 80) return S.groupNameTooLong;
    return _groupWrite(() => _groups.rename(groupId, trimmed), field: 'name');
  }

  Future<String?> leave() => _exit(() => _groups.leave(groupId), done: S.leftGroup, blocked: S.leaveBlocked);

  Future<String?> deleteGroup() => _exit(() => _groups.delete(groupId), done: S.groupDeleted);

  Future<String?> _groupWrite(Future<Group> Function() request, {String? field, String? balanceBlocked}) async {
    try {
      group.value = await request();
      return null;
    } on GroupNotFoundException {
      groupGone();
      return null;
    } on ApiException catch (e) {
      if (e.code == 'BALANCE_NOT_ZERO' && balanceBlocked != null) return balanceBlocked;
      return (field == null ? null : e.fieldErrors[field]) ?? e.message;
    }
  }

  /// Leave or delete: on success, back to the groups list.
  Future<String?> _exit(Future<void> Function() request, {required String done, String? blocked}) async {
    try {
      await request();
      unawaited(Get.offAllNamed<void>(Routes.groups));
      notify(done, group.value?.name ?? '');
      return null;
    } on GroupNotFoundException {
      groupGone();
      return null;
    } on ApiException catch (e) {
      if (e.code == 'BALANCE_NOT_ZERO' && blocked != null) return blocked;
      return e.message;
    }
  }

  /// GROUP_NOT_FOUND: removed from the group, or it never existed. Either way, back to the list.
  void groupGone() {
    unawaited(Get.offAllNamed<void>(Routes.groups));
    notify(S.groupUnavailable, S.noLongerMember);
  }
}
