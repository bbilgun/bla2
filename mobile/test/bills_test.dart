import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:netzero/app/strings.dart';
import 'package:netzero/controllers/bill_detail_controller.dart';
import 'package:netzero/controllers/bill_editor_controller.dart';
import 'package:netzero/models/models.dart';
import 'package:netzero/repositories/repositories.dart';
import 'package:netzero/services/api_client.dart';

import 'fakes.dart' show recordNotifications;

/// The bill JSON the server sends (shape from backend/src/services/bills.ts).
Map<String, dynamic> billJson({
  String status = 'OPEN',
  List<String> hostItems = const ['i1'],
  String updatedAt = '2026-11-05T10:00:00.000Z',
  int guestPaidCents = 1500000,
  int guestTotalCents = 1500000,
}) => {
  'id': 'b1',
  'code': '7KQ2HM',
  'title': 'Оройн хоол',
  'currency': 'MNT',
  'status': status,
  'hostName': 'Билгүүн',
  'items': [
    {
      'id': 'i1',
      'name': 'Хуушуур',
      'priceCents': 3000000,
      'claimedBy': ['g1', 'host'],
      'shares': {'g1': 1500000, 'host': 1500000},
    },
    {'id': 'i2', 'name': 'Кола', 'priceCents': 450000, 'claimedBy': <String>[], 'shares': <String, int>{}},
  ],
  'guests': [
    {
      'id': 'host',
      'name': 'Билгүүн',
      'isHost': true,
      'paid': false,
      'itemIds': hostItems,
      'totalCents': 1500000,
      'paidCents': 0,
      'dueCents': 1500000,
    },
    {
      'id': 'g1',
      'name': 'Бат',
      'isHost': false,
      'paid': guestPaidCents > 0 && guestTotalCents - guestPaidCents <= 0,
      'itemIds': ['i1'],
      'totalCents': guestTotalCents,
      'paidCents': guestPaidCents,
      'dueCents': guestTotalCents - guestPaidCents,
    },
  ],
  'totalCents': 3450000,
  'claimedCents': 3000000,
  'unclaimedCents': 450000,
  'owedCents': 1500000,
  'paidCents': 1500000,
  'payment': {'bankName': 'Хаан банк', 'accountNumber': '5000123456', 'accountName': 'Билгүүн'},
  'hasPayQr': false,
  'createdAt': '2026-11-05T10:00:00.000Z',
  'updatedAt': updatedAt,
  'token': 'tok',
  'url': 'https://api.example/b/tok',
};

class FakeBills implements BillsRepository {
  FakeBills({this.failures = 0});

  int failures;
  final creates = <({Map<String, dynamic> body, String key})>[];
  final updates = <({String id, Map<String, dynamic> body})>[];

  @override
  Future<Bill> create(Map<String, dynamic> body, {required String idempotencyKey}) async {
    creates.add((body: body, key: idempotencyKey));
    if (failures > 0) {
      failures--;
      throw ApiException(code: 'NETWORK', message: S.noConnection);
    }
    return Bill.fromJson(billJson());
  }

