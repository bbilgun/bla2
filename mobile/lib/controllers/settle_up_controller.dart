import 'dart:async';

import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../app/notify.dart';
import '../app/strings.dart';
import '../domain/money.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';
import 'group_detail_controller.dart';
import 'paging.dart';

/// Suggested payments to get everyone to zero, recording one, and the history of recorded payments
/// (a party to a payment can delete it if it was recorded by mistake).
class SettleUpController extends GetxController {
  SettleUpController(this.detail, this._settlements, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final GroupDetailController detail;
  final SettlementsRepository _settlements;
  final Uuid _uuid;

  late final history = CursorList<Settlement>((cursor) => _settlements.list(detail.groupId, cursor: cursor));
  final busy = <String>{}.obs;

  /// Settlement ids being deleted.
  final deleting = <String>{}.obs;

  /// One Idempotency-Key per distinct payment, kept until the server confirms it.
  final _keys = <String, String>{};

  Balances? get balances => detail.balances.value;
  List<Transfer> get transfers => balances?.transfers ?? const [];
  String get me => detail.myUserId;

  @override
  void onInit() {
    super.onInit();
    unawaited(_loadHistory());
  }

  bool canRecord(Transfer t) => t.fromUserId == me || t.toUserId == me;

  /// Only the payer or the receiver may delete a recorded payment.
  bool canDelete(Settlement s) => s.involves(me);

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
      notify(
        S.paymentRecorded,
        S.paymentFrom(nameFor(detail.group.value!, t.fromUserId), formatCents(amountCents, currency: detail.currency)),
      );
      return null;
    } on ApiException catch (e) {
      return e.isNetwork ? S.recordOffline : e.message;
    } finally {
      busy.remove(signature);
    }
  }

  bool isBusy(Transfer t) => busy.any((s) => s.startsWith('${t.fromUserId}>${t.toUserId}:'));

  /// Returns an error message, or null once it's deleted (deleting twice is fine on the server).
  Future<String?> deleteSettlement(Settlement s) async {
    if (!deleting.add(s.id)) return null;
    try {
      await _settlements.delete(detail.groupId, s.id);
    } on ApiException catch (e) {
      if (e.code != 'SETTLEMENT_NOT_FOUND') return e.message;
    } finally {
      deleting.remove(s.id);
    }
    history.removeWhere((x) => x.id == s.id);
    notify(S.paymentDeleted);
    await Future.wait([detail.refreshAfterWrite(), _loadHistory()]);
    return null;
  }

  Future<void> loadMoreHistory() async {
    try {
      await history.loadMore();
    } on ApiException catch (e) {
      notify(S.couldNotLoadMore, e.message);
    }
  }

  Future<void> _loadHistory() async {
    try {
      await history.reload();
    } on ApiException {
      // History is secondary; the transfers above still work.
    }
  }
}
