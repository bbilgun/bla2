// The bill page: the QR code, guests and their items, kept live by polling.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../app/notify.dart';
import '../app/strings.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../services/api_client.dart';

/// One bill, kept live. Guests claim items from their browsers, so the host's screen polls while
/// it's open. Polling pauses while the app is in the background or another page covers this one.
class BillDetailController extends GetxController with WidgetsBindingObserver {
  /// [pollEvery] lets tests poll faster.
  BillDetailController(this.billId, this._bills, {this.pollEvery = const Duration(seconds: 5)});

  final String billId;
  final BillsRepository _bills;

  /// Time between polls.
  final Duration pollEvery;

  /// The bill as last loaded or saved.
  final bill = Rxn<Bill>();

  /// True until the first load finishes, and again while "try again" reloads.
  final loading = true.obs;

  /// Why the bill couldn't load.
  final error = RxnString();

  /// Writes in flight, keyed by guest id, or by 'status', 'token' or 'delete' for bill-wide actions.
  /// Polling skips its turn while any are running.
  final busy = <String>{}.obs;

  /// The host's own ticks while a change is on its way to the server. Null when nothing is pending.
  final pendingMine = Rxn<Set<String>>();

  Timer? _timer;

  // Counts every write. A poll that started before a write answers with the bill as it was before it,
  // so that answer is dropped instead of overwriting the write's result.
  int _writes = 0;

  // Why polling is paused: 'background' when the app isn't visible, 'covered' when a page is on top.
  final _pauses = <String>{};

  // Ticks waiting to be sent after the request in flight, and whether one is in flight.
  Set<String>? _queuedMine;
  bool _sendingMine = false;

  /// Whether the poll timer is running.
  bool get isPolling => _timer != null;

  /// The items the host has ticked, including changes not yet confirmed by the server.
  Set<String> get myItemIds => pendingMine.value ?? bill.value?.host.itemIds.toSet() ?? const {};

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
        // Brief, as when control centre or a system dialog is showing, so keep going.
        break;
    }
  }

  /// Called by the page when another page is pushed on top of it, and when it's uncovered again.
  void setCovered(bool covered) {
    if (covered) {
      pausePolling('covered');
    } else {
      resumePolling('covered');
    }
  }

  /// Stops polling until [resumePolling] is called with the same [reason].
  void pausePolling(String reason) {
    _pauses.add(reason);
    _stopPolling();
  }

  /// Lifts one pause. Once none are left, polls straight away and then on the usual schedule.
  void resumePolling(String reason) {
    final wasPaused = _pauses.remove(reason);
    if (!wasPaused || _pauses.isNotEmpty || isClosed) return;
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

  /// Loads the bill.
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

  /// "Try again" on the error page. It shows the loading skeleton while it loads.
  Future<void> retry() {
    loading.value = true;
    return load();
  }

  /// Fetches the bill in the background. Skipped while a write is running, and the answer is dropped
  /// if a write started meanwhile or it is older than what's on screen.
  @visibleForTesting
  Future<void> poll() async {
    if (busy.isNotEmpty || loading.value) return;
    final writes = _writes;
    try {
      final fresh = await _bills.get(billId);
      if (busy.isEmpty && writes == _writes && !_isOlder(fresh)) bill.value = fresh;
    } on ApiException {
      // The next tick tries again. A failed background refresh shouldn't interrupt the host.
    }
  }

  bool _isOlder(Bill fresh) {
    final shown = bill.value?.updatedAt;
    final received = fresh.updatedAt;
    return shown != null && received != null && received.isBefore(shown);
  }

  /// Ticks or unticks one of the host's own items, which shares it with any guests who ticked it too.
  ///
  /// The tick shows at once. Taps made while a request is in flight are merged into one follow-up
  /// request carrying the latest full list. If a request fails, the ticks go back to what the server
  /// last said.
  Future<void> toggleMine(String itemId) async {
    if (bill.value == null) return;
    final next = {...myItemIds};
    if (next.contains(itemId)) {
      next.remove(itemId);
    } else {
      next.add(itemId);
    }
    pendingMine.value = next;
    _queuedMine = next;
    if (_sendingMine) return;

    _sendingMine = true;
    busy.add(Bill.hostGuestId);
    try {
      while (_queuedMine != null) {
        final itemIds = _queuedMine!;
        _queuedMine = null;
        _writes++;
        bill.value = await _bills.updateGuest(billId, Bill.hostGuestId, itemIds: itemIds.toList());
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

  /// Marks a guest paid or unpaid. Marking paid records the total the host sees right now as the amount.
  Future<void> setPaid(BillGuest guest, bool paid) {
    final paidCents = paid ? guest.totalCents : null;
    return _write(guest.id, () => _bills.updateGuest(billId, guest.id, paid: paid, paidCents: paidCents));
  }

  /// Removes a guest from the bill.
  Future<void> removeGuest(String guestId) => _write(guestId, () => _bills.removeGuest(billId, guestId));

  /// Opens or closes the bill to changes from guests.
  Future<void> setOpen(bool open) => _write('status', () => _bills.setOpen(billId, open));

  /// Replaces the link and QR code. The old ones stop working.
  Future<void> rotateLink() async {
    final rotated = await _write('token', () => _bills.rotateToken(billId));
    if (rotated) notify(S.newLinkCreated);
  }

  /// Deletes the bill. Returns true once it's gone, and the page then closes.
  Future<bool> delete() async {
    if (!busy.add('delete')) return false;
    _writes++;
    _stopPolling();
    try {
      await _bills.delete(billId);
      notify(S.billDeleted);
      return true;
    } on ApiException catch (e) {
      // Already gone is what we wanted.
      if (e.code == 'BILL_NOT_FOUND') return true;
      notify(S.somethingWentWrong, e.message);
      _startPolling();
      return false;
    } finally {
      busy.remove('delete');
    }
  }

  /// Shows the bill the editor saved.
  void replace(Bill updated) {
    _writes++;
    bill.value = updated;
  }

  /// Copies the guest link to the clipboard.
  Future<void> copyLink() async {
    final url = bill.value?.url;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    notify(S.linkCopied, url);
  }

  /// Whether a write for [guestId] is running.
  bool isBusy(String guestId) => busy.contains(guestId);

  // Runs one write that returns the updated bill. Returns whether it succeeded.
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
