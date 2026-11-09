// The group page: members, invites, balances and expenses.
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
///
/// The add expense, expense and settle up pages open on top of the group page and reuse this
/// controller while it's still on the stack.
class GroupDetailController extends GetxController {
  /// [myUserId] lets tests supply the signed-in user without an AuthService.
  GroupDetailController(this.groupId, this._groups, this._expenses, {String Function()? myUserId})
    : _myUserId = myUserId ?? (() => Get.find<AuthService>().userId ?? '');

  final String groupId;
  final GroupsRepository _groups;
  final ExpensesRepository _expenses;
  final String Function() _myUserId;

  /// The group with its members and invites, once loaded.
  final group = Rxn<Group>();

  /// Everyone's balance and the suggested payments, once loaded.
  final balances = Rxn<Balances>();
  late final _list = CursorList<Expense>((cursor) => _expenses.list(groupId, cursor: cursor));

  /// True until the first load finishes, and again while "try again" reloads.
  final loading = true.obs;

  /// Why the group couldn't load. Shown instead of the page.
  final error = RxnString();

  // Bumped by every full refresh, so an older refresh that answers late can't overwrite a newer one.
  int _refreshes = 0;

  /// The signed-in user's id.
  String get myUserId => _myUserId();

  /// The expenses loaded so far, newest first.
  RxList<Expense> get expenses => _list.items;

  /// The group's currency. USD until the group has loaded.
  String get currency => group.value?.currency ?? 'USD';

  /// The signed-in user's balance. Positive means they are owed.
  int get myNetCents => balances.value?.netOf(myUserId) ?? 0;

  /// Whether there are older expenses to load.
  bool get hasMore => _list.hasMore;

  /// Whether the next page of expenses is loading.
  bool get loadingMore => _list.loadingMore;

  /// Whether the last attempt to load more failed.
  bool get loadMoreFailed => _list.loadMoreFailed;

  /// Whether the expense list may fetch the next page on its own. False after a failure, until
  /// the user taps "load more".
  bool get shouldAutoLoad => _list.shouldAutoLoad;

  /// Whether nobody owes anybody.
  bool get isSettled => balances.value?.transfers.isEmpty ?? true;

  @override
  void onInit() {
    super.onInit();
    unawaited(load());
  }

  /// Loads the group, its balances and the first page of expenses together.
  Future<void> load() async {
    error.value = null;
    _refreshes++;
    final refresh = _refreshes;
    try {
      final results = await Future.wait<Object>([
        _groups.get(groupId),
        _groups.balances(groupId),
        _expenses.list(groupId),
      ]);
      if (refresh != _refreshes) return;
      group.value = results[0] as Group;
      balances.value = results[1] as Balances;
      _list.setFirstPage(results[2] as ExpensePage);
    } on GroupNotFoundException {
      groupGone();
    } on ApiException catch (e) {
      if (refresh != _refreshes) return;
      if (group.value == null) {
        error.value = e.message;
      } else {
        notify(S.couldNotRefresh, e.message);
      }
    } finally {
      loading.value = false;
    }
  }

  /// "Try again" on the error page. It shows the loading skeleton while it loads.
  Future<void> retry() {
    loading.value = true;
    return load();
  }

  /// Pull-to-refresh. Reloads everything, members and invites included.
  Future<void> refreshAll() => load();

  /// Reloads the balances and the first page of expenses after any write. We never patch numbers
  /// locally, because the server is the only authority on balances. A "load more" still in flight
  /// is discarded.
  Future<void> refreshAfterWrite() async {
    _refreshes++;
    final refresh = _refreshes;
    try {
      final results = await Future.wait<Object>([_groups.balances(groupId), _expenses.list(groupId)]);
      if (refresh != _refreshes) return;
      balances.value = results[0] as Balances;
      _list.setFirstPage(results[1] as ExpensePage);
    } on GroupNotFoundException {
      groupGone();
    } on ApiException catch (e) {
      if (refresh == _refreshes) notify(S.couldNotRefresh, e.message);
    }
  }

  /// Reloads only the balances.
  Future<void> refreshBalances() async {
    try {
      balances.value = await _groups.balances(groupId);
    } on GroupNotFoundException {
      groupGone();
    } on ApiException catch (e) {
      notify(S.couldNotRefresh, e.message);
    }
  }

