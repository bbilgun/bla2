// QR bills end to end: the host's routes, the public guest routes, and the host's bank QR.
import { randomBytes, randomUUID } from 'node:crypto';
import { ObjectId } from 'mongodb';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import * as billPage from '../../src/handlers/billPage';
import * as bills from '../../src/handlers/bills';
import * as me from '../../src/handlers/me';
import { deleteObject, objectExists } from '../../src/lib/s3';
import { getDb } from '../../src/repositories/db';
import { alice, bob, call, useFakeAwsEnv, useTestDb } from './helpers';

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

const payment = { bankName: 'Хаан банк', accountNumber: '5000 1234 56', accountName: 'Билгүүн' };
const dinner = {
  title: 'Оройн хоол',
  items: [
    { name: 'Хуушуур', priceCents: 3_000_000 },
    { name: 'Кола', priceCents: 450_000 },
    { name: 'Салат', priceCents: 1_200_000 },
  ],
  payment,
};

async function createBill(body: unknown = dinner, key = randomUUID()) {
  return call(bills.create, { method: 'POST', path: '/bills', headers: { 'Idempotency-Key': key }, body });
}

// A guest's browser, which makes up its own id and secret like the page does.
function newGuest(name: string) {
  return { name, guestId: randomBytes(12).toString('base64url'), secret: randomBytes(32).toString('base64url') };
}

async function join(token: string, guest: ReturnType<typeof newGuest>) {
  return call(billPage.join, { as: null, method: 'POST', params: { token }, body: guest });
}

async function tick(token: string, guest: ReturnType<typeof newGuest>, body: unknown, secret = guest.secret) {
  return call(billPage.updateGuest, {
    as: null,
    method: 'PUT',
    params: { token, guestId: guest.guestId },
    headers: { 'x-guest-secret': secret },
    body,
  });
}

const itemId = (bill: { items: { id: string; name: string }[] }, name: string) =>
  bill.items.find((i) => i.name === name)!.id;

interface GuestJson {
  id: string;
  totalCents: number;
  paid: boolean;
  paidCents: number;
  dueCents: number;
  itemIds: string[];
}
const guestOf = (bill: { guests: GuestJson[] }, id: string) => bill.guests.find((g) => g.id === id)!;

