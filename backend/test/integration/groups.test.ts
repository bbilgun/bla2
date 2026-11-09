// Caller identity, groups, invites, leaving, and the 404 every outsider gets.
import { randomUUID } from 'node:crypto';
import { ObjectId } from 'mongodb';
import { describe, expect, it } from 'vitest';
import * as balances from '../../src/handlers/balances';
import * as expenses from '../../src/handlers/expenses';
import * as groups from '../../src/handlers/groups';
import * as me from '../../src/handlers/me';
import * as receipts from '../../src/handlers/receipts';
import * as settlements from '../../src/handlers/settlements';
import { getDb } from '../../src/repositories/db';
import { addToGroup, alice, bob, call, carol, mallory, useTestDb, type TestUser } from './helpers';

useTestDb();

async function createGroup(name = 'Trip', as: TestUser = alice) {
  const res = await call(groups.create, { as, method: 'POST', path: '/groups', body: { name } });
  expect(res.status).toBe(201);
  return res.body as { id: string; members: { userId: string }[]; invites: unknown[] };
}

const invite = (groupId: string, email: string, as: TestUser = alice) =>
  call(groups.invite, { as, method: 'POST', params: { groupId }, body: { email } });

const inviteIdFor = (group: { invites: { id: string; email: string }[] }, email: string) =>
  group.invites.find((i) => i.email === email)!.id;

function addExpense(groupId: string, body: unknown, as: TestUser = alice) {
  return call(expenses.create, {
    as,
    method: 'POST',
    path: `/groups/${groupId}/expenses`,
    params: { groupId },
    body,
    headers: { 'Idempotency-Key': randomUUID() },
  });
}

function settle(groupId: string, body: unknown, as: TestUser) {
  return call(settlements.create, {
    as,
    method: 'POST',
    path: `/groups/${groupId}/settlements`,
    params: { groupId },
    body,
    headers: { 'Idempotency-Key': randomUUID() },
  });
}

const groupDoc = async (groupId: string) => (await getDb()).collection('groups').findOne({ _id: new ObjectId(groupId) });

describe('caller identity', () => {
  it('returns the caller from the token claims', async () => {
    const res = await call(me.handler, { as: bob });

    expect(res.status).toBe(200);
    expect(res.body).toEqual({
      userId: bob.sub,
      email: bob.email,
      name: bob.name,
      emailVerified: true,
      payment: null,
      payQrUrl: null,
    });
  });

  it('returns 401 without claims', async () => {
    const res = await call(me.handler, { as: null });

    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('UNAUTHORIZED');
  });

  it('returns 401 for an access token or a token without token_use', async () => {
    // Access tokens pass the API Gateway authorizer but carry no email or name.
    const access = await call(me.handler, { claims: { token_use: 'access' } });
    expect(access.status).toBe(401);
    expect(access.body.error.code).toBe('UNAUTHORIZED');

    const none = await call(me.handler, { claims: { token_use: undefined } });
    expect(none.status).toBe(401);
  });

  it('reads email_verified as a string or a boolean', async () => {
    expect((await call(me.handler, { claims: { email_verified: true } })).body.emailVerified).toBe(true);
    expect((await call(me.handler, { claims: { email_verified: 'false' } })).body.emailVerified).toBe(false);
    expect((await call(me.handler, { claims: { email_verified: undefined } })).body.emailVerified).toBe(false);
  });

  it('treats a token without an email as unverified, with no invites', async () => {
    const group = await createGroup();
    await invite(group.id, bob.email);

    const res = await call(me.handler, { as: bob, claims: { email: undefined } });
    const invites = await call(groups.listInvites, { as: bob, claims: { email: undefined } });

    expect(res.status).toBe(200);
    expect(res.body.email).toBe('');
    expect(res.body.emailVerified).toBe(false);
    expect(res.body.name).toBe('Bob');
    expect(invites.body.items).toEqual([]);
  });

  it('reads a base64-encoded body', async () => {
    const res = await call(groups.create, { method: 'POST', body: { name: 'Encoded ✓' }, base64: true });

    expect(res.status).toBe(201);
    expect(res.body.name).toBe('Encoded ✓');
  });

  it('refreshes the member copy in every group when the name or email changes', async () => {
    const group = await createGroup();
    await addToGroup(group.id, bob);
    const renamed = { ...bob, name: 'Bob Bat', email: 'bob.bat@example.com' };

    await call(me.handler, { as: renamed });

    const got = await call(groups.get, { params: { groupId: group.id } });
    expect(got.body.members.find((m: { userId: string }) => m.userId === bob.sub)).toEqual({
      userId: bob.sub,
      name: 'Bob Bat',
      email: 'bob.bat@example.com',
    });
  });

  it('leaves groups untouched when the name and email are unchanged', async () => {
    const group = await createGroup();
    await addToGroup(group.id, bob);
    const renamed = { ...bob, name: 'Bob Bat', email: 'bob.bat@example.com' };
    await call(me.handler, { as: renamed });
    await (await getDb()).collection('groups').updateOne({ _id: new ObjectId(group.id) }, { $set: { marker: 1 } });
    const before = await groupDoc(group.id);

    await call(me.handler, { as: renamed });

    expect(await groupDoc(group.id)).toEqual(before);
  });
});

