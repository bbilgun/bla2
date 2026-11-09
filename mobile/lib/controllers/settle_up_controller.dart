import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../app/strings.dart';
import '../domain/money.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';
import 'group_detail_controller.dart';

class SettleUpController extends GetxController {
  SettleUpController(this.detail, this._settlements, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final GroupDetailController detail;
  final SettlementsRepository _settlements;
  final Uuid _uuid;

  final history = <Settlement>[].obs;
  final busy = <String>{}.obs;

  /// One Idempotency-Key per distinct payment, kept until the server confirms it.
  final _keys = <String, String>{};

  Balances? get balances => detail.balances.value;
  List<Transfer> get transfers => balances?.transfers ?? const [];
  String get me => detail.myUserId;

  @override
  void onInit() {
    super.onInit();
    _loadHistory();
  }

  bool canRecord(Transfer t) => t.fromUserId == me || t.toUserId == me;

  /// "Та" for the signed-in person, otherwise their name.
  String nameFor(Group g, String userId) => userId == me ? S.you : g.nameOf(userId);

  String describe(Transfer t) {
    final g = detail.group.value!;
    return S.transfer(nameFor(g, t.fromUserId), nameFor(g, t.toUserId));
  }

  /// Returns an error message, or null on success.
  Future<String?> record(Transfer t, int amountCents) async {
    final signature = '${t.fromUserId}>${t.toUserId}:$amountCents';
    if (busy.contains(signature)) return null;
    final key = _keys[signature] ??= _uuid.v4();
    busy.add(signature);
    try {
      await _settlements.create(
        detail.groupId,
        fromUserId: t.fromUserId,
        toUserId: t.toUserId,
        amountCents: amountCents,
        idempotencyKey: key,
      );
      _keys.remove(signature);
      await Future.wait([detail.refreshAfterWrite(), _loadHistory()]);
      Get.snackbar(
        S.paymentRecorded,
        S.paymentFrom(nameFor(detail.group.value!, t.fromUserId), formatCents(amountCents, currency: detail.currency)),
        snackPosition: SnackPosition.BOTTOM,
      );
      return null;
    } on ApiException catch (e) {
      return e.isNetwork ? S.recordOffline : e.message;
    } finally {
      busy.remove(signature);
    }
  }

  bool isBusy(Transfer t) => busy.any((s) => s.startsWith('${t.fromUserId}>${t.toUserId}:'));

  Future<void> _loadHistory() async {
    try {
      history.assignAll(await _settlements.list(detail.groupId));
    } on ApiException {
      // History is secondary; the transfers above still work.
    }
  }
}
