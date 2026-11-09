import { randomBytes, randomUUID } from 'node:crypto';
import { beforeAll, describe, expect, it } from 'vitest';
import * as billPage from '../../src/handlers/billPage';
import * as bills from '../../src/handlers/bills';
import * as me from '../../src/handlers/me';
import { alice, bob, call, useTestDb } from './helpers';

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

/** A guest's browser: makes up its own id and secret, like the page does. */
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
  itemIds: string[];
}
const guestOf = (bill: { guests: GuestJson[] }, id: string) => bill.guests.find((g) => g.id === id)!;

describe('host creates a bill', () => {
  it('returns a share link, MNT by default, the host as the first guest, and nothing claimed yet', async () => {
    const res = await createBill();
    expect(res.status).toBe(201);
    expect(res.body.url).toMatch(/^https:\/\/.+\/b\/[A-Za-z0-9_-]{22}$/);
    expect(res.body.url.endsWith(res.body.token)).toBe(true);
    expect(res.body.code).toMatch(/^[A-Z2-9]{6}$/);
    expect(res.body.currency).toBe('MNT');
    expect(res.body.totalCents).toBe(4_650_000);
    expect(res.body.unclaimedCents).toBe(4_650_000);
    expect(res.body.guests).toEqual([
      { id: 'host', name: 'Alice', isHost: true, paid: false, itemIds: [], totalCents: 0 },
    ]);
    expect(res.body.payment).toEqual({ bankName: 'Хаан банк', accountNumber: '5000 1234 56', accountName: 'Билгүүн' });
  });

  it('remembers the bank details for the next bill (GET /me)', async () => {
    await createBill();
    const profile = await call(me.handler);
    expect(profile.body.payment).toEqual(payment);
    expect(profile.body.payQrUrl).toBeNull();
  });

  it('is idempotent: a retried create returns the same bill', async () => {
    const key = randomUUID();
    const first = await createBill(dinner, key);
    const again = await createBill(dinner, key);
    expect(again.status).toBe(201);
    expect(again.headers['idempotent-replayed']).toBe('true');
    expect(again.body.id).toBe(first.body.id);
    expect((await call(bills.list)).body.items).toHaveLength(1);
  });

  it('validates lines', async () => {
    const noItems = await createBill({ title: 'x', items: [] });
    expect(noItems.status).toBe(400);
    const float = await createBill({ title: 'x', items: [{ name: 'a', priceCents: 10.5 }] });
    expect(float.status).toBe(400);
    const noKey = await call(bills.create, { method: 'POST', body: dinner });
    expect(noKey.body.error.code).toBe('IDEMPOTENCY_KEY_REQUIRED');
  });

  it("another user can't see or touch it", async () => {
    const bill = (await createBill()).body;
    for (const [handler, method, extra] of [
      [bills.get, 'GET', {}],
      [bills.update, 'PUT', { body: dinner }],
      [bills.setStatus, 'POST', { body: { status: 'CLOSED' } }],
      [bills.updateGuest, 'PUT', { params: { billId: bill.id, guestId: 'host' }, body: { paid: true } }],
    ] as const) {
      const res = await call(handler, { as: bob, method, params: { billId: bill.id }, ...extra });
      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe('BILL_NOT_FOUND');
    }
    expect((await call(bills.list, { as: bob })).body.items).toEqual([]);
  });
});

