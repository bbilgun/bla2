// Expenses, idempotency, settlements, balances and paging: everything that moves money in a group.
import { createHash, randomUUID } from 'node:crypto';
import { ObjectId } from 'mongodb';
import { beforeEach, describe, expect, it } from 'vitest';
import * as balances from '../../src/handlers/balances';
import * as expenses from '../../src/handlers/expenses';
import * as groups from '../../src/handlers/groups';
import * as me from '../../src/handlers/me';
import * as settlements from '../../src/handlers/settlements';
import { getDb } from '../../src/repositories/db';
import { insertExpenseOnce } from '../../src/repositories/expenses';
import { claimKey } from '../../src/repositories/idempotency';
import { addToGroup, alice, bob, call, carol, mallory, useTestDb } from './helpers';

useTestDb();

let groupId: string;

beforeEach(async () => {
  await call(me.handler, { as: bob });
  await call(me.handler, { as: carol });
  const res = await call(groups.create, { method: 'POST', path: '/groups', body: { name: 'Flat' } });
  groupId = res.body.id;
  for (const user of [bob, carol]) await addToGroup(groupId, user);
});

const path = () => `/groups/${groupId}/expenses`;

function addExpense(body: unknown, opts: { key?: string | null; as?: typeof alice } = {}) {
  const key = opts.key === undefined ? randomUUID() : opts.key;
  return call(expenses.create, {
    as: opts.as ?? alice,
    method: 'POST',
    path: path(),
    params: { groupId },
    body,
    headers: key ? { 'Idempotency-Key': key } : {},
  });
}

const dinner = {
  description: 'Dinner',
  amountCents: 10_000,
  paidBy: alice.sub,
  split: { type: 'EVEN', userIds: [alice.sub, bob.sub, carol.sub] },
};

async function getBalances() {
  const res = await call(balances.handler, { params: { groupId } });
  expect(res.status).toBe(200);
  return res.body as {
    balances: { userId: string; netCents: number }[];
    transfers: { fromUserId: string; toUserId: string; amountCents: number }[];
  };
}

describe('POST /groups/{id}/expenses', () => {
  it('computes the split on the server', async () => {
    const res = await addExpense(dinner);

    expect(res.status).toBe(201);
    expect(res.body.splits).toEqual([
      { userId: 'sub-alice', amountCents: 3334 },
      { userId: 'sub-bob', amountCents: 3333 },
      { userId: 'sub-carol', amountCents: 3333 },
    ]);
  });

  it('supports EXACT and PERCENT', async () => {
    const exact = await addExpense({
      ...dinner,
      split: {
        type: 'EXACT',
        shares: [
          { userId: alice.sub, amountCents: 5000 },
          { userId: bob.sub, amountCents: 5000 },
        ],
      },
    });
    expect(exact.status).toBe(201);

    const percent = await addExpense({
      ...dinner,
      split: {
        type: 'PERCENT',
        shares: [
          { userId: alice.sub, basisPoints: 2500 },
          { userId: carol.sub, basisPoints: 7500 },
        ],
      },
    });
    expect(percent.status).toBe(201);
    expect(percent.body.splits).toEqual([
      { userId: 'sub-alice', amountCents: 2500 },
      { userId: 'sub-carol', amountCents: 7500 },
    ]);
  });

  it('rejects floats, bad splits and non-members', async () => {
    const float = await addExpense({ ...dinner, amountCents: 12.5 });
    expect(float.status).toBe(400);
    expect(float.body.error.code).toBe('VALIDATION_ERROR');

    const mismatch = await addExpense({ ...dinner, split: { type: 'EXACT', shares: [{ userId: alice.sub, amountCents: 1 }] } });
    expect(mismatch.body.error.code).toBe('SPLIT_SUM_MISMATCH');

    const payer = await addExpense({ ...dinner, paidBy: 'sub-stranger' });
    expect(payer.body.error.code).toBe('PAYER_NOT_MEMBER');

    const outsider = await addExpense({ ...dinner, split: { type: 'EVEN', userIds: [alice.sub, 'sub-stranger'] } });
    expect(outsider.body.error.code).toBe('SPLIT_USER_NOT_MEMBER');
    expect(outsider.body.error.details).toEqual({ userIds: ['sub-stranger'] });

    const exact = await addExpense({
      ...dinner,
      split: { type: 'EXACT', shares: [{ userId: alice.sub, amountCents: 5000 }, { userId: mallory.sub, amountCents: 5000 }] },
    });
    expect(exact.status).toBe(400);
    expect(exact.body.error.code).toBe('SPLIT_USER_NOT_MEMBER');

    const percent = await addExpense({
      ...dinner,
      split: { type: 'PERCENT', shares: [{ userId: mallory.sub, basisPoints: 10_000 }] },
    });
    expect(percent.status).toBe(400);
    expect(percent.body.error.code).toBe('SPLIT_USER_NOT_MEMBER');
    expect(await (await getDb()).collection('expenses').countDocuments()).toBe(0);
  });

  it('requires a well-formed Idempotency-Key', async () => {
    const res = await addExpense(dinner, { key: null });
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('IDEMPOTENCY_KEY_REQUIRED');
    for (const key of ['short', 'has spaces in it', 'x'.repeat(129), 'émoji-key-123']) {
      const bad = await addExpense(dinner, { key });
      expect(bad.status).toBe(400);
      expect(bad.body.error.code).toBe('IDEMPOTENCY_KEY_INVALID');
    }
  });
});

