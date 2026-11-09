import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:netzero/app/strings.dart';
import 'package:netzero/controllers/bill_detail_controller.dart';
import 'package:netzero/controllers/bill_editor_controller.dart';
import 'package:netzero/models/models.dart';
import 'package:netzero/repositories/repositories.dart';
import 'package:netzero/services/api_client.dart';

/// The bill JSON the server sends (shape from backend/src/services/bills.ts).
Map<String, dynamic> billJson({String status = 'OPEN', List<String> hostItems = const ['i1']}) => {
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
    {'id': 'host', 'name': 'Билгүүн', 'isHost': true, 'paid': false, 'itemIds': hostItems, 'totalCents': 1500000},
    {
      'id': 'g1',
      'name': 'Бат',
      'isHost': false,
      'paid': true,
      'itemIds': ['i1'],
      'totalCents': 1500000,
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
  'updatedAt': '2026-11-05T10:00:00.000Z',
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

  @override
  Future<Bill> updateGuest(String id, String guestId, {List<String>? itemIds, bool? paid}) async {
    final ids = [...?itemIds]..sort();
    sent.add(ids);
    final gate = Completer<void>();
    _gates.add(gate);
    await gate.future;
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
  setUp(() => Get.testMode = true);

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
