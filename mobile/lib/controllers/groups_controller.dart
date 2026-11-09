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

/// The groups tab: my groups, newest first, a page at a time.
/// Refetches quietly when the app comes back to the foreground (and the page asks again when the
/// person comes back to it from a group), so changes made elsewhere show up.
class GroupsController extends GetxController with WidgetsBindingObserver {
  GroupsController(this._groups, this._users);

  final GroupsRepository _groups;
  final UserRepository _users;

  late final list = CursorList<Group>((cursor) => _groups.list(cursor: cursor));
  RxList<Group> get groups => list.items;
  final loading = true.obs;
  final error = RxnString();
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

  Future<void> loadMe() async {
    try {
      me.value = await _users.me();
    } on ApiException {
      // Only the avatar uses it.
    }
  }

  /// First load and pull-to-refresh. With groups already on screen a failure is a snackbar,
  /// not an error page.
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

  /// "Try again" on the error page: show the skeleton, not a flash of the empty state.
  Future<void> retry() {
    loading.value = true;
    return load();
  }

  /// Back on the list or the app resumed: refetch without a skeleton, keep what's shown on failure.
  Future<void> refreshQuietly() async {
    if (loading.value) return;
    try {
      await list.reload();
      error.value = null;
    } on ApiException {
      // The list on screen stays; pull-to-refresh says what's wrong.
    }
  }

  Future<void> loadMore() async {
    try {
      await list.loadMore();
    } on ApiException catch (e) {
      notify(S.couldNotLoadMore, e.message);
    }
  }

  /// Returns an error message, or null on success (and opens the new group).
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

  /// An invite was accepted: show the group at once, then the server's list.
  void joined(Group group) {
    if (!groups.any((g) => g.id == group.id)) groups.insert(0, group);
    unawaited(refreshQuietly());
  }
}