describe('idempotency', () => {
  const count = async () => (await getDb()).collection('expenses').countDocuments();

  it('replays a repeated key without writing again', async () => {
    const key = randomUUID();

    const first = await addExpense(dinner, { key });
    const second = await addExpense(dinner, { key });

    expect(first.status).toBe(201);
    expect(second.status).toBe(201);
    expect(second.body).toEqual(first.body);
    expect(second.headers['idempotent-replayed']).toBe('true');
    expect(await count()).toBe(1);
  });

  it('writes once under concurrent retries with one key', async () => {
    const key = randomUUID();

    const results = await Promise.all(Array.from({ length: 8 }, () => addExpense(dinner, { key })));

    expect(new Set(results.map((r) => r.body.id)).size).toBe(1);
    expect(results.every((r) => r.status === 201)).toBe(true);
    expect(await count()).toBe(1);
  });

  it('returns 422 when a key is reused for a different body', async () => {
    const key = randomUUID();
    await addExpense(dinner, { key });

    const res = await addExpense({ ...dinner, amountCents: 999 }, { key });

    expect(res.status).toBe(422);
    expect(res.body.error.code).toBe('IDEMPOTENCY_KEY_REUSED');
    expect(await count()).toBe(1);
  });

  it('returns 422 when a key is reused on another route', async () => {
    const key = randomUUID();
    expect((await addExpense(dinner, { key })).status).toBe(201);

    const res = await call(settlements.create, {
      method: 'POST',
      path: `/groups/${groupId}/settlements`,
      params: { groupId },
      body: { fromUserId: alice.sub, toUserId: bob.sub, amountCents: 100 },
      headers: { 'Idempotency-Key': key },
    });

    expect(res.status).toBe(422);
    expect(res.body.error.code).toBe('IDEMPOTENCY_KEY_REUSED');
    expect(await (await getDb()).collection('settlements').countDocuments()).toBe(0);
  });

  it('scopes keys to the user who sent them', async () => {
    const key = randomUUID();

    await addExpense(dinner, { key });
    await addExpense({ ...dinner, paidBy: bob.sub }, { key, as: bob });

    expect(await count()).toBe(2);
  });

  it('does not double-write when a crash came before the response was stored', async () => {
    // Attempt 1: the key was claimed and the expense written, then the Lambda died before completeKey().
    const key = randomUUID();
    const body = JSON.stringify(dinner);
    const requestHash = createHash('sha256').update(`POST ${path()}\n${body}`).digest('hex');
    const claim = await claimKey({ userId: alice.sub, key, requestHash });
    await insertExpenseOnce({
      _id: claim.doc.resourceId,
      groupId: new ObjectId(groupId),
      description: 'Dinner',
      amountCents: 10_000,
      paidBy: alice.sub,
      splitType: 'EVEN',
      splits: [],
      version: 1,
      createdBy: alice.sub,
      createdAt: new Date(),
    });

    // Attempt 2, the client's retry, finds the pending key, reuses resourceId and inserts nothing new.
    const retry = await addExpense(dinner, { key });

    expect(retry.status).toBe(201);
    expect(retry.body.id).toBe(claim.doc.resourceId.toHexString());
    expect(await count()).toBe(1);
  });
});

