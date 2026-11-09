import 'dart:async';

import 'package:get/get.dart';

import '../app/notify.dart';
import '../app/routes.dart';
import '../app/strings.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';

/// The profile page: who I am, sign out, and delete my account (required in-app by Apple).
class AccountController extends GetxController {
  AccountController(this._users, this._auth);

  final UserRepository _users;
  final AuthService _auth;

  final me = Rxn<Me>();
  final loading = true.obs;
  final deleting = false.obs;
  final error = RxnString();

  @override
  void onInit() {
    super.onInit();
    unawaited(load());
  }

  Future<void> load() async {
    error.value = null;
    try {
      me.value = await _users.me();
    } on ApiException catch (e) {
      error.value = e.message;
    } finally {
      loading.value = false;
    }
  }

  /// Leaves at once: the session is forgotten in memory immediately, and a sign-in waits for the
  /// storage to be cleared, so there's no need to wait for that here.
  Future<void> signOut() async {
    final done = _auth.signOut();
    unawaited(Get.offAllNamed<void>(Routes.signIn));
    await done;
  }

  /// Returns null once the account is gone (signed out, on the sign-in page), or a message to show.
  Future<String?> deleteAccount() async {
    if (deleting.value) return null;
    deleting.value = true;
    try {
      await _users.deleteAccount();
    } on ApiException catch (e) {
      if (e.code == 'BALANCES_NOT_ZERO') {
        final groups = groupNames(e.details);
        return groups.isEmpty ? e.message : S.deleteAccountBlocked(groups);
      }
      return e.message;
    } finally {
      deleting.value = false;
    }
    await _auth.signOut();
    unawaited(Get.offAllNamed<void>(Routes.signIn));
    notify(S.accountDeleted);
    return null;
  }

  /// BALANCES_NOT_ZERO details: `[{groupId, name}]` -> the names.
  static List<String> groupNames(List<Object?> details) => [
    for (final d in details)
      if (d is Map && d['name'] is String) d['name'] as String,
  ];
}
