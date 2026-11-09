// SettleUpController: recording payments with an Idempotency-Key, and deleting them.
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:netzero/app/strings.dart';
import 'package:netzero/controllers/group_detail_controller.dart';
import 'package:netzero/controllers/settle_up_controller.dart';
import 'package:netzero/models/models.dart';
import 'package:netzero/repositories/repositories.dart';

import 'fakes.dart';

/// Keeps recorded payments in memory. The next [failCreates] creates fail as if offline.
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
    final settlement = Settlement(
      id: 's${creates.length}',
      fromUserId: fromUserId,
      toUserId: toUserId,
      amountCents: amountCents,
      createdAt: DateTime.utc(2026, 11, 9),
    );
    stored = [settlement, ...stored];
    return settlement;
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
    stored = [...stored.where((settlement) => settlement.id != settlementId)];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSettlements settlements;
  late SettleUpController controller;
  const batPaysAnu = Transfer(fromUserId: 'b', toUserId: 'a', amountCents: 3000);

  setUp(() async {
    Get.testMode = true;
    recordNotifications();
    settlements = FakeSettlements();
    final detail = GroupDetailController('g1', FakeGroups(), FakeExpenses([]), myUserId: () => 'a');
    await detail.load();
    controller = SettleUpController(detail, settlements);
  });

  group('Idempotency-Key', () {
    test('a retry after a network error reuses the key until the server confirms', () async {
      settlements.failCreates = 1;

      expect(await controller.record(batPaysAnu, 3000), S.recordOffline);
      expect(await controller.record(batPaysAnu, 3000), isNull);
      expect(settlements.creates.map((create) => create.key).toSet(), hasLength(1));

      // Recording the same payment again after it went through is a new payment with a new key.
      expect(await controller.record(batPaysAnu, 3000), isNull);
      expect(settlements.creates[2].key, isNot(settlements.creates[0].key));
    });

    test('a different amount gets its own key', () async {
      settlements.failCreates = 1;

      await controller.record(batPaysAnu, 3000);
      await controller.record(batPaysAnu, 1000);

      expect(settlements.creates[0].key, isNot(settlements.creates[1].key));
    });

    test('a recorded payment reloads the history and says so', () async {
      await controller.record(batPaysAnu, 3000);

      expect(controller.history.items.single.amountCents, 3000);
      expect(shown.last, startsWith(S.paymentRecorded));
    });
  });

  group('deleting a recorded payment', () {
    test('only the payer or receiver may delete it', () {
      final mine = Settlement(id: 's1', fromUserId: 'b', toUserId: 'a', amountCents: 1, createdAt: DateTime(2026));
      final others = Settlement(id: 's2', fromUserId: 'b', toUserId: 'c', amountCents: 1, createdAt: DateTime(2026));

      expect(controller.canDelete(mine), isTrue);
      expect(controller.canDelete(others), isFalse);
    });

    test('removes it from the history and says so', () async {
      await controller.record(batPaysAnu, 3000);
      final settlement = controller.history.items.single;

      final message = await controller.deleteSettlement(settlement);

      expect(message, isNull);
      expect(settlements.deletes, [settlement.id]);
      expect(controller.history.items, isEmpty);
      expect(shown.last, S.paymentDeleted);
    });

    test('one the other party already deleted counts as done', () async {
      await controller.record(batPaysAnu, 3000);
      settlements.failDelete = apiError('SETTLEMENT_NOT_FOUND', status: 404);

      final message = await controller.deleteSettlement(controller.history.items.single);

      expect(message, isNull);
    });

    test('a refusal from the server is shown and the payment stays', () async {
      await controller.record(batPaysAnu, 3000);
      settlements.failDelete = apiError('NOT_A_PARTY', status: 403);

      final message = await controller.deleteSettlement(controller.history.items.single);

      expect(message, 'NOT_A_PARTY');
      expect(controller.history.items, hasLength(1));
    });
  });
}
