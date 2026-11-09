// InvitesController: accepting and declining invites addressed to the user.
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:netzero/app/strings.dart';
import 'package:netzero/controllers/invites_controller.dart';
import 'package:netzero/models/models.dart';
import 'package:netzero/repositories/repositories.dart';

import 'fakes.dart';

PendingInvite inviteTo(String groupId) => PendingInvite(
  id: 'inv-$groupId',
  groupId: groupId,
  groupName: 'Group $groupId',
  currency: 'MNT',
  memberCount: 3,
  invitedByName: 'Bat',
  createdAt: DateTime.utc(2026, 11, 9),
);

/// Two pending invites. The next accept or decline can be made to fail with [failWith].
class FakeInvites implements InvitesRepository {
  List<PendingInvite> pending = [inviteTo('g1'), inviteTo('g2')];
  final calls = <String>[];
  Object? failWith;

  Future<void> _maybeFail() async {
    final error = failWith;
    if (error != null) {
      failWith = null;
      throw error;
    }
  }

  @override
  Future<List<PendingInvite>> list() async => pending;

  @override
  Future<Group> accept(PendingInvite invite) async {
    calls.add('accept ${invite.id}');
    await _maybeFail();
    pending = [...pending.where((other) => other.id != invite.id)];
    return groupOf(id: invite.groupId, name: invite.groupName);
  }

  @override
  Future<void> decline(PendingInvite invite) async {
    calls.add('decline ${invite.id}');
    await _maybeFail();
    pending = [...pending.where((other) => other.id != invite.id)];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeInvites repo;
  late InvitesController controller;

  List<String> groupIds() => controller.invites.map((invite) => invite.groupId).toList();

  setUp(() async {
    Get.testMode = true;
    recordNotifications();
    repo = FakeInvites();
    controller = InvitesController(repo);
    await controller.load();
  });

  test('loads the pending invites', () {
    expect(groupIds(), ['g1', 'g2']);
  });

  test('accepting returns the group and removes the invite', () async {
    final group = await controller.accept(controller.invites.first);

    expect(group?.id, 'g1');
    expect(groupIds(), ['g2']);
    expect(shown.single, '${S.joinedGroup}: Group g1');
  });

  test('an accept that fails offline keeps the invite', () async {
    repo.failWith = networkError();

    final group = await controller.accept(controller.invites.first);

    expect(group, isNull);
    expect(controller.invites, hasLength(2));
    expect(controller.isBusy(controller.invites.first), isFalse);
  });

  test('an invite that is gone on the server is dropped', () async {
    repo.failWith = apiError('INVITE_NOT_FOUND', status: 404);

    final group = await controller.accept(controller.invites.first);

    expect(group, isNull);
    expect(groupIds(), ['g2']);
  });

  test('a double tap sends one request', () async {
    final invite = controller.invites.first;

    await Future.wait([controller.accept(invite), controller.accept(invite)]);

    expect(repo.calls, ['accept inv-g1']);
  });

  test('declining removes the invite, and a full group is explained', () async {
    expect(await controller.decline(controller.invites.last), isTrue);
    expect(groupIds(), ['g1']);

    repo.failWith = apiError('GROUP_FULL');

    expect(await controller.accept(controller.invites.first), isNull);
    expect(shown.last, contains('GROUP_FULL'));
  });
}
