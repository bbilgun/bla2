// Invites addressed to the user, shown above the groups list.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../app/notify.dart';
import '../app/strings.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';

/// The user's pending invites, to accept or decline. They are fetched again whenever the app comes
/// back to the foreground, since someone may have sent one in the meantime.
class InvitesController extends GetxController with WidgetsBindingObserver {
  InvitesController(this._invites);

  final InvitesRepository _invites;

  /// The pending invites.
  final invites = <PendingInvite>[].obs;

  /// Ids of invites with a request in flight. Their buttons are disabled.
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

  /// Fetches the invites. Failures are ignored, since the groups list matters more and the next
  /// refresh tries again.
  Future<void> load() async {
    try {
      invites.assignAll(await _invites.list());
    } on ApiException {
      // Leave the current list as it is.
    }
  }

  /// Whether a request for [invite] is running.
  bool isBusy(PendingInvite invite) => busy.contains(invite.id);

  /// Joins the group. Returns it, or null after showing a snackbar about what went wrong.
  Future<Group?> accept(PendingInvite invite) async {
    if (!busy.add(invite.id)) return null;
    try {
      final group = await _invites.accept(invite);
      _remove(invite);
      notify(S.joinedGroup, group.name);
      return group;
    } on ApiException catch (e) {
      // The invite is gone: it was cancelled, or our own earlier accept worked but its answer was lost.
      if (e.code == 'INVITE_NOT_FOUND') _remove(invite);
      notify(S.actionFailed, e.message);
      return null;
    } finally {
      busy.remove(invite.id);
    }
  }

  /// Turns the invite down. Returns whether it's gone from the list.
  Future<bool> decline(PendingInvite invite) async {
    if (!busy.add(invite.id)) return false;
    try {
      await _invites.decline(invite);
      _remove(invite);
      notify(S.inviteDeclined, invite.groupName);
      return true;
    } on ApiException catch (e) {
      if (e.code == 'INVITE_NOT_FOUND') {
        _remove(invite);
        return true;
      }
      notify(S.actionFailed, e.message);
      return false;
    } finally {
      busy.remove(invite.id);
    }
  }

  void _remove(PendingInvite invite) => invites.removeWhere((other) => other.id == invite.id);
}
