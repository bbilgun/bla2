// The account page.
import 'dart:async';

import 'package:get/get.dart';

import '../app/notify.dart';
import '../app/routes.dart';
import '../app/strings.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';

/// The user's profile, signing out, and deleting the account. Apple requires account deletion in the app.
class AccountController extends GetxController {
  AccountController(this._users, this._auth);

  final UserRepository _users;
  final AuthService _auth;

  /// The profile, once loaded.
  final me = Rxn<Me>();

  /// True until the profile has loaded or failed.
  final loading = true.obs;

  /// True while the delete request is running.
  final deleting = false.obs;

  /// Why the profile couldn't load.
  final error = RxnString();

  @override
  void onInit() {
    super.onInit();
    unawaited(load());
  }

  /// Loads the profile.
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

  /// Signs out and goes to the sign-in page straight away. The session is forgotten in memory at once,
  /// and the next sign-in waits for storage to be cleared, so the page doesn't need to wait.
  Future<void> signOut() async {
    final signingOut = _auth.signOut();
    unawaited(Get.offAllNamed<void>(Routes.signIn));
    await signingOut;
  }

  /// Deletes the account, signs out and goes to sign-in. Returns null on success, or a message to
  /// show when the server refuses, such as unsettled balances.
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

  /// The group names from a `BALANCES_NOT_ZERO` error's details, which look like `[{groupId, name}]`.
  static List<String> groupNames(List<Object?> details) => [
    for (final detail in details)
      if (detail is Map && detail['name'] is String) detail['name'] as String,
  ];
}