describe('guests (no account, just the link)', () => {
  it('the page is HTML with a nonce-locked CSP', async () => {
    const res = await call(billPage.page, { as: null, params: { token: 'x' } });
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toBe('text/html; charset=utf-8');
    const csp = String(res.headers['content-security-policy']);
    const nonce = /script-src 'nonce-([^']+)'/.exec(csp)![1]!;
    expect(res.body).toContain(`<script nonce="${nonce}">`);
    expect(csp).toContain("default-src 'none'");
    expect(res.body).not.toContain('innerHTML');
  });

  it('a bad or unknown token is 404', async () => {
    for (const token of ['short', 'A'.repeat(22)]) {
      const res = await call(billPage.data, { as: null, params: { token } });
      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe('BILL_NOT_FOUND');
    }
  });

  it('join, tick, see the shared line split, mark paid; secrets never leave the server', async () => {
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

    // The host ticks the salad from the app.
    const host = await call(bills.updateGuest, {
      method: 'PUT',
      params: { billId: bill.id, guestId: 'host' },
      body: { itemIds: [itemId(bill, 'Салат')] },
    });
    expect(host.body.unclaimedCents).toBe(0);
    expect(guestOf(host.body, 'host').totalCents).toBe(1_200_000);
    expect(host.body.owedCents).toBe(3_450_000); // the host doesn't owe themselves

    const paid = await tick(bill.token, bat, { paid: true });
    expect(guestOf(paid.body, bat.guestId).paid).toBe(true);
    expect(paid.body.paidCents).toBe(1_950_000);

    const everything = JSON.stringify([joined.body, after.body, host.body, paid.body]);
    expect(everything).not.toContain(bat.secret);
    expect(everything).not.toContain('secretHash');
    expect(everything).not.toContain('hostUserId');
  });

  it('a retried join (dropped connection) does not add the guest twice', async () => {
    const bill = (await createBill()).body;
    const bat = newGuest('Бат');
    expect((await join(bill.token, bat)).status).toBe(201);
    const retry = await join(bill.token, bat);
    expect(retry.status).toBe(201);
    expect(retry.body.bill.guests).toHaveLength(2);

    const impostor = await join(bill.token, { ...bat, secret: randomBytes(32).toString('base64url') });
    expect(impostor.status).toBe(409);
    expect(impostor.body.error.code).toBe('GUEST_ID_TAKEN');
  });

  it("a guest can't edit someone else, even knowing their id", async () => {
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

  it('rejects ticks on lines that are not on the bill', async () => {
    const bill = (await createBill()).body;
    const bat = newGuest('Бат');
    await join(bill.token, bat);
    const res = await tick(bill.token, bat, { itemIds: ['nope'] });
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('UNKNOWN_ITEM');
  });

  it('changing ticks clears a "paid" mark, because the amount changed', async () => {
    const bill = (await createBill()).body;
    const bat = newGuest('Бат');
    await join(bill.token, bat);
    await tick(bill.token, bat, { itemIds: [itemId(bill, 'Кола')], paid: true });

    const same = await tick(bill.token, bat, { itemIds: [itemId(bill, 'Кола')] });
    expect(guestOf(same.body, bat.guestId).paid).toBe(true);

    const changed = await tick(bill.token, bat, { itemIds: [itemId(bill, 'Кола'), itemId(bill, 'Салат')] });
    expect(guestOf(changed.body, bat.guestId).paid).toBe(false);
  });

  it('a closed bill: no joining, no ticking, but paying still works', async () => {
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

  it('a bill holds at most 50 people, host included', async () => {
    const bill = (await createBill()).body;
    for (let i = 0; i < 49; i++) expect((await join(bill.token, newGuest(`G${i}`))).status).toBe(201);
    const full = await join(bill.token, newGuest('One too many'));
    expect(full.status).toBe(409);
    expect(full.body.error.code).toBe('BILL_FULL');
  });
});

describe('host manages the bill', () => {
  it('editing lines keeps ticks on lines that stay and drops ticks on removed ones', async () => {
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

  it('marks a cash payment, removes a guest, but never the host', async () => {
    const bill = (await createBill()).body;
    const bat = newGuest('Бат');
    await join(bill.token, bat);

    const cash = await call(bills.updateGuest, {
      method: 'PUT',
      params: { billId: bill.id, guestId: bat.guestId },
      body: { paid: true },
    });
    expect(guestOf(cash.body, bat.guestId).paid).toBe(true);

    const removed = await call(bills.removeGuest, { method: 'DELETE', params: { billId: bill.id, guestId: bat.guestId } });
    expect(removed.body.guests.map((g: { id: string }) => g.id)).toEqual(['host']);
    expect((await tick(bill.token, bat, { paid: true })).status).toBe(404);

    const host = await call(bills.removeGuest, { method: 'DELETE', params: { billId: bill.id, guestId: 'host' } });
    expect(host.body.error.code).toBe('CANNOT_REMOVE_HOST');
  });

  it('the list shows totals and how many have paid', async () => {
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

  it('the bank QR screenshot: upload URL under users/{sub}/, then guests get a view URL', async () => {
    const bill = (await createBill()).body;
    const upload = await call(bills.payQrUploadUrl, { method: 'POST', body: { contentType: 'image/png' } });
    expect(upload.status).toBe(200);
    expect(upload.body.key).toMatch(new RegExp(`^users/${alice.sub}/pay-qr/[0-9a-f-]{36}\\.png$`));

    const guest = await call(billPage.data, { as: null, params: { token: bill.token } });
    expect(guest.body.hasPayQr).toBe(true);
    expect(new URL(guest.body.payQrUrl).pathname).toBe(`/${upload.body.key}`);
    expect((await call(me.handler)).body.payQrUrl).toContain(upload.body.key);
  });
});
