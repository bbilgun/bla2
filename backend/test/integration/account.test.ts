// DELETE /me: refused while money is owed, otherwise removes the user from everything, safe to retry.
import { randomUUID } from 'node:crypto';
import { ObjectId } from 'mongodb';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import * as bills from '../../src/handlers/bills';
import * as expenses from '../../src/handlers/expenses';
import * as groups from '../../src/handlers/groups';
import * as me from '../../src/handlers/me';
import * as settlements from '../../src/handlers/settlements';
import { deleteCognitoUser } from '../../src/lib/cognito';
import { deleteObject } from '../../src/lib/s3';
import { getDb } from '../../src/repositories/db';
import { addToGroup, alice, bob, call, useFakeAwsEnv, useTestDb } from './helpers';

vi.mock('../../src/lib/cognito', () => ({ deleteCognitoUser: vi.fn(async () => undefined) }));
vi.mock('../../src/lib/s3', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../src/lib/s3')>()),
  objectExists: vi.fn(async () => true),
  deleteObject: vi.fn(async () => undefined),
}));

useTestDb();
useFakeAwsEnv();
beforeEach(() => {
  vi.mocked(deleteCognitoUser).mockReset().mockResolvedValue(undefined);
  vi.mocked(deleteObject).mockReset().mockResolvedValue(undefined);
});

const deleteMe = () => call(me.remove, { method: 'DELETE', path: '/me' });

async function createGroup(name: string) {
  return (await call(groups.create, { method: 'POST', body: { name } })).body.id as string;
}

function addExpense(groupId: string, amountCents: number) {
  return call(expenses.create, {
    method: 'POST',
    path: `/groups/${groupId}/expenses`,
    params: { groupId },
    headers: { 'Idempotency-Key': randomUUID() },
    body: { description: 'Dinner', amountCents, paidBy: alice.sub, split: { type: 'EVEN', userIds: [alice.sub, bob.sub] } },
  });
}

describe('DELETE /me', () => {
  it('is refused while the caller has a balance anywhere, naming those groups', async () => {
    const owed = await createGroup('Owed');
    const settled = await createGroup('Settled');
    await addToGroup(owed, bob);
    await addToGroup(settled, bob);
    await addExpense(owed, 1000);

    const res = await deleteMe();
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('BALANCES_NOT_ZERO');
    expect(res.body.error.details).toEqual([{ groupId: owed, name: 'Owed' }]);
    // Nothing was deleted.
    expect(deleteCognitoUser).not.toHaveBeenCalled();
    expect((await call(groups.list)).body.items).toHaveLength(2);
  });

  it('leaves every group and deletes bills, the QR image, the users row and the Cognito user', async () => {
    const shared = await createGroup('Shared');
    const solo = await createGroup('Solo');
    await addToGroup(shared, bob);
    await addExpense(shared, 1000);
    await call(settlements.create, {
      as: bob,
      method: 'POST',
      path: `/groups/${shared}/settlements`,
      params: { groupId: shared },
      headers: { 'Idempotency-Key': randomUUID() },
      body: { fromUserId: bob.sub, toUserId: alice.sub, amountCents: 500 },
    });
    await call(bills.create, {
      method: 'POST',
      headers: { 'Idempotency-Key': randomUUID() },
      body: { title: 'Bill', items: [{ name: 'Tea', priceCents: 100 }] },
    });
    const qr = (await call(me.payQrUploadUrl, { method: 'POST' })).body.key;
    await call(me.confirmPayQr, { method: 'PUT', body: { key: qr } });

    const res = await deleteMe();
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ deleted: true });
    expect(deleteCognitoUser).toHaveBeenCalledExactlyOnceWith(alice.sub);
    expect(deleteObject).toHaveBeenCalledWith(qr);

    const db = await getDb();
    expect(await db.collection('users').findOne({ _id: alice.sub as never })).toBeNull();
    expect(await db.collection('bills').countDocuments({ hostUserId: alice.sub })).toBe(0);
    expect(await db.collection('idempotency_keys').countDocuments({ userId: alice.sub })).toBe(0);

    // Bob keeps the shared group and its history, and Alice is gone from it. Her balance was zero.
    const bobsGroup = await call(groups.get, { as: bob, params: { groupId: shared } });
    expect(bobsGroup.body.members.map((m: { userId: string }) => m.userId)).toEqual([bob.sub]);
    expect((await call(expenses.list, { as: bob, params: { groupId: shared } })).body.items).toHaveLength(1);
    // The group only Alice was in is deleted.
    const soloDoc = await db.collection('groups').findOne({ _id: new ObjectId(solo) });
    expect(soloDoc!.deletedAt).toBeInstanceOf(Date);
  });

  it('finishes on retry after Cognito fails part-way', async () => {
    await createGroup('Mine');
    vi.mocked(deleteCognitoUser).mockRejectedValueOnce(new Error('cognito unavailable'));

    const failed = await deleteMe();
    expect(failed.status).toBe(500);
    expect(failed.body.error.code).toBe('INTERNAL');

    const retry = await deleteMe();
    expect(retry.status).toBe(200);
    expect(deleteCognitoUser).toHaveBeenCalledTimes(2);
    expect((await deleteMe()).status).toBe(200);
  });
});
