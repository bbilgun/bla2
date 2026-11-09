// BillDetailController: optimistic ticks, polling against writes, and when polling pauses.
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
      final controller = BillDetailController('b1', bills);
      // The host starts with i1 ticked.
      controller.bill.value = Bill.fromJson(billJson());

      final toggling = controller.toggleMine('i2');

      expect(controller.myItemIds, {'i1', 'i2'});

      bills.releaseNext();
      await toggling;

      expect(controller.myItemIds, {'i1'});
      expect(controller.pendingMine.value, isNull);
      expect(controller.isBusy(Bill.hostGuestId), isFalse);
      expect(shown.single, startsWith(S.somethingWentWrong));
    });
  });

  group('polling and writes', () {
    late PollingBills bills;
    late BillDetailController controller;

    setUp(() {
      bills = PollingBills();
      controller = BillDetailController('b1', bills);
      controller.bill.value = Bill.fromJson(billJson());
      controller.loading.value = false;
    });

    test("a poll that started before a write can't overwrite the write's result", () async {
      // This poll reads the bill as it was before the write below.
      final poll = controller.poll();
      final guest = controller.bill.value!.others.single;

      await controller.setPaid(guest, false);

      expect(controller.bill.value!.others.single.paidCents, 0);

      // The stale answer still has the guest as paid.
      bills.answerGet(Bill.fromJson(billJson(guestPaidCents: 1500000)));
      await poll;

      expect(controller.bill.value!.others.single.paidCents, 0);
    });

    test('a poll answering with an older updatedAt is dropped', () async {
      controller.bill.value = Bill.fromJson(billJson(updatedAt: '2026-11-05T10:05:00.000Z'));

      final poll = controller.poll();
      bills.answerGet(Bill.fromJson(billJson(updatedAt: '2026-11-05T10:00:00.000Z', hostItems: const [])));
      await poll;

      expect(controller.bill.value!.host.itemIds, ['i1']);
    });

    test('a newer poll is applied', () async {
      final poll = controller.poll();
      bills.answerGet(Bill.fromJson(billJson(updatedAt: '2026-11-05T10:09:00.000Z', hostItems: const [])));
      await poll;

      expect(controller.bill.value!.host.itemIds, isEmpty);
    });

    test('skips polling while a write is in flight', () async {
      controller.busy.add('g1');

      await controller.poll();

      expect(bills.getCalls, 0);
    });

    test('marking paid records the total the host sees as the amount paid', () async {
      final guest = Bill.fromJson(billJson(guestPaidCents: 0)).others.single;

      await controller.setPaid(guest, true);
      await controller.setPaid(guest, false);

      expect(bills.paidCalls, [
        (guestId: 'g1', paid: true, paidCents: 1500000),
        (guestId: 'g1', paid: false, paidCents: null),
      ]);
    });

    test('a new link comes back with a new URL', () async {
      await controller.rotateLink();

      expect(controller.bill.value!.url, 'https://api.example/b/tok2');
      expect(shown.single, S.newLinkCreated);
    });

    test('delete reports true once the bill is gone, even if it already was', () async {
      expect(await controller.delete(), isTrue);

      bills.failDelete = apiError('BILL_NOT_FOUND', status: 404);
      expect(await controller.delete(), isTrue);

      bills.failDelete = networkError();
      expect(await controller.delete(), isFalse);
    });
  });

  group('polling pauses', () {
    late BillDetailController controller;

    setUp(() {
      controller = BillDetailController('b1', PollingBills(), pollEvery: const Duration(days: 1));
      controller.onInit();
    });

    tearDown(() => controller.onClose());

    test('while the app is in the background', () {
      expect(controller.isPolling, isTrue);

      controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(controller.isPolling, isTrue);

      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(controller.isPolling, isFalse);

      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(controller.isPolling, isTrue);
    });

    test('until every reason to pause has cleared', () {
      controller.setCovered(true);
      expect(controller.isPolling, isFalse);

      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      controller.setCovered(false);
      expect(controller.isPolling, isFalse);

      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(controller.isPolling, isTrue);
    });
  });
}
