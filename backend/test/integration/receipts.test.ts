import { randomUUID } from 'node:crypto';
import { beforeAll, describe, expect, it } from 'vitest';
import * as expenses from '../../src/handlers/expenses';
import * as groups from '../../src/handlers/groups';
import * as receipts from '../../src/handlers/receipts';
import { alice, call, useTestDb } from './helpers';

useTestDb();

beforeAll(() => {
  // Presigning is a local computation: fake credentials are enough, nothing is sent to AWS.
  process.env.RECEIPTS_BUCKET = 'netzero-test-receipts';
  process.env.AWS_REGION = 'ap-northeast-1';
  process.env.AWS_ACCESS_KEY_ID = 'AKIATESTTESTTESTTEST';
  process.env.AWS_SECRET_ACCESS_KEY = 'test-secret';
  delete process.env.AWS_PROFILE;
  delete process.env.AWS_SESSION_TOKEN;
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

describe('receipts', () => {
  it('signs a PUT under groups/{groupId}/expenses/{expenseId}/ and then a GET for it', async () => {
    const ids = await setup();

    const none = await call(receipts.viewUrl, { params: ids });
    expect(none.status).toBe(404);
    expect(none.body.error.code).toBe('RECEIPT_NOT_FOUND');

    const upload = await call(receipts.uploadUrl, { method: 'POST', params: ids, body: { contentType: 'image/jpeg' } });
    expect(upload.status).toBe(200);
    expect(upload.body.key).toMatch(new RegExp(`^groups/${ids.groupId}/expenses/${ids.expenseId}/[0-9a-f-]{36}\\.jpg$`));
    const put = new URL(upload.body.uploadUrl);
    expect(put.hostname).toContain('netzero-test-receipts');
    expect(put.searchParams.get('X-Amz-Expires')).toBe('300');

    const list = await call(expenses.list, { params: { groupId: ids.groupId } });
    expect(list.body.items[0].hasReceipt).toBe(true);

    const view = await call(receipts.viewUrl, { params: ids });
    expect(view.status).toBe(200);
    expect(new URL(view.body.url).pathname).toBe(`/${upload.body.key}`);
  });

  it('works with no body (defaults to JPEG)', async () => {
    const ids = await setup();
    const upload = await call(receipts.uploadUrl, { method: 'POST', params: ids });
    expect(upload.status).toBe(200);
    expect(upload.body.headers['content-type']).toBe('image/jpeg');
  });

  it('404s for an expense in another group', async () => {
    const a = await setup();
    const b = await setup();
    const res = await call(receipts.uploadUrl, { method: 'POST', params: { groupId: a.groupId, expenseId: b.expenseId } });
    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe('EXPENSE_NOT_FOUND');
  });
});
