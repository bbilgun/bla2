import { describe, expect, it } from 'vitest';
import * as balances from '../../src/handlers/balances';
import * as expenses from '../../src/handlers/expenses';
import * as groups from '../../src/handlers/groups';
import * as me from '../../src/handlers/me';
import * as receipts from '../../src/handlers/receipts';
import * as settlements from '../../src/handlers/settlements';
import { alice, bob, call, mallory, useTestDb } from './helpers';

useTestDb();

async function createGroup(name = 'Trip') {
  const res = await call(groups.create, { method: 'POST', path: '/groups', body: { name } });
  expect(res.status).toBe(201);
  return res.body as { id: string; members: { userId: string }[] };
}

describe('GET /me', () => {
  it('returns the caller from the token claims', async () => {
    const res = await call(me.handler, { as: bob });
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ userId: bob.sub, email: bob.email, name: bob.name, payment: null, payQrUrl: null });
  });

  it('401 without claims (the authorizer would normally stop this first)', async () => {
    const res = await call(me.handler, { as: null });
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('UNAUTHORIZED');
  });
});

describe('groups', () => {
  it('create, list mine, get one', async () => {
    const group = await createGroup('Tokyo trip');
    expect(group.members.map((m) => m.userId)).toEqual([alice.sub]);

    const list = await call(groups.list);
    expect(list.body.items.map((g: { id: string }) => g.id)).toEqual([group.id]);

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
    const res = await groups.create(
      {
        body: '{nope',
        headers: {},
        requestContext: { authorizer: { jwt: { claims: { sub: 'x' } } }, http: { method: 'POST' } },
      } as never,
      {} as never,
    );
    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body!).error.code).toBe('INVALID_JSON');
  });

  it('adds a member by email once they have signed in', async () => {
    const group = await createGroup();

    const before = await call(groups.addMember, { method: 'POST', params: { groupId: group.id }, body: { email: bob.email } });
    expect(before.status).toBe(404);
    expect(before.body.error.code).toBe('USER_NOT_FOUND');

    await call(me.handler, { as: bob }); // bob signs in for the first time

    const added = await call(groups.addMember, {
      method: 'POST',
      params: { groupId: group.id },
      body: { email: 'BOB@example.com' },
    });
    expect(added.status).toBe(200);
    expect(added.body.members.map((m: { userId: string }) => m.userId)).toEqual([alice.sub, bob.sub]);

    // adding twice is a no-op
    const again = await call(groups.addMember, { method: 'POST', params: { groupId: group.id }, body: { email: bob.email } });
    expect(again.body.members).toHaveLength(2);

    // and now bob can see it
    const bobs = await call(groups.list, { as: bob });
    expect(bobs.body.items).toHaveLength(1);
  });
});

describe('outsiders get 404 GROUP_NOT_FOUND on every group route', () => {
  it.each([
    ['get group', groups.get, 'GET', undefined],
    ['add member', groups.addMember, 'POST', { email: 'mallory@example.com' }],
    ['create expense', expenses.create, 'POST', { description: 'x', amountCents: 100, paidBy: 'sub-mallory', split: { type: 'EVEN', userIds: ['sub-mallory'] } }],
    ['list expenses', expenses.list, 'GET', undefined],
    ['create settlement', settlements.create, 'POST', { fromUserId: 'sub-mallory', toUserId: 'sub-alice', amountCents: 1 }],
    ['list settlements', settlements.list, 'GET', undefined],
    ['balances', balances.handler, 'GET', undefined],
  ] as const)('%s', async (_name, handler, method, body) => {
    const group = await createGroup();
    const res = await call(handler, {
      as: mallory,
      method,
      params: { groupId: group.id },
      body,
      headers: { 'Idempotency-Key': 'mallory-key-123' },
    });
    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe('GROUP_NOT_FOUND');
  });

  it('receipt URLs too: nothing is signed for a group you are not in', async () => {
    const group = await createGroup();
    for (const handler of [receipts.uploadUrl, receipts.viewUrl]) {
      const res = await call(handler, { as: mallory, method: 'POST', params: { groupId: group.id, expenseId: '0'.repeat(24) } });
      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe('GROUP_NOT_FOUND');
    }
  });

  it('a malformed id looks exactly like a missing group', async () => {
    const res = await call(groups.get, { params: { groupId: 'not-an-object-id' } });
    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe('GROUP_NOT_FOUND');
  });
});
