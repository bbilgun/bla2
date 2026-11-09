import { randomBytes, randomUUID } from 'node:crypto';
import { ObjectId } from 'mongodb';
import { describe, expect, it, vi } from 'vitest';
import * as billPage from '../../src/handlers/billPage';
import * as bills from '../../src/handlers/bills';
import * as billsRepo from '../../src/repositories/bills';
import { getDb } from '../../src/repositories/db';
import { call, useFakeAwsEnv, useTestDb } from './helpers';

/**
 * The race the guard in repositories/bills.ts exists for: a guest's server request has read the bill,
 * then the host deletes a line, then the guest's write lands. Simulated by running the host's edit
 * inside the repository call, right before the guest's write.
 */
const hooks = vi.hoisted(() => ({ beforeGuestWrite: [] as (() => Promise<void>)[] }));

vi.mock('../../src/repositories/bills', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../src/repositories/bills')>();
  return {
    ...actual,
    updateGuestBySecret: vi.fn(async (...args: Parameters<typeof actual.updateGuestBySecret>) => {
      await hooks.beforeGuestWrite.shift()?.();
      return actual.updateGuestBySecret(...args);
    }),
  };
});

useTestDb();
useFakeAwsEnv();

const payment = { bankName: 'Хаан банк', accountNumber: '5000 1234 56', accountName: 'Билгүүн' };

async function setup() {
  const bill = (
    await call(bills.create, {
      method: 'POST',
      headers: { 'Idempotency-Key': randomUUID() },
      body: { title: 'Оройн хоол', items: [{ name: 'Хуушуур', priceCents: 3_000_000 }, { name: 'Кола', priceCents: 450_000 }], payment },
    })
  ).body;
  const guest = { name: 'Бат', guestId: randomBytes(12).toString('base64url'), secret: randomBytes(32).toString('base64url') };
  await call(billPage.join, { as: null, method: 'POST', params: { token: bill.token }, body: guest });
  const ids = Object.fromEntries(bill.items.map((i: { id: string; name: string }) => [i.name, i.id])) as Record<string, string>;
  const tick = (body: unknown) =>
    call(billPage.updateGuest, {
      as: null,
      method: 'PUT',
      params: { token: bill.token, guestId: guest.guestId },
      headers: { 'x-guest-secret': guest.secret },
      body,
    });
  const hostKeepsOnly = (name: string) => async () => {
    const res = await call(bills.update, {
      method: 'PUT',
      params: { billId: bill.id },
      body: { title: 'Оройн хоол', items: [{ id: ids[name], name, priceCents: 3_000_000 }], payment },
    });
    expect(res.status).toBe(200);
  };
  return { bill, guest, ids, tick, hostKeepsOnly };
}

describe('host removes a line between a guest read and write', () => {
  it('the guest write retries with the fresh lines: 200, no dangling tick, not stuck', async () => {
    const { bill, guest, ids, tick, hostKeepsOnly } = await setup();
    vi.mocked(billsRepo.updateGuestBySecret).mockClear();
    hooks.beforeGuestWrite.push(hostKeepsOnly('Хуушуур'));

    const res = await tick({ itemIds: [ids['Хуушуур'], ids['Кола']], paid: true });
    expect(res.status).toBe(200);
    const me = res.body.guests.find((g: { id: string }) => g.id === guest.guestId);
    // Ticks and the paid amount were both recomputed against the bill as it is now.
    expect(me).toMatchObject({ itemIds: [ids['Хуушуур']], totalCents: 3_000_000, paidCents: 3_000_000, paid: true });
    expect(billsRepo.updateGuestBySecret).toHaveBeenCalledTimes(2);

    const doc = await (await getDb()).collection('bills').findOne({ _id: new ObjectId(bill.id) });
    expect(doc!.guests.find((g: { id: string }) => g.id === guest.guestId).itemIds).toEqual([ids['Хуушуур']]);

    // And the next tick from the same (stale) page just works.
    const next = await tick({ itemIds: [ids['Кола']] });
    expect(next.status).toBe(200);
    expect(next.body.guests.find((g: { id: string }) => g.id === guest.guestId).itemIds).toEqual([]);
  });

  it('if the bill is closed in between, the guest gets BILL_CLOSED, not a silent miss', async () => {
    const { bill, ids, tick } = await setup();
    hooks.beforeGuestWrite.push(async () => {
      await call(bills.setStatus, { method: 'POST', params: { billId: bill.id }, body: { status: 'CLOSED' } });
    });
    const res = await tick({ itemIds: [ids['Кола']] });
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('BILL_CLOSED');
  });

  it('if the guest is removed in between, it is GUEST_NOT_FOUND', async () => {
    const { bill, guest, ids, tick } = await setup();
    hooks.beforeGuestWrite.push(async () => {
      await call(bills.removeGuest, { method: 'DELETE', params: { billId: bill.id, guestId: guest.guestId } });
    });
    const res = await tick({ itemIds: [ids['Кола']] });
    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe('GUEST_NOT_FOUND');
  });
});