describe('settlements', () => {
  function settle(body: unknown, as = alice) {
    return call(settlements.create, {
      as,
      method: 'POST',
      path: `/groups/${groupId}/settlements`,
      params: { groupId },
      body,
      headers: { 'Idempotency-Key': randomUUID() },
    });
  }

  it('records a payment and moves the balances', async () => {
    // Alice +6666, Bob -3333, Carol -3333.
    await addExpense(dinner);

    const res = await settle({ fromUserId: bob.sub, toUserId: alice.sub, amountCents: 3333 }, bob);

    expect(res.status).toBe(201);

    const { balances: rows } = await getBalances();
    expect(rows).toEqual([
      expect.objectContaining({ userId: alice.sub, netCents: 3333 }),
      expect.objectContaining({ userId: bob.sub, netCents: 0 }),
      expect.objectContaining({ userId: carol.sub, netCents: -3333 }),
    ]);

    const list = await call(settlements.list, { params: { groupId } });
    expect(list.body.items).toHaveLength(1);
  });

  it('lets only someone in the payment record it', async () => {
    const res = await settle({ fromUserId: bob.sub, toUserId: carol.sub, amountCents: 100 }, alice);

    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('NOT_A_PARTY');
  });

  it('requires both people to be in the group', async () => {
    const res = await settle({ fromUserId: alice.sub, toUserId: mallory.sub, amountCents: 100 });

    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('SETTLEMENT_USER_NOT_MEMBER');
  });

  it('soft-deletes a payment, only for the people in it, and can repeat', async () => {
    await addExpense(dinner);
    const paid = (await settle({ fromUserId: bob.sub, toUserId: alice.sub, amountCents: 3333 }, bob)).body;
    const params = { groupId, settlementId: paid.id };

    const stranger = await call(settlements.remove, { as: carol, method: 'DELETE', params });
    expect(stranger.status).toBe(403);
    expect(stranger.body.error.code).toBe('NOT_A_PARTY');

    const deleted = await call(settlements.remove, { as: alice, method: 'DELETE', params });
    expect(deleted.status).toBe(200);
    expect(deleted.body).toEqual({ id: paid.id, deleted: true });
    const again = await call(settlements.remove, { as: bob, method: 'DELETE', params });
    expect(again.body).toEqual({ id: paid.id, deleted: true });

    const { balances: rows } = await getBalances();
    expect(rows.find((r) => r.userId === bob.sub)!.netCents).toBe(-3333);
    expect((await call(settlements.list, { params: { groupId } })).body.items).toEqual([]);
    // Kept in the database, marked deleted.
    expect(await (await getDb()).collection('settlements').countDocuments()).toBe(1);

    for (const settlementId of [new ObjectId().toHexString(), 'nope']) {
      const missing = await call(settlements.remove, { method: 'DELETE', params: { groupId, settlementId } });
      expect(missing.status).toBe(404);
      expect(missing.body.error.code).toBe('SETTLEMENT_NOT_FOUND');
    }
  });

  it('pages newest first', async () => {
    for (let i = 1; i <= 5; i++) await settle({ fromUserId: alice.sub, toUserId: bob.sub, amountCents: i });

    const first = await call(settlements.list, { params: { groupId }, query: { limit: '3' } });
    expect(first.body.items.map((s: { amountCents: number }) => s.amountCents)).toEqual([5, 4, 3]);
    const second = await call(settlements.list, { params: { groupId }, query: { limit: '3', cursor: first.body.nextCursor } });
    expect(second.body.items.map((s: { amountCents: number }) => s.amountCents)).toEqual([2, 1]);
    expect(second.body.nextCursor).toBeNull();
  });

  it('writes once for a repeated key', async () => {
    const key = randomUUID();
    const send = () =>
      call(settlements.create, {
        method: 'POST',
        path: `/groups/${groupId}/settlements`,
        params: { groupId },
        body: { fromUserId: alice.sub, toUserId: bob.sub, amountCents: 500 },
        headers: { 'Idempotency-Key': key },
      });

    const first = await send();
    const second = await send();

    expect(second.body).toEqual(first.body);
    expect(await (await getDb()).collection('settlements').countDocuments()).toBe(1);
  });
});