describe('groups', () => {
  it('creates, lists and gets a group', async () => {
    const group = await createGroup('Tokyo trip');
    expect(group.members.map((m) => m.userId)).toEqual([alice.sub]);
    expect(group.invites).toEqual([]);

    const list = await call(groups.list);
    expect(list.body.items.map((g: { id: string }) => g.id)).toEqual([group.id]);
    expect(list.body.nextCursor).toBeNull();

    const got = await call(groups.get, { params: { groupId: group.id } });
    expect(got.status).toBe(200);
    expect(got.body.name).toBe('Tokyo trip');
    expect(got.body.currency).toBe('USD');
  });

  it('validates the body', async () => {
    const res = await call(groups.create, { method: 'POST', body: { name: '   ' } });

    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
    expect(res.body.error.details[0].path).toBe('name');
  });

  it('rejects invalid JSON', async () => {
    const event = {
      body: '{nope',
      headers: {},
      requestContext: { authorizer: { jwt: { claims: { sub: 'x', token_use: 'id' } } }, http: { method: 'POST' } },
    };

    const res = await groups.create(event as never, {} as never);

    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body!).error.code).toBe('INVALID_JSON');
  });

  it('pages newest first and rejects a bad cursor or limit', async () => {
    const ids: string[] = [];
    for (let i = 0; i < 5; i++) ids.push((await createGroup(`G${i}`)).id);

    const first = await call(groups.list, { query: { limit: '2' } });
    expect(first.body.items.map((g: { id: string }) => g.id)).toEqual([ids[4], ids[3]]);
    const second = await call(groups.list, { query: { limit: '2', cursor: first.body.nextCursor } });
    expect(second.body.items.map((g: { id: string }) => g.id)).toEqual([ids[2], ids[1]]);
    const third = await call(groups.list, { query: { limit: '2', cursor: second.body.nextCursor } });
    expect(third.body.items.map((g: { id: string }) => g.id)).toEqual([ids[0]]);
    expect(third.body.nextCursor).toBeNull();

    const bad = await call(groups.list, { query: { cursor: 'not-an-id' } });
    expect(bad.status).toBe(400);
    expect(bad.body.error.code).toBe('VALIDATION_ERROR');
    expect((await call(groups.list, { query: { limit: '101' } })).status).toBe(400);
  });

  it('lets any member rename the group, trimming the name', async () => {
    const group = await createGroup();
    await addToGroup(group.id, bob);

    const res = await call(groups.rename, { as: bob, method: 'PATCH', params: { groupId: group.id }, body: { name: '  Ski  ' } });
    const empty = await call(groups.rename, { method: 'PATCH', params: { groupId: group.id }, body: { name: ' ' } });

    expect(res.status).toBe(200);
    expect(res.body.name).toBe('Ski');
    expect(empty.body.error.code).toBe('VALIDATION_ERROR');
  });
});

