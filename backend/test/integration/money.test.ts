import { randomUUID } from 'node:crypto';
import { beforeEach, describe, expect, it } from 'vitest';
import * as balances from '../../src/handlers/balances';
import * as expenses from '../../src/handlers/expenses';
import * as groups from '../../src/handlers/groups';
import * as me from '../../src/handlers/me';
import * as settlements from '../../src/handlers/settlements';
import { getDb } from '../../src/repositories/db';
import { claimKey } from '../../src/repositories/idempotency';
import { insertExpenseOnce } from '../../src/repositories/expenses';
import { alice, bob, call, carol, useTestDb } from './helpers';
import { ObjectId } from 'mongodb';

useTestDb();

let groupId: string;

beforeEach(async () => {
  await call(me.handler, { as: bob });
  await call(me.handler, { as: carol });
  const res = await call(groups.create, { method: 'POST', path: '/groups', body: { name: 'Flat' } });
  groupId = res.body.id;
  for (const u of [bob, carol]) {
    await call(groups.addMember, { method: 'POST', params: { groupId }, body: { email: u.email } });
  }
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
  it('the server computes the split', async () => {
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
  });

  it('requires an Idempotency-Key', async () => {
    const res = await addExpense(dinner, { key: null });
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('IDEMPOTENCY_KEY_REQUIRED');
  });
});

describe('idempotency', () => {
  const count = async () => (await getDb()).collection('expenses').countDocuments();

  it('replay: the same key sent twice writes once and returns the same body', async () => {
    const key = randomUUID();
    const first = await addExpense(dinner, { key });
    const second = await addExpense(dinner, { key });

    expect(first.status).toBe(201);
    expect(second.status).toBe(201);
    expect(second.body).toEqual(first.body);
    expect(second.headers['idempotent-replayed']).toBe('true');
    expect(await count()).toBe(1);
  });

  it('concurrent retries with one key still write once', async () => {
    const key = randomUUID();
    const results = await Promise.all(Array.from({ length: 8 }, () => addExpense(dinner, { key })));
    expect(new Set(results.map((r) => r.body.id)).size).toBe(1);
    expect(results.every((r) => r.status === 201)).toBe(true);
    expect(await count()).toBe(1);
  });

  it('reusing a key for a different request is a 422', async () => {
    const key = randomUUID();
    await addExpense(dinner, { key });
    const res = await addExpense({ ...dinner, amountCents: 999 }, { key });
    expect(res.status).toBe(422);
    expect(res.body.error.code).toBe('IDEMPOTENCY_KEY_REUSED');
    expect(await count()).toBe(1);
  });

  it('keys are per user: two users can use the same key', async () => {
    const key = randomUUID();
    await addExpense(dinner, { key });
    await addExpense({ ...dinner, paidBy: bob.sub }, { key, as: bob });
    expect(await count()).toBe(2);
  });

  it('a crash between the write and recording the response does not double-write', async () => {
    // Simulate attempt #1: key claimed, expense written, then Lambda died before completeKey().
    const key = randomUUID();
    const body = JSON.stringify(dinner);
    const { createHash } = await import('node:crypto');
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
      createdBy: alice.sub,
      createdAt: new Date(),
    });

    // Attempt #2 (the client's retry) finds the pending key, reuses resourceId, and inserts nothing new.
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
    await addExpense(dinner); // alice +6666, bob -3333, carol -3333
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

  it('only a party to the payment can record it', async () => {
    const res = await settle({ fromUserId: bob.sub, toUserId: carol.sub, amountCents: 100 }, alice);
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('NOT_A_PARTY');
  });

  it('is idempotent', async () => {
    const key = randomUUID();
    const send = () =>
      call(settlements.create, {
        method: 'POST',
        path: `/groups/${groupId}/settlements`,
        params: { groupId },
        body: { fromUserId: alice.sub, toUserId: bob.sub, amountCents: 500 },
        headers: { 'Idempotency-Key': key },
      });
    const [a, b] = [await send(), await send()];
    expect(b.body).toEqual(a.body);
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

  it('always sums to exactly 0, whatever the ledger looks like', async () => {
    const people = [alice, bob, carol];
    let seed = 7;
    const rand = (n: number) => {
      seed = (seed * 16_807) % 2_147_483_647;
      return seed % n;
    };
    for (let i = 0; i < 40; i++) {
      const payer = people[rand(3)]!;
      const amountCents = 1 + rand(1_000_000);
      const kind = rand(3);
      const split =
        kind === 0
          ? { type: 'EVEN', userIds: people.slice(0, 1 + rand(3)).map((p) => p.sub) }
          : kind === 1
            ? { type: 'PERCENT', shares: [{ userId: alice.sub, basisPoints: 3333 }, { userId: bob.sub, basisPoints: 3333 }, { userId: carol.sub, basisPoints: 3334 }] }
            : { type: 'EXACT', shares: [{ userId: payer.sub, amountCents }] };
      const res = await addExpense({ description: `e${i}`, amountCents, paidBy: payer.sub, split }, { as: payer });
      expect(res.status).toBe(201);
      if (i % 5 === 0) {
        const res2 = await call(settlements.create, {
          as: bob,
          method: 'POST',
          params: { groupId },
          body: { fromUserId: bob.sub, toUserId: carol.sub, amountCents: 1 + rand(5000) },
          headers: { 'Idempotency-Key': randomUUID() },
        });
        expect(res2.status).toBe(201);
      }
    }
    const { balances: rows } = await getBalances();
    expect(rows.reduce((a, r) => a + r.netCents, 0)).toBe(0);
    expect(rows.every((r) => Number.isInteger(r.netCents))).toBe(true);
  });
});

describe('GET /groups/{id}/expenses pagination', () => {
  it('pages newest-first by _id with no gaps or repeats', async () => {
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
});