describe('GET /groups/{id}/balances', () => {
  it('derives balances and suggests who pays whom', async () => {
    await addExpense(dinner);

    const { balances: rows, transfers } = await getBalances();

    expect(rows.map((r) => [r.userId, r.netCents])).toEqual([
      [alice.sub, 6666],
      [bob.sub, -3333],
      [carol.sub, -3333],
    ]);
    expect(transfers).toEqual([
      { fromUserId: bob.sub, toUserId: alice.sub, amountCents: 3333 },
      { fromUserId: carol.sub, toUserId: alice.sub, amountCents: 3333 },
    ]);
  });

  it('shows everyone at zero for a new group', async () => {
    const { balances: rows, transfers } = await getBalances();

    expect(rows.every((r) => r.netCents === 0)).toBe(true);
    expect(rows).toHaveLength(3);
    expect(transfers).toEqual([]);
  });

  it('always sums to zero over a random ledger', async () => {
    const people = [alice, bob, carol];
    let seed = 7;
    const rand = (n: number) => {
      seed = (seed * 16_807) % 2_147_483_647;
      return seed % n;
    };
    const thirds = [
      { userId: alice.sub, basisPoints: 3333 },
      { userId: bob.sub, basisPoints: 3333 },
      { userId: carol.sub, basisPoints: 3334 },
    ];
    const randomSplit = (payer: typeof alice, amountCents: number) => {
      const kind = rand(3);
      if (kind === 0) return { type: 'EVEN', userIds: people.slice(0, 1 + rand(3)).map((person) => person.sub) };
      if (kind === 1) return { type: 'PERCENT', shares: thirds };
      return { type: 'EXACT', shares: [{ userId: payer.sub, amountCents }] };
    };

    for (let i = 0; i < 40; i++) {
      const payer = people[rand(3)]!;
      const amountCents = 1 + rand(1_000_000);
      const split = randomSplit(payer, amountCents);
      const res = await addExpense({ description: `e${i}`, amountCents, paidBy: payer.sub, split }, { as: payer });
      expect(res.status).toBe(201);
      if (i % 5 === 0) {
        const payment = await call(settlements.create, {
          as: bob,
          method: 'POST',
          params: { groupId },
          body: { fromUserId: bob.sub, toUserId: carol.sub, amountCents: 1 + rand(5000) },
          headers: { 'Idempotency-Key': randomUUID() },
        });
        expect(payment.status).toBe(201);
      }
    }

    const { balances: rows } = await getBalances();

    expect(rows.reduce((a, r) => a + r.netCents, 0)).toBe(0);
    expect(rows.every((r) => Number.isInteger(r.netCents))).toBe(true);
  });
});

describe('GET /groups/{id}/expenses pagination', () => {
  it('pages newest first by _id with no gaps or repeats', async () => {
    for (let i = 0; i < 25; i++) await addExpense({ ...dinner, description: `#${i}` });

    const seen: string[] = [];
    let cursor: string | undefined;
    let pages = 0;
    do {
      const res = await call(expenses.list, { params: { groupId }, query: { limit: '10', ...(cursor && { cursor }) } });
      expect(res.status).toBe(200);
      seen.push(...res.body.items.map((e: { description: string }) => e.description));
      cursor = res.body.nextCursor ?? undefined;
      pages++;
    } while (cursor);

    expect(pages).toBe(3);
    expect(seen).toEqual(Array.from({ length: 25 }, (_, i) => `#${24 - i}`));
  });

  it('rejects an invalid cursor', async () => {
    for (const cursor of ['not-an-id', '0'.repeat(23), 'Z'.repeat(24)]) {
      const res = await call(expenses.list, { params: { groupId }, query: { cursor } });
      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('VALIDATION_ERROR');
    }
  });
});

