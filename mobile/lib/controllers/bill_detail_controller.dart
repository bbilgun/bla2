import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../app/notify.dart';
import '../app/strings.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';

/// One bill, live: guests tick lines from their browsers, so the host's screen polls while it's open
/// and visible. Polling pauses while the app is in the background or another page covers this one.
class BillDetailController extends GetxController with WidgetsBindingObserver {
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

  /// Counts every write. A poll that started before a write answers with the bill as it was before
  /// it, so its answer is dropped instead of overwriting the write's result.
  int _writes = 0;

  /// Why polling is paused: 'background' (app not visible), 'covered' (another page on top).
  final _pauses = <String>{};
  bool get isPolling => _timer != null;

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
    unawaited(load());
    _startPolling();
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPolling();
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        resumePolling('background');
      case AppLifecycleState.paused || AppLifecycleState.hidden || AppLifecycleState.detached:
        pausePolling('background');
      case AppLifecycleState.inactive:
        break; // brief (control centre, a system dialog): keep going
    }
  }

  /// The page tells us when another page is pushed on top of it, and when it's back.
  void setCovered(bool covered) => covered ? pausePolling('covered') : resumePolling('covered');

  void pausePolling(String reason) {
    _pauses.add(reason);
    _stopPolling();
  }

  /// Picks up at once with a fresh poll, then on the usual schedule.
  void resumePolling(String reason) {
    if (!_pauses.remove(reason) || _pauses.isNotEmpty || isClosed) return;
    unawaited(poll());
    _startPolling();
  }

  void _startPolling() {
    if (_timer != null || _pauses.isNotEmpty) return;
    _timer = Timer.periodic(pollEvery, (_) => unawaited(poll()));
  }

  void _stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> load() async {
    error.value = null;
    final writes = _writes;
    try {
      final fresh = await _bills.get(billId);
      if (writes == _writes) bill.value = fresh;
    } on ApiException catch (e) {
      error.value = e.message;
    } finally {
      loading.value = false;
    }
  }

  /// "Try again": show the skeleton while it loads.
  Future<void> retry() {
    loading.value = true;
    return load();
  }

  @visibleForTesting
  Future<void> poll() async {
    if (busy.isNotEmpty || loading.value) return;
    final writes = _writes;
    try {
      final fresh = await _bills.get(billId);
      if (busy.isEmpty && writes == _writes && !_isOlder(fresh)) bill.value = fresh;
    } on ApiException {
      // Next tick tries again; a failed background refresh shouldn't interrupt the host.
    }
  }

  bool _isOlder(Bill fresh) {
    final shown = bill.value?.updatedAt;
    final got = fresh.updatedAt;
    return shown != null && got != null && got.isBefore(shown);
  }

  /// The host's ticks as shown: changes appear at once, before the server answers.
  final pendingMine = Rxn<Set<String>>();
  Set<String> get myItemIds => pendingMine.value ?? bill.value?.host.itemIds.toSet() ?? const {};
  Set<String>? _queuedMine;
  bool _sendingMine = false;

  /// The host's own lines: ticking them shares those lines with guests who ticked them too.
  /// Optimistic: the tick shows immediately; taps made while a request is in flight are merged into
  /// one follow-up request with the latest full list (lists, not toggles, so nothing flips back).
  /// If the request fails, the ticks go back to what the server last said.
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
        _writes++;
        bill.value = await _bills.updateGuest(billId, Bill.hostGuestId, itemIds: ids.toList());
      }
    } on ApiException catch (e) {
      _queuedMine = null;
      notify(S.somethingWentWrong, e.message);
    } finally {
      pendingMine.value = null;
      _sendingMine = false;
      busy.remove(Bill.hostGuestId);
    }
  }

  /// Marking paid records the total the host sees right now as the amount paid.
  Future<void> setPaid(BillGuest guest, bool paid) => _write(
    guest.id,
    () => _bills.updateGuest(billId, guest.id, paid: paid, paidCents: paid ? guest.totalCents : null),
  );

  Future<void> removeGuest(String guestId) => _write(guestId, () => _bills.removeGuest(billId, guestId));

  Future<void> setOpen(bool open) => _write('status', () => _bills.setOpen(billId, open));

  /// A new link and QR code; the old ones stop working.
  Future<void> rotateLink() async {
    if (await _write('token', () => _bills.rotateToken(billId))) notify(S.newLinkCreated);
  }

  /// Returns true once it's deleted (the page then closes).
  Future<bool> delete() async {
    if (!busy.add('delete')) return false;
    _writes++;
    _stopPolling();
    try {
      await _bills.delete(billId);
      notify(S.billDeleted);
      return true;
    } on ApiException catch (e) {
      if (e.code == 'BILL_NOT_FOUND') return true; // already gone
      notify(S.somethingWentWrong, e.message);
      _startPolling();
      return false;
    } finally {
      busy.remove('delete');
    }
  }

  /// After editing: the editor returns the saved bill.
  void replace(Bill updated) {
    _writes++;
    bill.value = updated;
  }

  Future<void> copyLink() async {
    final url = bill.value?.url;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    notify(S.linkCopied, url);
  }

  bool isBusy(String guestId) => busy.contains(guestId);

  Future<bool> _write(String key, Future<Bill> Function() request) async {
    if (busy.contains(key)) return false;
    busy.add(key);
    _writes++;
    try {
      bill.value = await request();
      return true;
    } on ApiException catch (e) {
      notify(S.somethingWentWrong, e.message);
      return false;
    } finally {
      busy.remove(key);
    }
  }
}