  /// Appends the next page of expenses. A failure stops automatic loading until this is called again
  /// from the button.
  Future<void> loadMore() async {
    try {
      await _list.loadMore();
    } on GroupNotFoundException {
      groupGone();
    } on ApiException catch (e) {
      notify(S.couldNotLoadMore, e.message);
    }
  }

  // Expenses

  /// Swaps in the server's new version of an expense, after an edit or a receipt upload.
  void replaceExpense(Expense updated) {
    final index = expenses.indexWhere((expense) => expense.id == updated.id);
    if (index >= 0) expenses[index] = updated;
  }

  /// Drops an expense from the list after it was deleted.
  void removeExpense(String expenseId) => _list.removeWhere((expense) => expense.id == expenseId);

  /// Finds the latest version of one expense by paging through the list, since the API has no route
  /// for a single expense. Returns null if it was deleted or is older than [maxPages] pages.
  Future<Expense?> findExpense(String expenseId, {int maxPages = 10}) async {
    String? cursor;
    for (var i = 0; i < maxPages; i++) {
      final page = await _expenses.list(groupId, cursor: cursor, limit: 50);
      final found = page.items.firstWhereOrNull((expense) => expense.id == expenseId);
      if (found != null) return found;
      cursor = page.nextCursor;
      if (cursor == null) return null;
    }
    return null;
  }

  // Members and invites. Each action returns a message to show, or null on success.

  /// Invites [email] to the group.
  Future<String?> invite(String email) async {
    final address = email.trim();
    if (!isValidEmail(address)) return S.enterValidEmail;
    return _groupWrite(() => _groups.invite(groupId, address), field: 'email');
  }

  /// Withdraws an invite. If it was accepted or cancelled in the meantime, the group reloads instead.
  Future<String?> cancelInvite(GroupInvite invite) async {
    try {
      group.value = await _groups.cancelInvite(groupId, invite.id);
      return null;
    } on GroupNotFoundException {
      groupGone();
      return null;
    } on ApiException catch (e) {
      if (e.code != 'INVITE_NOT_FOUND') return e.message;
      unawaited(refreshAll());
      return null;
    }
  }

  /// Removes another member. Refused while that member's balance isn't zero.
  Future<String?> removeMember(Member member) async {
    final message = await _groupWrite(
      () => _groups.removeMember(groupId, member.userId),
      balanceBlocked: S.removeBlocked,
    );
    if (message == null) await refreshBalances();
    return message;
  }

  /// Renames the group, checking the name locally first.
  Future<String?> rename(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return S.giveGroupName;
    if (trimmed.length > 80) return S.groupNameTooLong;
    return _groupWrite(() => _groups.rename(groupId, trimmed), field: 'name');
  }

  /// Leaves the group and goes back to the groups list. Refused while the user's balance isn't zero.
  Future<String?> leave() => _exit(() => _groups.leave(groupId), done: S.leftGroup, blocked: S.leaveBlocked);

  /// Deletes the group for everyone and goes back to the groups list.
  Future<String?> deleteGroup() => _exit(() => _groups.delete(groupId), done: S.groupDeleted);

  // Runs a write that returns the updated group. [field] picks a server validation error to show
  // in place of the generic message.
  Future<String?> _groupWrite(Future<Group> Function() request, {String? field, String? balanceBlocked}) async {
    try {
      group.value = await request();
      return null;
    } on GroupNotFoundException {
      groupGone();
      return null;
    } on ApiException catch (e) {
      if (e.code == 'BALANCE_NOT_ZERO' && balanceBlocked != null) return balanceBlocked;
      final fieldError = field == null ? null : e.fieldErrors[field];
      return fieldError ?? e.message;
    }
  }

  // Leaves or deletes the group, then goes back to the groups list.
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

  /// Handles `GROUP_NOT_FOUND`: the user was removed from the group, or it never existed. Either way
  /// we go back to the groups list and say so.
  void groupGone() {
    unawaited(Get.offAllNamed<void>(Routes.groups));
    notify(S.groupUnavailable, S.noLongerMember);
  }
}
