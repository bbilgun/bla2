import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../app/notify.dart';
import '../app/strings.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';

/// Invites to me, shown on top of the groups list: accept to join, or decline.
/// Refetched when the app comes back to the foreground (someone may have invited me meanwhile).
class InvitesController extends GetxController with WidgetsBindingObserver {
  InvitesController(this._invites);

  final InvitesRepository _invites;

  final invites = <PendingInvite>[].obs;

  /// Invite ids with a request in flight: their buttons are disabled.
  final busy = <String>{}.obs;

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
    unawaited(load());
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(load());
  }

  Future<void> load() async {
    try {
      invites.assignAll(await _invites.list());
    } on ApiException {
      // Secondary to the groups list; the next refresh tries again.
    }
  }

  bool isBusy(PendingInvite invite) => busy.contains(invite.id);

  /// Returns the group I joined, or null (a snackbar says why).
  Future<Group?> accept(PendingInvite invite) async {
    if (!busy.add(invite.id)) return null;
    try {
      final group = await _invites.accept(invite);
      invites.removeWhere((i) => i.id == invite.id);
      notify(S.joinedGroup, group.name);
      return group;
    } on ApiException catch (e) {
      // Gone: cancelled, or our own earlier accept went through but its answer was lost.
      if (e.code == 'INVITE_NOT_FOUND') invites.removeWhere((i) => i.id == invite.id);
      notify(S.actionFailed, e.message);
      return null;
    } finally {
      busy.remove(invite.id);
    }
  }

  Future<bool> decline(PendingInvite invite) async {
    if (!busy.add(invite.id)) return false;
    try {
      await _invites.decline(invite);
      invites.removeWhere((i) => i.id == invite.id);
      notify(S.inviteDeclined, invite.groupName);
      return true;
    } on ApiException catch (e) {
      if (e.code == 'INVITE_NOT_FOUND') {
        invites.removeWhere((i) => i.id == invite.id);
        return true;
      }
      notify(S.actionFailed, e.message);
      return false;
    } finally {
      busy.remove(invite.id);
    }
  }
}