  @override
  Future<Bill> update(String id, Map<String, dynamic> body) async {
    updates.add((id: id, body: body));
    return Bill.fromJson(billJson());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Holds each updateGuest call until the test releases it, like a slow network.
class SlowBills implements BillsRepository {
  final sent = <List<String>>[];
  final _gates = <Completer<void>>[];

  void releaseNext() => _gates.removeAt(0).complete();

  /// When set, every updateGuest fails with it once released.
  ApiException? failWith;

  @override
  Future<Bill> updateGuest(String id, String guestId, {List<String>? itemIds, bool? paid, int? paidCents}) async {
    final ids = [...?itemIds]..sort();
    sent.add(ids);
    final gate = Completer<void>();
    _gates.add(gate);
    await gate.future;
    final error = failWith;
    if (error != null) throw error;
    return Bill.fromJson(billJson(hostItems: ids));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class FakeUsers implements UserRepository {
  @override
  Future<Me> me() async => const Me(
    userId: 'u1',
    email: 'u@x.com',
    name: 'Билгүүн',
    payment: PaymentInfo(bankName: 'Голомт банк', accountNumber: '1105000123', accountName: 'Билгүүн'),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

BillEditorController editor(FakeBills bills, {Bill? existing}) {
  final c = BillEditorController(existing: existing, bills: bills, users: FakeUsers());
  c.onInit();
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Get.testMode = true;
    recordNotifications();
  });

  test('a guest who paid and then ticked more: the server says how much is still due', () {
    final guest = Bill.fromJson(billJson(guestPaidCents: 1000000, guestTotalCents: 1500000)).others.single;
    expect(guest.paid, isFalse);
    expect(guest.paidCents, 1000000);
    expect(guest.dueCents, 500000);
    expect(guest.paidDiffers, isTrue);
    final overpaid = Bill.fromJson(billJson(guestPaidCents: 2000000)).others.single;
    expect(overpaid.dueCents, -500000);
    expect(overpaid.paid, isTrue);
  });

  test('Bill.fromJson: integer amounts, host, names', () {
    final bill = Bill.fromJson(billJson());
    expect(bill.isOpen, isTrue);
    expect(bill.host.id, 'host');
    expect(bill.others.single.name, 'Бат');
    expect(bill.items.first.shares['g1'], 1500000);
    expect(bill.nameOf('g1'), 'Бат');
    expect(bill.payment!.bankName, 'Хаан банк');
    expect(Bill.fromJson(billJson(status: 'CLOSED')).isOpen, isFalse);
  });

  group('new bill', () {
    test('pre-fills bank details from the last bill', () async {
      final c = editor(FakeBills());
      await Future<void>.delayed(Duration.zero);
      expect(c.bank.text, 'Голомт банк');
      expect(c.accountNumber.text, '1105000123');
    });

    test('blank rows are skipped; half-filled rows and missing title are errors', () {
      final c = editor(FakeBills());
      expect(c.buildBody(), isNull);
      expect(c.fieldErrors.keys, containsAll(['title', 'items']));

      c.title.text = 'Оройн хоол';
      c.lines[0].name.text = 'Хуушуур';
      c.lines[0].price.text = '30000';
      c.lines[1].name.text = 'Кола'; // no price
      expect(c.buildBody(), isNull);
      expect(c.fieldErrors['items'], S.itemRowIncomplete(2));

      c.lines[1].price.text = '4500';
      final body = c.buildBody()!;
      expect(body['currency'], 'MNT');
      expect(body['items'], [
        {'name': 'Хуушуур', 'priceCents': 3000000},
        {'name': 'Кола', 'priceCents': 450000},
      ]);
    });

    test('bank details are all or nothing', () async {
      final c = editor(FakeBills());
      await Future<void>.delayed(Duration.zero);
      c.title.text = 'x';
      c.lines[0].name.text = 'a';
      c.lines[0].price.text = '1';
      c.accountName.text = '';
      expect(c.buildBody(), isNull);
      expect(c.fieldErrors['payment'], S.paymentIncomplete);

      c.bank.text = '';
      c.accountNumber.text = '';
      expect(c.buildBody()!['payment'], isNull);
    });

    test('Save, network drops, Save again: same Idempotency-Key, so one bill', () async {
      final bills = FakeBills(failures: 1);
      final c = editor(bills);
      c.title.text = 'Оройн хоол';
      c.lines[0].name.text = 'Хуушуур';
      c.lines[0].price.text = '30000';

      expect(await c.save(), isNull);
      expect(c.error.value, S.saveOffline);
      expect(await c.save(), isNotNull);
      expect(bills.creates.map((x) => x.key).toSet(), hasLength(1));
      expect(c.pendingIdempotencyKey, isNull);
    });
  });

  test('editing keeps line ids, so guests keep their ticks, and uses PUT', () async {
    final bills = FakeBills();
    final c = editor(bills, existing: Bill.fromJson(billJson()));
    expect(c.title.text, 'Оройн хоол');
    expect(c.lines.map((l) => l.price.text), ['30000.00', '4500.00']);

    c.lines[1].price.text = '5000';
    expect(await c.save(), isNotNull);
    expect(bills.creates, isEmpty);
    expect(bills.updates.single.id, 'b1');
    expect(bills.updates.single.body['items'], [
      {'id': 'i1', 'name': 'Хуушуур', 'priceCents': 3000000},
      {'id': 'i2', 'name': 'Кола', 'priceCents': 500000},
    ]);
  });

  test('host ticks show at once; taps during a request merge into one follow-up with the final list', () async {
    final bills = SlowBills();
    final c = BillDetailController('b1', bills); // onInit not called: no load, no polling timer
    c.bill.value = Bill.fromJson(billJson()); // the host has i1

    final done = c.toggleMine('i2');
    expect(c.myItemIds, {'i1', 'i2'}); // before the server answers
    unawaited(c.toggleMine('i1'));
    unawaited(c.toggleMine('i2'));
    expect(c.myItemIds, isEmpty);

    bills.releaseNext();
    await pumpEventQueue();
    bills.releaseNext();
    await done;

    expect(bills.sent, [
      ['i1', 'i2'],
      <String>[],
    ]);
    expect(c.pendingMine.value, isNull);
    expect(c.bill.value!.host.itemIds, isEmpty);
  });
}

/// get() answers from a queue of held responses; writes answer at once.
class PollingBills implements BillsRepository {
  final _gets = <Completer<Bill>>[];
  int getCalls = 0;
  final paidCalls = <({String guestId, bool? paid, int? paidCents})>[];
  Object? failDelete;
  int deletes = 0;

  /// Answers the oldest get() still waiting.
  void answerGet(Bill bill) => _gets.removeAt(0).complete(bill);

  @override
  Future<Bill> get(String id) {
    getCalls++;
    final c = Completer<Bill>();
    _gets.add(c);
    return c.future;
  }

  @override
  Future<Bill> updateGuest(String id, String guestId, {List<String>? itemIds, bool? paid, int? paidCents}) async {
    paidCalls.add((guestId: guestId, paid: paid, paidCents: paidCents));
    return Bill.fromJson(billJson(updatedAt: '2026-11-05T10:05:00.000Z', guestPaidCents: paidCents ?? 0));
  }

  @override
  Future<Bill> rotateToken(String id) async =>
      Bill.fromJson({...billJson(), 'token': 'tok2', 'url': 'https://api.example/b/tok2'});

  @override
  Future<void> delete(String id) async {
    deletes++;
    final error = failDelete;
    if (error != null) {
      failDelete = null;
      throw error;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