describe('the host', () => {
  it('creates a bill with a share link and the host as the first guest', async () => {
    const res = await createBill();

    expect(res.status).toBe(201);
    expect(res.body.url).toMatch(/^https:\/\/.+\/b\/[A-Za-z0-9_-]{22}$/);
    expect(res.body.url.endsWith(res.body.token)).toBe(true);
    expect(res.body.code).toMatch(/^[A-Z2-9]{6}$/);
    expect(res.body.currency).toBe('MNT');
    expect(res.body.totalCents).toBe(4_650_000);
    expect(res.body.unclaimedCents).toBe(4_650_000);
    expect(res.body.guests).toEqual([
      { id: 'host', name: 'Alice', isHost: true, paid: false, paidCents: 0, dueCents: 0, itemIds: [], totalCents: 0 },
    ]);
    expect(res.body.payment).toEqual({ bankName: 'Хаан банк', accountNumber: '5000 1234 56', accountName: 'Билгүүн' });
  });

  it('gets the bank details back from GET /me for the next bill', async () => {
    await createBill();

    const profile = await call(me.handler);

    expect(profile.body.payment).toEqual(payment);
    expect(profile.body.payQrUrl).toBeNull();
  });

  it('gets the same bill back from a retried create', async () => {
    const key = randomUUID();

    const first = await createBill(dinner, key);
    const again = await createBill(dinner, key);

    expect(again.status).toBe(201);
    expect(again.headers['idempotent-replayed']).toBe('true');
    expect(again.body.id).toBe(first.body.id);
    expect((await call(bills.list)).body.items).toHaveLength(1);
  });

  it('gets 400 for bad lines or a missing Idempotency-Key', async () => {
    const noItems = await createBill({ title: 'x', items: [] });
    expect(noItems.status).toBe(400);
    const float = await createBill({ title: 'x', items: [{ name: 'a', priceCents: 10.5 }] });
    expect(float.status).toBe(400);
    const noKey = await call(bills.create, { method: 'POST', body: dinner });
    expect(noKey.body.error.code).toBe('IDEMPOTENCY_KEY_REQUIRED');
  });

  it('is the only one who can see or change the bill', async () => {
    const bill = (await createBill()).body;
    const bat = newGuest('Бат');
    await join(bill.token, bat);
    for (const [handler, method, extra] of [
      [bills.get, 'GET', {}],
      [bills.update, 'PUT', { body: dinner }],
      [bills.setStatus, 'POST', { body: { status: 'CLOSED' } }],
      [bills.updateGuest, 'PUT', { params: { billId: bill.id, guestId: 'host' }, body: { paid: true } }],
      [bills.removeGuest, 'DELETE', { params: { billId: bill.id, guestId: bat.guestId } }],
      [bills.rotateToken, 'POST', {}],
      [bills.remove, 'DELETE', {}],
    ] as const) {
      const res = await call(handler, { as: bob, method, params: { billId: bill.id }, ...extra });
      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe('BILL_NOT_FOUND');
    }
    expect((await call(bills.list, { as: bob })).body.items).toEqual([]);
    // Nothing changed.
    const mine = (await call(bills.get, { params: { billId: bill.id } })).body;
    expect(mine.token).toBe(bill.token);
    expect(mine.guests).toHaveLength(2);
    expect(mine.status).toBe('OPEN');
  });

  it('pages through their bills newest first', async () => {
    const ids: string[] = [];
    for (let i = 0; i < 3; i++) ids.push((await createBill({ ...dinner, title: `B${i}` })).body.id);

    const first = await call(bills.list, { query: { limit: '2' } });
    expect(first.body.items.map((b: { id: string }) => b.id)).toEqual([ids[2], ids[1]]);
    const second = await call(bills.list, { query: { limit: '2', cursor: first.body.nextCursor } });
    expect(second.body.items.map((b: { id: string }) => b.id)).toEqual([ids[0]]);
    expect(second.body.nextCursor).toBeNull();
    expect((await call(bills.list, { query: { cursor: 'bad' } })).status).toBe(400);
  });

  it('deletes a bill for good, and its link stops working', async () => {
    const bill = (await createBill()).body;

    const res = await call(bills.remove, { method: 'DELETE', params: { billId: bill.id } });

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ id: bill.id, deleted: true });
    expect((await call(bills.get, { params: { billId: bill.id } })).status).toBe(404);
    expect((await call(billPage.data, { as: null, params: { token: bill.token } })).status).toBe(404);
    const again = await call(bills.remove, { method: 'DELETE', params: { billId: bill.id } });
    expect(again.status).toBe(404);
    expect(again.body.error.code).toBe('BILL_NOT_FOUND');
  });

  it('replaces the link by rotating the token, keeping guests and ticks', async () => {
    const bill = (await createBill()).body;
    const bat = newGuest('Бат');
    await join(bill.token, bat);
    await tick(bill.token, bat, { itemIds: [itemId(bill, 'Кола')] });

    const rotated = await call(bills.rotateToken, { method: 'POST', params: { billId: bill.id } });
    expect(rotated.status).toBe(200);
    expect(rotated.body.token).not.toBe(bill.token);
    expect(rotated.body.token).toMatch(/^[A-Za-z0-9_-]{22}$/);
    expect(rotated.body.url.endsWith(`/b/${rotated.body.token}`)).toBe(true);
    expect(guestOf(rotated.body, bat.guestId).totalCents).toBe(450_000);

    const old = await call(billPage.data, { as: null, params: { token: bill.token } });
    expect(old.status).toBe(404);
    expect(old.body.error.code).toBe('BILL_NOT_FOUND');
    expect((await tick(bill.token, bat, { paid: true })).status).toBe(404);
    expect((await tick(rotated.body.token, bat, { paid: true })).status).toBe(200);
  });
});

