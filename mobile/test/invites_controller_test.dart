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
    pending = [...pending.where((i) => i.id != invite.id)];
    return groupOf(id: invite.groupId, name: invite.groupName);
  }

  @override
  Future<void> decline(PendingInvite invite) async {
    calls.add('decline ${invite.id}');
    await _maybeFail();
    pending = [...pending.where((i) => i.id != invite.id)];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeInvites repo;
  late InvitesController c;

  setUp(() async {
    Get.testMode = true;
    recordNotifications();
    repo = FakeInvites();
    c = InvitesController(repo);
    await c.load();
  });

  test('loads my invites', () {
    expect(c.invites.map((i) => i.groupId), ['g1', 'g2']);
  });

  test('accept: returns the group I joined and removes the invite', () async {
    final group = await c.accept(c.invites.first);
    expect(group?.id, 'g1');
    expect(c.invites.map((i) => i.groupId), ['g2']);
    expect(shown.single, '${S.joinedGroup}: Group g1');
  });

  test('accept that fails offline keeps the invite to try again', () async {
    repo.failWith = networkError();
    expect(await c.accept(c.invites.first), isNull);
    expect(c.invites, hasLength(2));
    expect(c.isBusy(c.invites.first), isFalse);
  });

  test('INVITE_NOT_FOUND (cancelled, or our earlier accept went through) drops it', () async {
    repo.failWith = apiError('INVITE_NOT_FOUND', status: 404);
    expect(await c.accept(c.invites.first), isNull);
    expect(c.invites.map((i) => i.groupId), ['g2']);
  });

  test('a double tap sends one request', () async {
    final invite = c.invites.first;
    await Future.wait([c.accept(invite), c.accept(invite)]);
    expect(repo.calls, ['accept inv-g1']);
  });

  test('decline removes it; GROUP_FULL on accept is explained', () async {
    expect(await c.decline(c.invites.last), isTrue);
    expect(c.invites.map((i) => i.groupId), ['g1']);

    repo.failWith = apiError('GROUP_FULL');
    expect(await c.accept(c.invites.first), isNull);
    expect(shown.last, contains('GROUP_FULL'));
  });
}