describe('editing an expense', () => {
  const edit = (expenseId: string, body: unknown, as = alice) =>
    call(expenses.update, { as, method: 'PUT', params: { groupId, expenseId }, body });

  it('lets any member edit, bumps the version and recomputes the split', async () => {
    const created = (await addExpense(dinner)).body;
    expect(created).toMatchObject({ version: 1, updatedAt: null, updatedBy: null });

    const res = await edit(created.id, { ...dinner, amountCents: 9_000, split: { type: 'EVEN', userIds: [bob.sub, carol.sub] }, version: 1 }, bob);
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ id: created.id, version: 2, amountCents: 9_000, updatedBy: bob.sub, createdBy: alice.sub });
    expect(res.body.updatedAt).toEqual(expect.any(String));
    expect(res.body.splits).toEqual([
      { userId: bob.sub, amountCents: 4500 },
      { userId: carol.sub, amountCents: 4500 },
    ]);

    const { balances: rows } = await getBalances();
    expect(rows.map((r) => [r.userId, r.netCents])).toEqual([
      [alice.sub, 9000],
      [bob.sub, -4500],
      [carol.sub, -4500],
    ]);
    const listed = (await call(expenses.list, { params: { groupId } })).body.items;
    expect(listed).toHaveLength(1);
    expect(listed[0].version).toBe(2);
  });

  it('rejects a stale version but accepts a retry of the same edit', async () => {
    const created = (await addExpense(dinner)).body;
    const mine = { ...dinner, description: 'Dinner + tip', amountCents: 11_000, version: 1 };
    expect((await edit(created.id, mine)).body.version).toBe(2);

    // The response was lost and the app retries the same edit: same content, 200, no new version.
    const retry = await edit(created.id, mine);
    expect(retry.status).toBe(200);
    expect(retry.body.version).toBe(2);

    // Bob edits from a screen loaded before Alice's change.
    const stale = await edit(created.id, { ...dinner, description: 'Lunch', version: 1 }, bob);
    expect(stale.status).toBe(409);
    expect(stale.body.error.code).toBe('EXPENSE_CHANGED');

    // After reloading he has version 2 and it works.
    expect((await edit(created.id, { ...dinner, description: 'Lunch', version: 2 }, bob)).body.version).toBe(3);
  });

  it('lets exactly one of several racing edits win', async () => {
    const created = (await addExpense(dinner)).body;

    const results = await Promise.all(
      [1, 2, 3, 4].map((n) => edit(created.id, { ...dinner, description: `Edit ${n}`, version: 1 })),
    );

    expect(results.filter((r) => r.status === 200)).toHaveLength(1);
    expect(results.filter((r) => r.status === 409).every((r) => r.body.error.code === 'EXPENSE_CHANGED')).toBe(true);
  });

  it('keeps the last 20 versions on the server with who changed them', async () => {
    const created = (await addExpense(dinner)).body;

    for (let version = 1; version <= 25; version++) {
      const editor = version % 2 ? bob : alice;
      const res = await edit(created.id, { ...dinner, description: `v${version + 1}`, version }, editor);
      expect(res.status).toBe(200);
    }

    const doc = await (await getDb()).collection('expenses').findOne({ _id: new ObjectId(created.id) });
    expect(doc!.version).toBe(26);
    expect(doc!.history).toHaveLength(20);
    expect(doc!.history[0]).toMatchObject({ version: 6, description: 'v6', changedBy: alice.sub });
    expect(doc!.history[19]).toMatchObject({ version: 25, description: 'v25', changedBy: bob.sub, changedAt: expect.any(Date) });
    // History is never sent to the app.
    expect((await call(expenses.list, { params: { groupId } })).body.items[0].history).toBeUndefined();
  });

  it('validates like create and returns 404 for a missing or deleted expense', async () => {
    const created = (await addExpense(dinner)).body;
    const payer = await edit(created.id, { ...dinner, paidBy: mallory.sub, version: 1 });
    expect(payer.body.error.code).toBe('PAYER_NOT_MEMBER');
    const split = await edit(created.id, { ...dinner, split: { type: 'EVEN', userIds: [mallory.sub] }, version: 1 });
    expect(split.body.error.code).toBe('SPLIT_USER_NOT_MEMBER');
    const noVersion = await edit(created.id, dinner);
    expect(noVersion.body.error.code).toBe('VALIDATION_ERROR');

    const missing = await edit(new ObjectId().toHexString(), { ...dinner, version: 1 });
    expect(missing.status).toBe(404);
    expect(missing.body.error.code).toBe('EXPENSE_NOT_FOUND');

    await call(expenses.remove, { method: 'DELETE', params: { groupId, expenseId: created.id } });
    const deleted = await edit(created.id, { ...dinner, version: 1 });
    expect(deleted.status).toBe(404);
    expect(deleted.body.error.code).toBe('EXPENSE_NOT_FOUND');
  });

  it('treats an expense without a version field as version 1', async () => {
    const created = (await addExpense(dinner)).body;
    await (await getDb()).collection('expenses').updateOne({ _id: new ObjectId(created.id) }, { $unset: { version: '' } });

    expect((await call(expenses.list, { params: { groupId } })).body.items[0].version).toBe(1);
    const res = await edit(created.id, { ...dinner, description: 'Edited', version: 1 });
    expect(res.status).toBe(200);
    expect(res.body.version).toBe(2);
  });
});

