// QR bills: parsing, the bill editor, and the host's optimistic ticks. Also holds the bill fakes
// that bill_detail_controller_test.dart imports.
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

/// A bill as the server sends it, shaped like backend/src/services/bills.ts. Bat has paid for half
/// of the khuushuur unless told otherwise.
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

/// Records creates and updates. The first [failures] creates fail as if offline.
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

  /// Lets the oldest held call finish.
  void releaseNext() => _gates.removeAt(0).complete();

  /// When set, every updateGuest fails with it once released.
  ApiException? failWith;

  @override
  Future<Bill> updateGuest(String id, String guestId, {List<String>? itemIds, bool? paid, int? paidCents}) async {
    final sortedIds = [...?itemIds]..sort();
    sent.add(sortedIds);
    final gate = Completer<void>();
    _gates.add(gate);
    await gate.future;
    final error = failWith;
    if (error != null) throw error;
    return Bill.fromJson(billJson(hostItems: sortedIds));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// A profile with bank details saved from an earlier bill.
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

/// A bill editor that has run onInit, so it has started loading the profile.
BillEditorController editor(FakeBills bills, {Bill? existing}) {
  final form = BillEditorController(existing: existing, bills: bills, users: FakeUsers());
  form.onInit();
  return form;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Get.testMode = true;
    recordNotifications();
  });

  test('the server says how much a guest still owes after changing their items', () {
    final underpaid = Bill.fromJson(billJson(guestPaidCents: 1000000, guestTotalCents: 1500000)).others.single;
    final overpaid = Bill.fromJson(billJson(guestPaidCents: 2000000)).others.single;

    expect(underpaid.paid, isFalse);
    expect(underpaid.paidCents, 1000000);
    expect(underpaid.dueCents, 500000);
    expect(underpaid.paidDiffers, isTrue);
    expect(overpaid.dueCents, -500000);
    expect(overpaid.paid, isTrue);
  });

  test('a bill parses its amounts, host and guest names', () {
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
      final form = editor(FakeBills());

      await Future<void>.delayed(Duration.zero);

      expect(form.bank.text, 'Голомт банк');
      expect(form.accountNumber.text, '1105000123');
    });

    test('skips blank rows and reports half-filled rows and a missing title', () {
      final form = editor(FakeBills());

      expect(form.buildBody(), isNull);
      expect(form.fieldErrors.keys, containsAll(['title', 'items']));

      form.title.text = 'Оройн хоол';
      form.lines[0].name.text = 'Хуушуур';
      form.lines[0].price.text = '30000';
      // The second row has a name but no price.
      form.lines[1].name.text = 'Кола';

      expect(form.buildBody(), isNull);
      expect(form.fieldErrors['items'], S.itemRowIncomplete(2));

      form.lines[1].price.text = '4500';
      final body = form.buildBody()!;

      expect(body['currency'], 'MNT');
      expect(body['items'], [
        {'name': 'Хуушуур', 'priceCents': 3000000},
        {'name': 'Кола', 'priceCents': 450000},
      ]);
    });

    test('bank details are all or nothing', () async {
      final form = editor(FakeBills());
      await Future<void>.delayed(Duration.zero);
      form.title.text = 'x';
      form.lines[0].name.text = 'a';
      form.lines[0].price.text = '1';

      form.accountName.text = '';

      expect(form.buildBody(), isNull);
      expect(form.fieldErrors['payment'], S.paymentIncomplete);

      form.bank.text = '';
      form.accountNumber.text = '';

      expect(form.buildBody()!['payment'], isNull);
    });

    test('saving again after a network failure reuses the Idempotency-Key', () async {
      final bills = FakeBills(failures: 1);
      final form = editor(bills);
      form.title.text = 'Оройн хоол';
      form.lines[0].name.text = 'Хуушуур';
      form.lines[0].price.text = '30000';

      expect(await form.save(), isNull);
      expect(form.error.value, S.saveOffline);

      expect(await form.save(), isNotNull);
      expect(bills.creates.map((create) => create.key).toSet(), hasLength(1));
      expect(form.pendingIdempotencyKey, isNull);
    });
  });

  test('editing keeps line ids so guests keep their ticks, and sends a PUT', () async {
    final bills = FakeBills();
    final form = editor(bills, existing: Bill.fromJson(billJson()));

    expect(form.title.text, 'Оройн хоол');
    expect(form.lines.map((line) => line.price.text), ['30000.00', '4500.00']);

    form.lines[1].price.text = '5000';

    expect(await form.save(), isNotNull);
    expect(bills.creates, isEmpty);
    expect(bills.updates.single.id, 'b1');
    expect(bills.updates.single.body['items'], [
      {'id': 'i1', 'name': 'Хуушуур', 'priceCents': 3000000},
      {'id': 'i2', 'name': 'Кола', 'priceCents': 500000},
    ]);
  });

  test('host ticks show at once, and taps during a request merge into one follow-up', () async {
    final bills = SlowBills();
    // Without onInit there is no load and no polling timer.
    final controller = BillDetailController('b1', bills);
    // The host starts with i1 ticked.
    controller.bill.value = Bill.fromJson(billJson());

    final toggling = controller.toggleMine('i2');

    // The tick shows before the server answers.
    expect(controller.myItemIds, {'i1', 'i2'});

    unawaited(controller.toggleMine('i1'));
    unawaited(controller.toggleMine('i2'));

    expect(controller.myItemIds, isEmpty);

    bills.releaseNext();
    await pumpEventQueue();
    bills.releaseNext();
    await toggling;

    expect(bills.sent, [
      ['i1', 'i2'],
      <String>[],
    ]);
    expect(controller.pendingMine.value, isNull);
    expect(controller.bill.value!.host.itemIds, isEmpty);
  });
}

/// get() calls wait until the test answers them, while writes answer at once.
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
    final answer = Completer<Bill>();
    _gets.add(answer);
    return answer.future;
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