describe('invites', () => {
  it('lets the invitee see and accept an invite', async () => {
    const group = await createGroup('Flat');
    const invited = await invite(group.id, '  BOB@Example.com ');
    expect(invited.status).toBe(200);
    expect(invited.body.invites).toEqual([
      { id: expect.stringMatching(/^[A-Za-z0-9_-]{16}$/), email: bob.email, invitedBy: alice.sub, createdAt: expect.any(String) },
    ]);
    const inviteId = invited.body.invites[0].id;

    // Bob hasn't signed in yet. The invite waits for his verified email.
    const listed = await call(groups.listInvites, { as: bob });
    expect(listed.body.items).toEqual([
      {
        id: inviteId,
        groupId: group.id,
        groupName: 'Flat',
        currency: 'USD',
        memberCount: 1,
        invitedByName: 'Alice',
        createdAt: invited.body.invites[0].createdAt,
      },
    ]);

    const accepted = await call(groups.acceptInvite, { as: bob, method: 'POST', params: { groupId: group.id, inviteId } });
    expect(accepted.status).toBe(200);
    expect(accepted.body.members.map((m: { userId: string }) => m.userId)).toEqual([alice.sub, bob.sub]);
    expect(accepted.body.members[1]).toEqual({ userId: bob.sub, email: bob.email, name: 'Bob' });
    expect(accepted.body.invites).toEqual([]);
    expect((await call(groups.listInvites, { as: bob })).body.items).toEqual([]);
    expect((await call(groups.list, { as: bob })).body.items).toHaveLength(1);
  });

  it('adds the member once however many times they accept', async () => {
    const group = await createGroup();
    const inviteId = inviteIdFor((await invite(group.id, bob.email)).body, bob.email);
    const accept = () => call(groups.acceptInvite, { as: bob, method: 'POST', params: { groupId: group.id, inviteId } });

    const results = await Promise.all([accept(), accept(), accept()]);
    const again = await accept();

    expect(results.map((r) => r.status)).toEqual([200, 200, 200]);
    expect(again.status).toBe(200);
    expect(again.body.members.filter((m: { userId: string }) => m.userId === bob.sub)).toHaveLength(1);
  });

  it('returns 404 to anyone but the verified invitee', async () => {
    const group = await createGroup();
    const inviteId = inviteIdFor((await invite(group.id, bob.email)).body, bob.email);

    const wrong = await call(groups.acceptInvite, { as: carol, method: 'POST', params: { groupId: group.id, inviteId } });
    expect(wrong.status).toBe(404);
    expect(wrong.body.error.code).toBe('INVITE_NOT_FOUND');

    const unverified = { ...bob, emailVerified: false };
    const notYet = await call(groups.acceptInvite, { as: unverified, method: 'POST', params: { groupId: group.id, inviteId } });
    expect(notYet.status).toBe(404);
    expect(notYet.body.error.code).toBe('INVITE_NOT_FOUND');
    expect((await call(groups.listInvites, { as: unverified })).body.items).toEqual([]);

    for (const params of [
      { groupId: group.id, inviteId: 'nope' },
      { groupId: 'not-an-id', inviteId },
      { groupId: new ObjectId().toHexString(), inviteId },
    ]) {
      const res = await call(groups.acceptInvite, { as: bob, method: 'POST', params });
      expect(res.body.error.code).toBe('INVITE_NOT_FOUND');
    }

    // Declining someone else's invite is a 404 too, and leaves it in place.
    const decline = await call(groups.declineInvite, { as: carol, method: 'POST', params: { groupId: group.id, inviteId } });
    expect(decline.body.error.code).toBe('INVITE_NOT_FOUND');
    expect((await call(groups.listInvites, { as: bob })).body.items).toHaveLength(1);
  });

  it('removes a declined invite and returns 404 on a second decline', async () => {
    const group = await createGroup();
    const inviteId = inviteIdFor((await invite(group.id, bob.email)).body, bob.email);
    const decline = () => call(groups.declineInvite, { as: bob, method: 'POST', params: { groupId: group.id, inviteId } });

    const res = await decline();
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ declined: true });
    expect((await call(groups.get, { params: { groupId: group.id } })).body.invites).toEqual([]);

    const again = await decline();
    expect(again.status).toBe(404);
    expect(again.body.error.code).toBe('INVITE_NOT_FOUND');
  });

  it('ignores a repeated invite', async () => {
    const group = await createGroup();
    await invite(group.id, bob.email);

    const twice = await invite(group.id, bob.email);

    expect(twice.status).toBe(200);
    expect(twice.body.invites).toHaveLength(1);
  });

  it('refuses to invite someone already in the group', async () => {
    const group = await createGroup();

    const self = await invite(group.id, alice.email);

    expect(self.status).toBe(409);
    expect(self.body.error.code).toBe('ALREADY_MEMBER');
  });

  it('rejects a malformed email', async () => {
    const group = await createGroup();

    const bad = await invite(group.id, 'not-an-email');

    expect(bad.status).toBe(400);
    expect(bad.body.error.code).toBe('VALIDATION_ERROR');
  });

  it('caps members and invites at 50', async () => {
    const group = await createGroup();
    for (let i = 0; i < 49; i++) expect((await invite(group.id, `p${i}@example.com`)).status).toBe(200);

    const full = await invite(group.id, 'one-too-many@example.com');
    expect(full.status).toBe(409);
    expect(full.body.error.code).toBe('GROUP_FULL');

    // Re-inviting an address that's already invited still changes nothing, full or not.
    expect((await invite(group.id, 'p0@example.com')).status).toBe(200);
  });

  it('refuses to accept into a group with 50 members and keeps the invite', async () => {
    const group = await createGroup();
    const inviteId = inviteIdFor((await invite(group.id, bob.email)).body, bob.email);
    const filler = Array.from({ length: 49 }, (_, i) => ({ userId: `sub-${i}`, email: `f${i}@x.mn`, name: `F${i}`, joinedAt: new Date() }));
    await (await getDb())
      .collection('groups')
      .updateOne({ _id: new ObjectId(group.id) }, { $push: { members: { $each: filler } } } as never);

    const res = await call(groups.acceptInvite, { as: bob, method: 'POST', params: { groupId: group.id, inviteId } });

    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('GROUP_FULL');
    expect((await call(groups.listInvites, { as: bob })).body.items).toHaveLength(1);
  });

  it('lets any member cancel an invite', async () => {
    const group = await createGroup();
    await addToGroup(group.id, carol);
    const inviteId = inviteIdFor((await invite(group.id, bob.email)).body, bob.email);

    const cancelled = await call(groups.cancelInvite, { as: carol, method: 'DELETE', params: { groupId: group.id, inviteId } });
    expect(cancelled.status).toBe(200);
    expect(cancelled.body.invites).toEqual([]);
    expect((await call(groups.listInvites, { as: bob })).body.items).toEqual([]);

    const again = await call(groups.cancelInvite, { method: 'DELETE', params: { groupId: group.id, inviteId } });
    expect(again.status).toBe(404);
    expect(again.body.error.code).toBe('INVITE_NOT_FOUND');
  });
});