describe('guests with just the link', () => {
  it('get the page as HTML with a nonce-locked CSP', async () => {
    const res = await call(billPage.page, { as: null, params: { token: 'x' } });

    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toBe('text/html; charset=utf-8');
    const csp = String(res.headers['content-security-policy']);
    const nonce = /script-src 'nonce-([^']+)'/.exec(csp)![1]!;
    expect(res.body).toContain(`<script nonce="${nonce}">`);
    expect(csp).toContain("default-src 'none'");
    expect(csp).toContain('img-src https://netzero-test-receipts.s3.ap-northeast-1.amazonaws.com;');
    expect(csp).not.toContain('*');
    expect(res.body).not.toContain('innerHTML');
  });

  it('get 404 for a bad or unknown token', async () => {
    for (const token of ['short', 'A'.repeat(22)]) {
      const res = await call(billPage.data, { as: null, params: { token } });
      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe('BILL_NOT_FOUND');
    }
  });

  it('join, tick, see shared lines split and mark paid, with no secrets in any response', async () => {
    const bill = (await createBill()).body;
    const bat = newGuest('Бат');
    const saraa = newGuest('Сараа');

    const joined = await join(bill.token, bat);
    expect(joined.status).toBe(201);
    expect(joined.body.guestId).toBe(bat.guestId);
    await join(bill.token, saraa);

    const khuushuur = itemId(bill, 'Хуушуур');
    const cola = itemId(bill, 'Кола');
    await tick(bill.token, bat, { itemIds: [khuushuur, cola] });
    const after = await tick(bill.token, saraa, { itemIds: [khuushuur] });
    expect(after.status).toBe(200);
    expect(guestOf(after.body, bat.guestId).totalCents).toBe(1_500_000 + 450_000);
    expect(guestOf(after.body, saraa.guestId).totalCents).toBe(1_500_000);
    expect(after.body.unclaimedCents).toBe(1_200_000);
    expect(after.body.owedCents).toBe(3_450_000);

    // The host ticks the salad from the app. The host doesn't owe themselves, so owedCents stays put.
    const host = await call(bills.updateGuest, {
      method: 'PUT',
      params: { billId: bill.id, guestId: 'host' },
      body: { itemIds: [itemId(bill, 'Салат')] },
    });
    expect(host.body.unclaimedCents).toBe(0);
    expect(guestOf(host.body, 'host').totalCents).toBe(1_200_000);
    expect(host.body.owedCents).toBe(3_450_000);

    const paid = await tick(bill.token, bat, { paid: true });
    expect(guestOf(paid.body, bat.guestId).paid).toBe(true);
    expect(paid.body.paidCents).toBe(1_950_000);

    const everything = JSON.stringify([joined.body, after.body, host.body, paid.body]);
    expect(everything).not.toContain(bat.secret);
    expect(everything).not.toContain('secretHash');
    expect(everything).not.toContain('hostUserId');
  });

  it('are added once when a join is retried', async () => {
    const bill = (await createBill()).body;
    const bat = newGuest('Бат');
    expect((await join(bill.token, bat)).status).toBe(201);

    const retry = await join(bill.token, bat);

    expect(retry.status).toBe(201);
    expect(retry.body.bill.guests).toHaveLength(2);

    // The same id with another secret is someone else.
    const impostor = await join(bill.token, { ...bat, secret: randomBytes(32).toString('base64url') });
    expect(impostor.status).toBe(409);
    expect(impostor.body.error.code).toBe('GUEST_ID_TAKEN');
  });

  it('need their own secret to change their entry', async () => {
    const bill = (await createBill()).body;
    const bat = newGuest('Бат');
    const saraa = newGuest('Сараа');
    await join(bill.token, bat);
    await join(bill.token, saraa);

    const wrong = await tick(bill.token, bat, { paid: true }, saraa.secret);
    expect(wrong.status).toBe(404);
    expect(wrong.body.error.code).toBe('GUEST_NOT_FOUND');
    const none = await call(billPage.updateGuest, {
      as: null,
      method: 'PUT',
      params: { token: bill.token, guestId: bat.guestId },
      body: { paid: true },
    });
    expect(none.status).toBe(404);
    const host = await call(billPage.updateGuest, {
      as: null,
      method: 'PUT',
      params: { token: bill.token, guestId: 'host' },
      headers: { 'x-guest-secret': '' },
      body: { paid: true },
    });
    expect(host.status).toBe(404);
  });

  it('have ticks on lines not on the bill dropped', async () => {
    const bill = (await createBill()).body;
    const bat = newGuest('Бат');
    await join(bill.token, bat);
    const cola = itemId(bill, 'Кола');

    const res = await tick(bill.token, bat, { itemIds: ['nope', cola, cola] });

    expect(res.status).toBe(200);
    expect(guestOf(res.body, bat.guestId).itemIds).toEqual([cola]);
    expect(guestOf(res.body, bat.guestId).totalCents).toBe(450_000);
  });

  it('can keep ticking from a page that still shows a deleted line', async () => {
    const bill = (await createBill()).body;
    const bat = newGuest('Бат');
    await join(bill.token, bat);
    const [khuushuur, cola] = [itemId(bill, 'Хуушуур'), itemId(bill, 'Кола')];
    await tick(bill.token, bat, { itemIds: [khuushuur] });
    // The host removes the cola line.
    await call(bills.update, {
      method: 'PUT',
      params: { billId: bill.id },
      body: { title: dinner.title, items: [{ id: khuushuur, name: 'Хуушуур', priceCents: 3_000_000 }], payment },
    });
    // Bat's page, loaded before that, ticks it.
    const res = await tick(bill.token, bat, { itemIds: [khuushuur, cola] });

    expect(res.status).toBe(200);
    expect(guestOf(res.body, bat.guestId).itemIds).toEqual([khuushuur]);
  });

  it('have the paid amount stored, with later changes shown as due or overpaid', async () => {
    const bill = (await createBill()).body;
    const bat = newGuest('Бат');
    await join(bill.token, bat);
    const [cola, salad] = [itemId(bill, 'Кола'), itemId(bill, 'Салат')];
    await tick(bill.token, bat, { itemIds: [cola] });

    const paid = await tick(bill.token, bat, { paid: true, paidCents: 450_000 });
    expect(guestOf(paid.body, bat.guestId)).toMatchObject({ paid: true, paidCents: 450_000, dueCents: 0, totalCents: 450_000 });
    expect(paid.body.paidCents).toBe(450_000);

    // Ticking more keeps the payment and shows what's still due.
    const more = await tick(bill.token, bat, { itemIds: [cola, salad] });
    expect(guestOf(more.body, bat.guestId)).toMatchObject({ paid: false, paidCents: 450_000, dueCents: 1_200_000 });

    // Unticking everything means they paid too much.
    const less = await tick(bill.token, bat, { itemIds: [] });
    expect(guestOf(less.body, bat.guestId)).toMatchObject({ paid: true, paidCents: 450_000, dueCents: -450_000, totalCents: 0 });

    // `paid: true` without an amount stores the current total, counting this request's ticks.
    const all = await tick(bill.token, bat, { itemIds: [cola, salad], paid: true });
    expect(guestOf(all.body, bat.guestId)).toMatchObject({ paid: true, paidCents: 1_650_000, dueCents: 0 });

    // `paid: false` clears it whatever amount is sent.
    const undo = await tick(bill.token, bat, { paid: false, paidCents: 5 });
    expect(guestOf(undo.body, bat.guestId)).toMatchObject({ paid: false, paidCents: 0, dueCents: 1_650_000 });

    // Paying less than the total is recorded but isn't "paid".
    const partial = await tick(bill.token, bat, { paid: true, paidCents: 1_000_000 });
    expect(guestOf(partial.body, bat.guestId)).toMatchObject({ paid: false, paidCents: 1_000_000, dueCents: 650_000 });
    const summary = (await call(bills.list)).body.items[0];
    expect(summary).toMatchObject({ paidCents: 1_000_000, paidCount: 0, owedCents: 1_650_000 });

    const float = await tick(bill.token, bat, { paid: true, paidCents: 10.5 });
    expect(float.body.error.code).toBe('VALIDATION_ERROR');
  });

  it('have an old paid flag read as paying the current total', async () => {
    const bill = (await createBill()).body;
    const bat = newGuest('Бат');
    await join(bill.token, bat);
    await tick(bill.token, bat, { itemIds: [itemId(bill, 'Кола')] });
    await (await getDb())
      .collection('bills')
      .updateOne(
        { _id: new ObjectId(bill.id), 'guests.id': bat.guestId },
        { $set: { 'guests.$.paid': true }, $unset: { 'guests.$.paidCents': '', 'guests.$.nameKey': '' } },
      );
    const data = (await call(billPage.data, { as: null, params: { token: bill.token } })).body;
    expect(guestOf(data, bat.guestId)).toMatchObject({ paid: true, paidCents: 450_000, dueCents: 0 });
    expect(data.paidCents).toBe(450_000);
    // A name stored without a nameKey still counts for NAME_TAKEN.
    expect((await join(bill.token, newGuest('бат'))).body.error.code).toBe('NAME_TAKEN');
    // The next write replaces the old flag with an amount.
    const undo = await tick(bill.token, bat, { paid: false });
    expect(guestOf(undo.body, bat.guestId)).toMatchObject({ paid: false, paidCents: 0 });
    const doc = await (await getDb()).collection('bills').findOne({ _id: new ObjectId(bill.id) });
    expect(doc!.guests[1].paid).toBeUndefined();
  });

  it('get NAME_TAKEN for a name already on the bill, ignoring case and spaces', async () => {
    const bill = (await createBill()).body;
    expect((await join(bill.token, newGuest('Бат'))).status).toBe(201);
    for (const name of ['Бат', '  бат ', 'БАТ', 'alice', 'Alice']) {
      const res = await join(bill.token, newGuest(name));
      expect(res.status).toBe(409);
      expect(res.body.error.code).toBe('NAME_TAKEN');
    }
    expect((await join(bill.token, newGuest('Бат Д.'))).status).toBe(201);
  });

  it('get only one of several same-name joins in at once', async () => {
    const bill = (await createBill()).body;

    const results = await Promise.all(Array.from({ length: 5 }, () => join(bill.token, newGuest('Сараа'))));

    expect(results.filter((r) => r.status === 201)).toHaveLength(1);
    expect(results.filter((r) => r.status === 409).every((r) => r.body.error.code === 'NAME_TAKEN')).toBe(true);
  });

  it('get GUEST_REMOVED when rejoining with the id the host removed', async () => {
    const bill = (await createBill()).body;
    const bat = newGuest('Бат');
    await join(bill.token, bat);
    await call(bills.removeGuest, { method: 'DELETE', params: { billId: bill.id, guestId: bat.guestId } });

    const res = await join(bill.token, bat);

    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('GUEST_REMOVED');
    // The name is free again for a new guest.
    expect((await join(bill.token, newGuest('Бат'))).status).toBe(201);
  });

  it('get 410 BILL_EXPIRED 90 days after the bill was created', async () => {
    const bill = (await createBill()).body;
    const bat = newGuest('Бат');
    await join(bill.token, bat);
    const age = async (days: number) =>
      (await getDb())
        .collection('bills')
        .updateOne({ _id: new ObjectId(bill.id) }, { $set: { createdAt: new Date(Date.now() - days * 86_400_000) } });

    await age(89);
    expect((await call(billPage.data, { as: null, params: { token: bill.token } })).status).toBe(200);

    await age(91);
    for (const res of [
      await call(billPage.data, { as: null, params: { token: bill.token } }),
      await join(bill.token, newGuest('Late')),
      await tick(bill.token, bat, { paid: true }),
    ]) {
      expect(res.status).toBe(410);
      expect(res.body.error.code).toBe('BILL_EXPIRED');
    }
    // The page itself still loads to show the message, and the host still sees the bill in the app.
    expect((await call(billPage.page, { as: null, params: { token: bill.token } })).status).toBe(200);
    expect((await call(bills.get, { params: { billId: bill.id } })).status).toBe(200);
  });

  it('can still mark paid on a closed bill, but not join or tick', async () => {
    const bill = (await createBill()).body;
    const bat = newGuest('Бат');
    await join(bill.token, bat);
    await tick(bill.token, bat, { itemIds: [itemId(bill, 'Кола')] });
    const closed = await call(bills.setStatus, { method: 'POST', params: { billId: bill.id }, body: { status: 'CLOSED' } });
    expect(closed.body.status).toBe('CLOSED');

    expect((await join(bill.token, newGuest('Late'))).body.error.code).toBe('BILL_CLOSED');
    expect((await tick(bill.token, bat, { itemIds: [] })).body.error.code).toBe('BILL_CLOSED');
    const paid = await tick(bill.token, bat, { paid: true });
    expect(paid.status).toBe(200);
    expect(guestOf(paid.body, bat.guestId).paid).toBe(true);
  });

  it('are capped at 50 people, host included', async () => {
    const bill = (await createBill()).body;
    for (let i = 0; i < 49; i++) expect((await join(bill.token, newGuest(`G${i}`))).status).toBe(201);

    const full = await join(bill.token, newGuest('One too many'));

    expect(full.status).toBe(409);
    expect(full.body.error.code).toBe('BILL_FULL');
  });
});

