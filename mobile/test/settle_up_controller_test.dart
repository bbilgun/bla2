import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:netzero/app/strings.dart';
import 'package:netzero/controllers/group_detail_controller.dart';
import 'package:netzero/controllers/settle_up_controller.dart';
import 'package:netzero/models/models.dart';
import 'package:netzero/repositories/repositories.dart';

import 'fakes.dart';

class FakeSettlements implements SettlementsRepository {
  final creates = <({int amountCents, String key})>[];
  final deletes = <String>[];
  int failCreates = 0;
  Object? failDelete;
  List<Settlement> stored = [];

  @override
  Future<Settlement> create(
    String groupId, {
    required String fromUserId,
    required String toUserId,
    required int amountCents,
    required String idempotencyKey,
  }) async {
    creates.add((amountCents: amountCents, key: idempotencyKey));
    if (failCreates > 0) {
      failCreates--;
      throw networkError();
    }
    final s = Settlement(
      id: 's${creates.length}',
      fromUserId: fromUserId,
      toUserId: toUserId,
      amountCents: amountCents,
      createdAt: DateTime.utc(2026, 11, 9),
    );
    stored = [s, ...stored];
    return s;
  }

  @override
  Future<CursorPage<Settlement>> list(String groupId, {String? cursor, int limit = 20}) async =>
      CursorPage(items: stored, nextCursor: null);

  @override
  Future<void> delete(String groupId, String settlementId) async {
    deletes.add(settlementId);
    final error = failDelete;
    if (error != null) {
      failDelete = null;
      throw error;
    }
    stored = [...stored.where((s) => s.id != settlementId)];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSettlements settlements;
  late SettleUpController c;
  const batPaysAnu = Transfer(fromUserId: 'b', toUserId: 'a', amountCents: 3000);

  setUp(() async {
    Get.testMode = true;
    recordNotifications();
    settlements = FakeSettlements();
    final detail = GroupDetailController('g1', FakeGroups(), FakeExpenses([]), myUserId: () => 'a');
    await detail.load();
    c = SettleUpController(detail, settlements);
  });

  group('Idempotency-Key lifecycle', () {
    test('a retry after a network error reuses the key; it is dropped once the server confirms', () async {
      settlements.failCreates = 1;
      expect(await c.record(batPaysAnu, 3000), S.recordOffline);
      expect(await c.record(batPaysAnu, 3000), isNull);
      expect(settlements.creates.map((x) => x.key).toSet(), hasLength(1));

      // The same payment again is a new payment: new key.
      expect(await c.record(batPaysAnu, 3000), isNull);
      expect(settlements.creates[2].key, isNot(settlements.creates[0].key));
    });

    test('a different amount (a partial payment) is a different request with its own key', () async {
      settlements.failCreates = 1;
      await c.record(batPaysAnu, 3000);
      await c.record(batPaysAnu, 1000);
      expect(settlements.creates[0].key, isNot(settlements.creates[1].key));
    });

    test('success reloads the history and says so', () async {
      await c.record(batPaysAnu, 3000);
      expect(c.history.items.single.amountCents, 3000);
      expect(shown.last, startsWith(S.paymentRecorded));
    });
  });

  group('deleting a recorded payment', () {
    test('only a party may delete it', () {
      final mine = Settlement(id: 's1', fromUserId: 'b', toUserId: 'a', amountCents: 1, createdAt: DateTime(2026));
      final others = Settlement(id: 's2', fromUserId: 'b', toUserId: 'c', amountCents: 1, createdAt: DateTime(2026));
      expect(c.canDelete(mine), isTrue);
      expect(c.canDelete(others), isFalse);
    });

    test('deletes, removes it from the history and refreshes balances', () async {
      await c.record(batPaysAnu, 3000);
      final s = c.history.items.single;
      expect(await c.deleteSettlement(s), isNull);
      expect(settlements.deletes, [s.id]);
      expect(c.history.items, isEmpty);
      expect(shown.last, S.paymentDeleted);
    });

    test('already deleted by the other party: treated as done', () async {
      await c.record(batPaysAnu, 3000);
      settlements.failDelete = apiError('SETTLEMENT_NOT_FOUND', status: 404);
      expect(await c.deleteSettlement(c.history.items.single), isNull);
    });

    test('NOT_A_PARTY is shown', () async {
      await c.record(batPaysAnu, 3000);
      settlements.failDelete = apiError('NOT_A_PARTY', status: 403);
      expect(await c.deleteSettlement(c.history.items.single), 'NOT_A_PARTY');
      expect(c.history.items, hasLength(1));
    });
  });
}
