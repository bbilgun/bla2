// The settle up page of a group.
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

/// The suggested payments that bring everyone to zero, recording one of them, and the history of
/// recorded payments. Either side of a payment can delete it if it was recorded by mistake.
class SettleUpController extends GetxController {
  SettleUpController(this.detail, this._settlements, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  /// The group page underneath, which owns the group and its balances.
  final GroupDetailController detail;
  final SettlementsRepository _settlements;
  final Uuid _uuid;

  /// Payments recorded so far, newest first.
  late final history = CursorList<Settlement>((cursor) => _settlements.list(detail.groupId, cursor: cursor));

  /// Payments being recorded, by [_signature].
  final busy = <String>{}.obs;

  /// Ids of recorded payments being deleted.
  final deleting = <String>{}.obs;

  // One Idempotency-Key per distinct payment, kept until the server confirms it.
  final _keys = <String, String>{};

  /// The group's balances, from the group page.
  Balances? get balances => detail.balances.value;

  /// The suggested payments.
  List<Transfer> get transfers => balances?.transfers ?? const [];

  /// The signed-in user's id.
  String get me => detail.myUserId;

  @override
  void onInit() {
    super.onInit();
    unawaited(_loadHistory());
  }

  /// Whether the user is the payer or receiver, and so may record it.
  bool canRecord(Transfer transfer) => transfer.fromUserId == me || transfer.toUserId == me;

  /// Whether the user may delete a recorded payment. Only its payer or receiver may.
  bool canDelete(Settlement settlement) => settlement.involves(me);

  /// "Та" (you) for the signed-in user, otherwise the member's name.
  String nameFor(Group group, String userId) => userId == me ? S.you : group.nameOf(userId);

  /// "Payer → receiver" for a suggested payment.
  String describe(Transfer transfer) {
    final group = detail.group.value!;
    return S.transfer(nameFor(group, transfer.fromUserId), nameFor(group, transfer.toUserId));
  }

  /// Records that [transfer] was paid, possibly only in part. Returns null on success, or a message to show.
  ///
  /// Tapping again after a network failure reuses the same Idempotency-Key, so the payment can't be
  /// recorded twice. A different amount counts as a different payment and gets a new key.
  Future<String?> record(Transfer transfer, int amountCents) async {
    final signature = _signature(transfer, amountCents);
    if (busy.contains(signature)) return null;
    final key = _keys[signature] ??= _uuid.v4();
    busy.add(signature);
    try {
      await _settlements.create(
        detail.groupId,
        fromUserId: transfer.fromUserId,
        toUserId: transfer.toUserId,
        amountCents: amountCents,
        idempotencyKey: key,
      );
      _keys.remove(signature);
      await Future.wait([detail.refreshAfterWrite(), _loadHistory()]);
      final payer = nameFor(detail.group.value!, transfer.fromUserId);
      notify(S.paymentRecorded, S.paymentFrom(payer, formatCents(amountCents, currency: detail.currency)));
      return null;
    } on ApiException catch (e) {
      return e.isNetwork ? S.recordOffline : e.message;
    } finally {
      busy.remove(signature);
    }
  }

  /// Whether any amount for [transfer] is being recorded.
  bool isBusy(Transfer transfer) => busy.any((signature) => signature.startsWith(_pairPrefix(transfer)));

  /// Deletes a recorded payment. Returns null once it's gone, or a message to show.
  Future<String?> deleteSettlement(Settlement settlement) async {
    if (!deleting.add(settlement.id)) return null;
    try {
      await _settlements.delete(detail.groupId, settlement.id);
    } on ApiException catch (e) {
      // Already deleted is what we wanted.
      if (e.code != 'SETTLEMENT_NOT_FOUND') return e.message;
    } finally {
      deleting.remove(settlement.id);
    }
    history.removeWhere((other) => other.id == settlement.id);
    notify(S.paymentDeleted);
    await Future.wait([detail.refreshAfterWrite(), _loadHistory()]);
    return null;
  }

  /// Appends the next page of history.
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
      // History is secondary. The suggested payments above still work.
    }
  }

  static String _pairPrefix(Transfer transfer) => '${transfer.fromUserId}>${transfer.toUserId}:';

  // Identifies one payment the user is recording: who pays whom, and how much.
  static String _signature(Transfer transfer, int amountCents) => '${_pairPrefix(transfer)}$amountCents';
}
