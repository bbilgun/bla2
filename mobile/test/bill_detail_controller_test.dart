import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:netzero/app/strings.dart';
import 'package:netzero/controllers/bill_detail_controller.dart';
import 'package:netzero/models/models.dart';

import 'bills_test.dart' show PollingBills, SlowBills, billJson;
import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Get.testMode = true;
    recordNotifications();
  });

  group('host ticks', () {
    test('a failed request rolls the ticks back to what the server last said', () async {
      final bills = SlowBills()..failWith = networkError();
      final c = BillDetailController('b1', bills);
      c.bill.value = Bill.fromJson(billJson()); // the host has i1

      final done = c.toggleMine('i2');
      expect(c.myItemIds, {'i1', 'i2'}); // optimistic
      bills.releaseNext();
      await done;

      expect(c.myItemIds, {'i1'}); // rolled back
      expect(c.pendingMine.value, isNull);
      expect(c.isBusy(Bill.hostGuestId), isFalse);
      expect(shown.single, startsWith(S.somethingWentWrong));
    });
  });

  group('polling vs writes', () {
    late PollingBills bills;
    late BillDetailController c;

    setUp(() {
      bills = PollingBills();
      c = BillDetailController('b1', bills);
      c.bill.value = Bill.fromJson(billJson());
      c.loading.value = false;
    });

    test("a poll that started before a write can't overwrite the write's result", () async {
      final poll = c.poll(); // reads the bill as it was before the write
      final guest = c.bill.value!.others.single;
      await c.setPaid(guest, false);
      expect(c.bill.value!.others.single.paidCents, 0);

      bills.answerGet(Bill.fromJson(billJson(guestPaidCents: 1500000))); // stale: still paid
      await poll;
      expect(c.bill.value!.others.single.paidCents, 0);
    });

    test('a poll answering with an older updatedAt is dropped', () async {
      c.bill.value = Bill.fromJson(billJson(updatedAt: '2026-11-05T10:05:00.000Z'));
      final poll = c.poll();
      bills.answerGet(Bill.fromJson(billJson(updatedAt: '2026-11-05T10:00:00.000Z', hostItems: const [])));
      await poll;
      expect(c.bill.value!.host.itemIds, ['i1']);
    });

    test('a newer poll is applied (guests ticking from their phones)', () async {
      final poll = c.poll();
      bills.answerGet(Bill.fromJson(billJson(updatedAt: '2026-11-05T10:09:00.000Z', hostItems: const [])));
      await poll;
      expect(c.bill.value!.host.itemIds, isEmpty);
    });

    test('no poll while a write is in flight', () async {
      c.busy.add('g1');
      await c.poll();
      expect(bills.getCalls, 0);
    });

    test('marking paid records the total the host sees as the amount paid', () async {
      final guest = Bill.fromJson(billJson(guestPaidCents: 0)).others.single;
      await c.setPaid(guest, true);
      await c.setPaid(guest, false);
      expect(bills.paidCalls, [
        (guestId: 'g1', paid: true, paidCents: 1500000),
        (guestId: 'g1', paid: false, paidCents: null),
      ]);
    });

    test('new link: the bill comes back with a new URL', () async {
      await c.rotateLink();
      expect(c.bill.value!.url, 'https://api.example/b/tok2');
      expect(shown.single, S.newLinkCreated);
    });

    test('delete: true when gone (also when it was already gone)', () async {
      expect(await c.delete(), isTrue);
      bills.failDelete = apiError('BILL_NOT_FOUND', status: 404);
      expect(await c.delete(), isTrue);
      bills.failDelete = networkError();
      expect(await c.delete(), isFalse);
    });
  });

  group('polling pauses', () {
    late BillDetailController c;

    setUp(() {
      c = BillDetailController('b1', PollingBills(), pollEvery: const Duration(days: 1));
      c.onInit();
    });

    tearDown(() => c.onClose());

    test('while the app is in the background', () {
      expect(c.isPolling, isTrue);
      c.didChangeAppLifecycleState(AppLifecycleState.inactive); // brief: keeps going
      expect(c.isPolling, isTrue);
      c.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(c.isPolling, isFalse);
      c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(c.isPolling, isTrue);
    });

    test('while another page covers this one, and both reasons must clear', () {
      c.setCovered(true);
      expect(c.isPolling, isFalse);
      c.didChangeAppLifecycleState(AppLifecycleState.paused);
      c.setCovered(false);
      expect(c.isPolling, isFalse); // still in the background
      c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(c.isPolling, isTrue);
    });
  });
}
