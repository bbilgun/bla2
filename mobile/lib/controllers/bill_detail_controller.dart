import 'dart:async';

import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../app/strings.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';

/// One bill, live: guests tick lines from their browsers, so the host's screen polls while it's open.
class BillDetailController extends GetxController {
  BillDetailController(this.billId, this._bills, {this.pollEvery = const Duration(seconds: 5)});

  final String billId;
  final BillsRepository _bills;
  final Duration pollEvery;

  final bill = Rxn<Bill>();
  final loading = true.obs;
  final error = RxnString();

  /// Writes in flight, by guest id ("host" for the host's own ticks). Polling pauses while any run.
  final busy = <String>{}.obs;
  Timer? _timer;

  @override
  void onInit() {
    super.onInit();
    load();
    _timer = Timer.periodic(pollEvery, (_) => _poll());
  }

  Future<void> load() async {
    error.value = null;
    try {
      bill.value = await _bills.get(billId);
    } on ApiException catch (e) {
      error.value = e.message;
    } finally {
      loading.value = false;
    }
  }

  Future<void> _poll() async {
    if (busy.isNotEmpty || loading.value) return;
    try {
      final fresh = await _bills.get(billId);
      if (busy.isEmpty) bill.value = fresh;
    } on ApiException {
      // Next tick tries again; a failed background refresh shouldn't interrupt the host.
    }
  }

  /// The host's ticks as shown: changes appear at once, before the server answers.
  final pendingMine = Rxn<Set<String>>();
  Set<String> get myItemIds => pendingMine.value ?? bill.value?.host.itemIds.toSet() ?? const {};
  Set<String>? _queuedMine;
  bool _sendingMine = false;

  /// The host's own lines: ticking them shares those lines with guests who ticked them too.
  /// Optimistic: the tick shows immediately; taps made while a request is in flight are merged into
  /// one follow-up request with the latest full list (lists, not toggles, so nothing flips back).
  Future<void> toggleMine(String itemId) async {
    if (bill.value == null) return;
    final next = {...myItemIds};
    next.contains(itemId) ? next.remove(itemId) : next.add(itemId);
    pendingMine.value = next;
    _queuedMine = next;
    if (_sendingMine) return;

    _sendingMine = true;
    busy.add(Bill.hostGuestId);
    try {
      while (_queuedMine != null) {
        final ids = _queuedMine!;
        _queuedMine = null;
        bill.value = await _bills.updateGuest(billId, Bill.hostGuestId, itemIds: ids.toList());
      }
    } on ApiException catch (e) {
      _queuedMine = null;
      Get.snackbar(S.somethingWentWrong, e.message, snackPosition: SnackPosition.BOTTOM);
    } finally {
      pendingMine.value = null;
      _sendingMine = false;
      busy.remove(Bill.hostGuestId);
    }
  }

  Future<void> setPaid(String guestId, bool paid) =>
      _write(guestId, () => _bills.updateGuest(billId, guestId, paid: paid));

  Future<void> removeGuest(String guestId) => _write(guestId, () => _bills.removeGuest(billId, guestId));

  Future<void> setOpen(bool open) => _write('status', () => _bills.setOpen(billId, open));

  /// After editing: the editor returns the saved bill.
  void replace(Bill updated) => bill.value = updated;

  Future<void> copyLink() async {
    final url = bill.value?.url;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    Get.snackbar(S.linkCopied, url, snackPosition: SnackPosition.BOTTOM);
  }

  bool isBusy(String guestId) => busy.contains(guestId);

  Future<void> _write(String key, Future<Bill> Function() request) async {
    if (busy.contains(key)) return;
    busy.add(key);
    try {
      bill.value = await request();
    } on ApiException catch (e) {
      Get.snackbar(S.somethingWentWrong, e.message, snackPosition: SnackPosition.BOTTOM);
    } finally {
      busy.remove(key);
    }
  }

  @override
  void onClose() {
    _timer?.cancel();
    super.onClose();
  }
}
