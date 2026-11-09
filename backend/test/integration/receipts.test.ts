// Receipt photos: signing an upload, confirming it, replacing it and signing a view URL.
import { randomUUID } from 'node:crypto';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import * as expenses from '../../src/handlers/expenses';
import * as groups from '../../src/handlers/groups';
import * as receipts from '../../src/handlers/receipts';
import { deleteObject, objectExists } from '../../src/lib/s3';
import { alice, call, useFakeAwsEnv, useTestDb } from './helpers';

// HEAD and DELETE would reach S3. Signing is local, so it runs for real.
vi.mock('../../src/lib/s3', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../src/lib/s3')>()),
  objectExists: vi.fn(async () => true),
  deleteObject: vi.fn(async () => undefined),
}));

useTestDb();
useFakeAwsEnv();
beforeEach(() => {
  vi.mocked(objectExists).mockClear().mockResolvedValue(true);
  vi.mocked(deleteObject).mockClear().mockResolvedValue(undefined);
});

async function setup() {
  const group = (await call(groups.create, { method: 'POST', body: { name: 'Receipts' } })).body;
  const expense = (
    await call(expenses.create, {
      method: 'POST',
      params: { groupId: group.id },
      headers: { 'Idempotency-Key': randomUUID() },
      body: { description: 'Taxi', amountCents: 2500, paidBy: alice.sub, split: { type: 'EVEN', userIds: [alice.sub] } },
    })
  ).body;
  return { groupId: group.id as string, expenseId: expense.id as string };
}

const sign = (ids: { groupId: string; expenseId: string }, body?: unknown) =>
  call(receipts.uploadUrl, { method: 'POST', params: ids, body });
const confirm = (ids: { groupId: string; expenseId: string }, key: string) =>
  call(receipts.confirm, { method: 'PUT', params: ids, body: { key } });

describe('receipts', () => {
  it('signs an upload, saves it on confirm, then signs a view URL', async () => {
    const ids = await setup();

    const none = await call(receipts.viewUrl, { params: ids });
    expect(none.status).toBe(404);
    expect(none.body.error.code).toBe('RECEIPT_NOT_FOUND');

    const upload = await sign(ids, { contentType: 'image/jpeg' });
    expect(upload.status).toBe(200);
    expect(upload.body).toMatchObject({
      uploadUrl: 'https://netzero-test-receipts.s3.ap-northeast-1.amazonaws.com/',
      method: 'POST',
      maxBytes: 10_485_760,
      expiresIn: 300,
    });
    expect(upload.body.key).toMatch(new RegExp(`^groups/${ids.groupId}/expenses/${ids.expenseId}/[0-9a-f-]{36}\\.jpg$`));
    expect(upload.body.fields).toMatchObject({ key: upload.body.key, 'Content-Type': 'image/jpeg' });
    expect(upload.body.fields['X-Amz-Signature']).toMatch(/^[0-9a-f]{64}$/);
    const policy = JSON.parse(Buffer.from(upload.body.fields.Policy, 'base64').toString('utf8'));
    expect(policy.conditions).toEqual(
      expect.arrayContaining([
        ['content-length-range', 1, 10_485_760],
        ['eq', '$Content-Type', 'image/jpeg'],
        { bucket: 'netzero-test-receipts' },
        { key: upload.body.key },
      ]),
    );

    // Signed but not confirmed, so nothing points at it yet.
    expect((await call(expenses.list, { params: { groupId: ids.groupId } })).body.items[0].hasReceipt).toBe(false);

    const confirmed = await confirm(ids, upload.body.key);
    expect(confirmed.status).toBe(200);
    expect(confirmed.body).toMatchObject({ id: ids.expenseId, hasReceipt: true });
    expect(objectExists).toHaveBeenCalledWith(upload.body.key);
    expect((await call(expenses.list, { params: { groupId: ids.groupId } })).body.items[0].hasReceipt).toBe(true);

    const view = await call(receipts.viewUrl, { params: ids });
    expect(view.status).toBe(200);
    expect(new URL(view.body.url).pathname).toBe(`/${upload.body.key}`);
  });

  it('defaults to JPEG when there is no body', async () => {
    const ids = await setup();

    const upload = await sign(ids);

    expect(upload.status).toBe(200);
    expect(upload.body.fields['Content-Type']).toBe('image/jpeg');
  });

  it('replaces the old receipt and deletes its object only once', async () => {
    const ids = await setup();
    const first = (await sign(ids)).body.key;
    await confirm(ids, first);
    const second = (await sign(ids, { contentType: 'image/png' })).body.key;

    expect((await confirm(ids, second)).status).toBe(200);
    expect(deleteObject).toHaveBeenCalledExactlyOnceWith(first);

    // A retried confirm deletes nothing.
    expect((await confirm(ids, second)).status).toBe(200);
    expect(deleteObject).toHaveBeenCalledTimes(1);
  });

  it('confirms only a key under this expense that is really in S3', async () => {
    const a = await setup();
    const b = await setup();
    const keyForB = (await sign(b)).body.key;
    const badKeys = [
      keyForB,
      `groups/${a.groupId}/expenses/${a.expenseId}/x.jpg`,
      `groups/${a.groupId}/expenses/${a.expenseId}/../${b.expenseId}/k.jpg`,
    ];

    for (const key of badKeys) {
      const res = await confirm(a, key);
      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('INVALID_UPLOAD_KEY');
    }

    const keyForA = (await sign(a)).body.key;
    vi.mocked(objectExists).mockResolvedValueOnce(false);
    const missing = await confirm(a, keyForA);
    expect(missing.status).toBe(409);
    expect(missing.body.error.code).toBe('UPLOAD_NOT_FOUND');
    expect((await call(receipts.viewUrl, { params: a })).body.error.code).toBe('RECEIPT_NOT_FOUND');
  });

  it('returns 404 for an expense in another group', async () => {
    const a = await setup();
    const b = await setup();

    const res = await sign({ groupId: a.groupId, expenseId: b.expenseId });

    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe('EXPENSE_NOT_FOUND');
  });

  it('returns 404 on every receipt route for a deleted expense', async () => {
    const ids = await setup();
    const key = (await sign(ids)).body.key;
    await confirm(ids, key);

    await call(expenses.remove, { method: 'DELETE', params: ids });

    for (const res of [await sign(ids), await call(receipts.viewUrl, { params: ids }), await confirm(ids, key)]) {
      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe('EXPENSE_NOT_FOUND');
    }
  });
});