describe('leaving and removing people', () => {
  const dinner = (groupId: string) =>
    addExpense(groupId, { description: 'Dinner', amountCents: 1000, paidBy: alice.sub, split: { type: 'EVEN', userIds: [alice.sub, bob.sub] } });

  it('blocks leaving until your balance is zero', async () => {
    const group = await createGroup();
    await addToGroup(group.id, bob);
    // Bob owes Alice 500.
    await dinner(group.id);

    const blocked = await call(groups.leave, { as: bob, method: 'POST', params: { groupId: group.id } });
    expect(blocked.status).toBe(409);
    expect(blocked.body.error.code).toBe('BALANCE_NOT_ZERO');

    await settle(group.id, { fromUserId: bob.sub, toUserId: alice.sub, amountCents: 500 }, bob);
    const left = await call(groups.leave, { as: bob, method: 'POST', params: { groupId: group.id } });
    expect(left.status).toBe(200);
    expect(left.body).toEqual({ left: true });
    expect((await call(groups.get, { as: bob, params: { groupId: group.id } })).status).toBe(404);

    // A former member with a zero balance doesn't show in balances.
    const rows = (await call(balances.handler, { params: { groupId: group.id } })).body.balances;
    expect(rows.map((r: { userId: string }) => r.userId)).toEqual([alice.sub]);
  });

  it('deletes the group, invites and all, when the last member leaves', async () => {
    const group = await createGroup();
    await invite(group.id, bob.email);

    const left = await call(groups.leave, { method: 'POST', params: { groupId: group.id } });

    expect(left.status).toBe(200);
    expect((await call(groups.listInvites, { as: bob })).body.items).toEqual([]);
    expect((await groupDoc(group.id))!.deletedAt).toBeInstanceOf(Date);
  });

  it('removes another member only when their balance is zero', async () => {
    const group = await createGroup();
    await addToGroup(group.id, bob);
    await addToGroup(group.id, carol);
    await dinner(group.id);

    const self = await call(groups.removeMember, { method: 'DELETE', params: { groupId: group.id, userId: alice.sub } });
    expect(self.status).toBe(400);
    expect(self.body.error.code).toBe('CANNOT_REMOVE_SELF');

    const stranger = await call(groups.removeMember, { method: 'DELETE', params: { groupId: group.id, userId: mallory.sub } });
    expect(stranger.status).toBe(404);
    expect(stranger.body.error.code).toBe('MEMBER_NOT_FOUND');

    const owing = await call(groups.removeMember, { method: 'DELETE', params: { groupId: group.id, userId: bob.sub } });
    expect(owing.status).toBe(409);
    expect(owing.body.error.code).toBe('BALANCE_NOT_ZERO');

    const removed = await call(groups.removeMember, { as: bob, method: 'DELETE', params: { groupId: group.id, userId: carol.sub } });
    expect(removed.status).toBe(200);
    expect(removed.body.members.map((m: { userId: string }) => m.userId)).toEqual([alice.sub, bob.sub]);
    expect((await call(groups.get, { as: carol, params: { groupId: group.id } })).status).toBe(404);
  });

  it('deletes a group only when every balance is zero, and then it looks missing', async () => {
    const group = await createGroup();
    await addToGroup(group.id, bob);
    await dinner(group.id);

    const blocked = await call(groups.remove, { method: 'DELETE', params: { groupId: group.id } });
    expect(blocked.status).toBe(409);
    expect(blocked.body.error.code).toBe('BALANCES_NOT_ZERO');

    await settle(group.id, { fromUserId: bob.sub, toUserId: alice.sub, amountCents: 500 }, alice);
    const deleted = await call(groups.remove, { as: bob, method: 'DELETE', params: { groupId: group.id } });
    expect(deleted.status).toBe(200);
    expect(deleted.body).toEqual({ id: group.id, deleted: true });

    for (const handler of [groups.get, expenses.list, balances.handler]) {
      const res = await call(handler, { params: { groupId: group.id } });
      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe('GROUP_NOT_FOUND');
    }
    expect((await call(groups.list)).body.items).toEqual([]);
    expect((await call(groups.remove, { method: 'DELETE', params: { groupId: group.id } })).status).toBe(404);
  });
});