describe('the host managing a bill', () => {
  it('keeps ticks on lines that stay when editing and drops the rest', async () => {
    const bill = (await createBill()).body;
    const bat = newGuest('Бат');
    await join(bill.token, bat);
    const khuushuur = itemId(bill, 'Хуушуур');
    const cola = itemId(bill, 'Кола');
    await tick(bill.token, bat, { itemIds: [khuushuur, cola] });

    const edited = await call(bills.update, {
      method: 'PUT',
      params: { billId: bill.id },
      body: {
        title: 'Оройн хоол',
        items: [
          { id: khuushuur, name: 'Хуушуур', priceCents: 3_300_000 },
          { name: 'Цай', priceCents: 200_000 },
        ],
        payment,
      },
    });
    expect(edited.status).toBe(200);
    expect(itemId(edited.body, 'Хуушуур')).toBe(khuushuur);
    expect(guestOf(edited.body, bat.guestId).itemIds).toEqual([khuushuur]);
    expect(guestOf(edited.body, bat.guestId).totalCents).toBe(3_300_000);
  });

  it('has to reopen a closed bill before editing it', async () => {
    const bill = (await createBill()).body;
    await call(bills.setStatus, { method: 'POST', params: { billId: bill.id }, body: { status: 'CLOSED' } });

    const res = await call(bills.update, { method: 'PUT', params: { billId: bill.id }, body: { ...dinner, title: 'Changed' } });
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('BILL_CLOSED');
    expect((await call(bills.get, { params: { billId: bill.id } })).body.title).toBe('Оройн хоол');

    await call(bills.setStatus, { method: 'POST', params: { billId: bill.id }, body: { status: 'OPEN' } });
    const reopened = await call(bills.update, { method: 'PUT', params: { billId: bill.id }, body: { ...dinner, title: 'Changed' } });
    expect(reopened.status).toBe(200);
    expect(reopened.body.title).toBe('Changed');
  });

  it('marks a cash payment and removes a guest, but never the host', async () => {
    const bill = (await createBill()).body;
    const bat = newGuest('Бат');
    await join(bill.token, bat);
    await tick(bill.token, bat, { itemIds: [itemId(bill, 'Кола')] });

    const cash = await call(bills.updateGuest, {
      method: 'PUT',
      params: { billId: bill.id, guestId: bat.guestId },
      body: { paid: true },
    });
    expect(guestOf(cash.body, bat.guestId)).toMatchObject({ paid: true, paidCents: 450_000 });

    const removed = await call(bills.removeGuest, { method: 'DELETE', params: { billId: bill.id, guestId: bat.guestId } });
    expect(removed.body.guests.map((g: { id: string }) => g.id)).toEqual(['host']);
    expect((await tick(bill.token, bat, { paid: true })).status).toBe(404);

    const host = await call(bills.removeGuest, { method: 'DELETE', params: { billId: bill.id, guestId: 'host' } });
    expect(host.body.error.code).toBe('CANNOT_REMOVE_HOST');
  });

  it('sees totals and how many have paid in the list', async () => {
    const bill = (await createBill()).body;
    const bat = newGuest('Бат');
    await join(bill.token, bat);
    await tick(bill.token, bat, { itemIds: [itemId(bill, 'Кола')], paid: true });

    const list = await call(bills.list);

    expect(list.body.items[0]).toMatchObject({
      id: bill.id,
      title: 'Оройн хоол',
      totalCents: 4_650_000,
      owedCents: 450_000,
      paidCents: 450_000,
      guestCount: 1,
      paidCount: 1,
      status: 'OPEN',
    });
  });

  it('uploads a bank QR that guests then see', async () => {
    const bill = (await createBill()).body;
    const upload = await call(me.payQrUploadUrl, { method: 'POST', body: { contentType: 'image/png' } });
    expect(upload.status).toBe(200);
    expect(upload.body).toMatchObject({ method: 'POST', maxBytes: 10 * 1024 * 1024, expiresIn: 300 });
    expect(upload.body.key).toMatch(new RegExp(`^users/${alice.sub}/pay-qr/[0-9a-f-]{36}\\.png$`));
    expect(upload.body.uploadUrl).toBe('https://netzero-test-receipts.s3.ap-northeast-1.amazonaws.com/');
    expect(upload.body.fields).toMatchObject({ key: upload.body.key, 'Content-Type': 'image/png' });
    const policy = JSON.parse(Buffer.from(upload.body.fields.Policy, 'base64').toString('utf8'));
    expect(policy.conditions).toEqual(
      expect.arrayContaining([
        ['content-length-range', 1, 10 * 1024 * 1024],
        ['eq', '$Content-Type', 'image/png'],
      ]),
    );

    // Signing alone saves nothing.
    expect((await call(billPage.data, { as: null, params: { token: bill.token } })).body.hasPayQr).toBe(false);

    const confirmed = await call(me.confirmPayQr, { method: 'PUT', body: { key: upload.body.key } });
    expect(confirmed.status).toBe(200);
    expect(new URL(confirmed.body.payQrUrl).pathname).toBe(`/${upload.body.key}`);
    expect(objectExists).toHaveBeenCalledWith(upload.body.key);
    expect(deleteObject).not.toHaveBeenCalled();

    const guest = await call(billPage.data, { as: null, params: { token: bill.token } });
    expect(guest.body.hasPayQr).toBe(true);
    expect(new URL(guest.body.payQrUrl).pathname).toBe(`/${upload.body.key}`);
    expect((await call(me.handler)).body.payQrUrl).toContain(upload.body.key);

    // The guest page's CSP allows images from exactly the host the QR URL points at.
    const page = await call(billPage.page, { as: null, params: { token: bill.token } });
    expect(String(page.headers['content-security-policy'])).toContain(`img-src ${new URL(guest.body.payQrUrl).origin};`);

    // A new QR replaces the old one, and the old object is deleted.
    const next = await call(me.payQrUploadUrl, { method: 'POST' });
    await call(me.confirmPayQr, { method: 'PUT', body: { key: next.body.key } });
    expect(deleteObject).toHaveBeenCalledWith(upload.body.key);
    // A failed cleanup doesn't fail the request.
    vi.mocked(deleteObject).mockRejectedValueOnce(new Error('s3 down'));
    const third = await call(me.payQrUploadUrl, { method: 'POST' });
    expect((await call(me.confirmPayQr, { method: 'PUT', body: { key: third.body.key } })).status).toBe(200);
  });

  it('can confirm only their own QR key, and only once it is uploaded', async () => {
    const upload = (await call(me.payQrUploadUrl, { method: 'POST' })).body;
    for (const key of [
      upload.key.replace(alice.sub, bob.sub),
      `users/${alice.sub}/pay-qr/../../groups/x.jpg`,
      `users/${alice.sub}/pay-qr/not-a-uuid.jpg`,
      'groups/a/expenses/b/00000000-0000-0000-0000-000000000000.jpg',
    ]) {
      const res = await call(me.confirmPayQr, { method: 'PUT', body: { key } });
      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('INVALID_UPLOAD_KEY');
    }
    vi.mocked(objectExists).mockResolvedValueOnce(false);
    const missing = await call(me.confirmPayQr, { method: 'PUT', body: { key: upload.key } });
    expect(missing.status).toBe(409);
    expect(missing.body.error.code).toBe('UPLOAD_NOT_FOUND');
    expect((await call(me.handler)).body.payQrUrl).toBeNull();
  });
});
