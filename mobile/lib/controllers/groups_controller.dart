// The groups tab on the home page.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../app/notify.dart';
import '../app/routes.dart';
import '../app/strings.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';
import 'paging.dart';

/// The user's groups, newest first, a page at a time.
///
/// The list refreshes quietly when the app returns to the foreground, and the page asks for a refresh
/// when the user comes back from a group, so changes made elsewhere show up.
class GroupsController extends GetxController with WidgetsBindingObserver {
  GroupsController(this._groups, this._users);

  final GroupsRepository _groups;
  final UserRepository _users;

  /// The paged list behind [groups].
  late final list = CursorList<Group>((cursor) => _groups.list(cursor: cursor));

  /// The groups loaded so far.
  RxList<Group> get groups => list.items;

  /// True until the first load finishes, and again while "try again" reloads.
  final loading = true.obs;

  /// Why the first page couldn't load. Shown instead of the list.
  final error = RxnString();

  /// The user's profile, for the account button in the app bar.
  final me = Rxn<Me>();

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
    unawaited(load());
    unawaited(loadMe());
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refreshQuietly());
  }

  /// Loads the profile. A failure is ignored because only the account button uses it.
  Future<void> loadMe() async {
    try {
      me.value = await _users.me();
    } on ApiException {
      // The account button works without a name.
    }
  }

  /// The first load and pull-to-refresh. If groups are already on screen, a failure is a snackbar
  /// rather than an error page.
  Future<void> load() async {
    error.value = null;
    try {
      await list.reload();
    } on ApiException catch (e) {
      if (groups.isEmpty) {
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

  /// Refetches without a skeleton, for coming back to the list or the app resuming. On failure the
  /// list on screen stays as it is.
  Future<void> refreshQuietly() async {
    if (loading.value) return;
    try {
      await list.reload();
      error.value = null;
    } on ApiException {
      // Pull-to-refresh will say what's wrong if the user tries.
    }
  }

  /// Appends the next page.
  Future<void> loadMore() async {
    try {
      await list.loadMore();
    } on ApiException catch (e) {
      notify(S.couldNotLoadMore, e.message);
    }
  }

  /// Creates a group and opens it. Returns null on success, or a message for the form.
  Future<String?> create(String name, String currency) async {
    try {
      final group = await _groups.create(name: name.trim(), currency: currency);
      groups.insert(0, group);
      unawaited(Get.toNamed<void>(Routes.groupPath(group.id)));
      return null;
    } on ApiException catch (e) {
      return e.fieldErrors['name'] ?? e.message;
    }
  }

  /// Called after an invite is accepted. The group shows at once, then the list refreshes from the server.
  void joined(Group group) {
    final alreadyListed = groups.any((listed) => listed.id == group.id);
    if (!alreadyListed) groups.insert(0, group);
    unawaited(refreshQuietly());
  }
}