describe('deleting an expense', () => {
  it('soft-deletes, and deleting twice is fine', async () => {
    const keep = (await addExpense({ ...dinner, description: 'Keep' })).body;
    const drop = (await addExpense({ ...dinner, description: 'Drop', paidBy: bob.sub }, { as: bob })).body;

    const res = await call(expenses.remove, { as: carol, method: 'DELETE', params: { groupId, expenseId: drop.id } });
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ id: drop.id, deleted: true });
    const again = await call(expenses.remove, { method: 'DELETE', params: { groupId, expenseId: drop.id } });
    expect(again.status).toBe(200);
    expect(again.body).toEqual({ id: drop.id, deleted: true });

    const listed = (await call(expenses.list, { params: { groupId } })).body.items;
    expect(listed.map((e: { id: string }) => e.id)).toEqual([keep.id]);
    const { balances: rows } = await getBalances();
    expect(rows.map((r) => [r.userId, r.netCents])).toEqual([
      [alice.sub, 6666],
      [bob.sub, -3333],
      [carol.sub, -3333],
    ]);
    const doc = await (await getDb()).collection('expenses').findOne({ _id: new ObjectId(drop.id) });
    expect(doc).toMatchObject({ deletedBy: carol.sub, deletedAt: expect.any(Date) });

    const missing = await call(expenses.remove, { method: 'DELETE', params: { groupId, expenseId: new ObjectId().toHexString() } });
    expect(missing.status).toBe(404);
    expect(missing.body.error.code).toBe('EXPENSE_NOT_FOUND');
  });

  it('skips deleted expenses when paging', async () => {
    const ids: string[] = [];
    for (let i = 0; i < 6; i++) ids.push((await addExpense({ ...dinner, description: `#${i}` })).body.id);
    for (const id of [ids[1], ids[4]]) await call(expenses.remove, { method: 'DELETE', params: { groupId, expenseId: id! } });

    const first = await call(expenses.list, { params: { groupId }, query: { limit: '2' } });
    const second = await call(expenses.list, { params: { groupId }, query: { limit: '2', cursor: first.body.nextCursor } });

    expect([...first.body.items, ...second.body.items].map((e: { description: string }) => e.description)).toEqual(['#5', '#3', '#2', '#0']);
    expect(second.body.nextCursor).toBeNull();
  });
});
