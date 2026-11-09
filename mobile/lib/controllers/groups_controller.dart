import 'package:get/get.dart';

import '../app/routes.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';

class GroupsController extends GetxController {
  GroupsController(this._groups, this._users, this._auth);

  final GroupsRepository _groups;
  final UserRepository _users;
  final AuthService _auth;

  final groups = <Group>[].obs;
  final loading = true.obs;
  final error = RxnString();
  final me = Rxn<Me>();

  @override
  void onInit() {
    super.onInit();
    load();
    _users.me().then((m) => me.value = m).ignore();
  }

  Future<void> load() async {
    error.value = null;
    try {
      groups.assignAll(await _groups.list());
    } on ApiException catch (e) {
      error.value = e.message;
    } finally {
      loading.value = false;
    }
  }

  /// Returns an error message, or null on success (and opens the new group).
  Future<String?> create(String name, String currency) async {
    try {
      final group = await _groups.create(name: name.trim(), currency: currency);
      groups.insert(0, group);
      Get.toNamed(Routes.groupPath(group.id));
      return null;
    } on ApiException catch (e) {
      return e.fieldErrors['name'] ?? e.message;
    }
  }

  Future<void> signOut() async {
    await _auth.signOut();
    Get.offAllNamed(Routes.signIn);
  }
}