describe('someone outside the group', () => {
  const someId = '0'.repeat(24);
  const evenSplit = { type: 'EVEN', userIds: ['sub-mallory'] };

  it.each([
    ['get group', groups.get, 'GET', {}, undefined],
    ['rename', groups.rename, 'PATCH', {}, { name: 'mine now' }],
    ['delete group', groups.remove, 'DELETE', {}, undefined],
    ['invite', groups.invite, 'POST', {}, { email: 'mallory@example.com' }],
    ['cancel invite', groups.cancelInvite, 'DELETE', { inviteId: 'x' }, undefined],
    ['leave', groups.leave, 'POST', {}, undefined],
    ['remove member', groups.removeMember, 'DELETE', { userId: 'sub-alice' }, undefined],
    ['create expense', expenses.create, 'POST', {}, { description: 'x', amountCents: 100, paidBy: 'sub-mallory', split: evenSplit }],
    ['list expenses', expenses.list, 'GET', {}, undefined],
    ['edit expense', expenses.update, 'PUT', { expenseId: someId }, { description: 'x', amountCents: 1, paidBy: 'sub-mallory', split: evenSplit, version: 1 }],
    ['delete expense', expenses.remove, 'DELETE', { expenseId: someId }, undefined],
    ['create settlement', settlements.create, 'POST', {}, { fromUserId: 'sub-mallory', toUserId: 'sub-alice', amountCents: 1 }],
    ['list settlements', settlements.list, 'GET', {}, undefined],
    ['delete settlement', settlements.remove, 'DELETE', { settlementId: someId }, undefined],
    ['balances', balances.handler, 'GET', {}, undefined],
    ['confirm receipt', receipts.confirm, 'PUT', { expenseId: someId }, { key: 'groups/x' }],
  ] as const)('gets 404 GROUP_NOT_FOUND from %s', async (_name, handler, method, params, body) => {
    const group = await createGroup();

    const res = await call(handler, {
      as: mallory,
      method,
      params: { groupId: group.id, ...params },
      body,
      headers: { 'Idempotency-Key': 'mallory-key-123' },
    });

    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe('GROUP_NOT_FOUND');
  });

  it('gets no receipt URLs signed', async () => {
    const group = await createGroup();

    for (const handler of [receipts.uploadUrl, receipts.viewUrl]) {
      const res = await call(handler, { as: mallory, method: 'POST', params: { groupId: group.id, expenseId: someId } });
      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe('GROUP_NOT_FOUND');
    }
  });

  it('gets the same 404 for a malformed group id', async () => {
    const res = await call(groups.get, { params: { groupId: 'not-an-object-id' } });

    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe('GROUP_NOT_FOUND');
  });
});
