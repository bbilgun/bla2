// Runs the real guest page script in jsdom against the real API. Every fetch the page makes becomes an
// API Gateway event for the real router (src/handlers/api.ts) and its MongoDB, and the tests click through
// like a guest would. The host's side goes through the real host handlers.
import { randomUUID } from 'node:crypto';
import { JSDOM } from 'jsdom';
import { ObjectId } from 'mongodb';
import { afterEach, describe, expect, it } from 'vitest';
import { handler as api } from '../../src/handlers/api';
import * as bills from '../../src/handlers/bills';
import { getDb } from '../../src/repositories/db';
import { call, useFakeAwsEnv, useTestDb, type TestUser } from '../integration/helpers';

useTestDb();
useFakeAwsEnv();

const host: TestUser = { sub: 'sub-host', email: 'host@example.com', name: 'Билгүүн' };
const payment = { bankName: 'Хаан банк', accountNumber: '5000 1234 56', accountName: 'Билгүүн' };

interface Bill {
  id: string;
  token: string;
  code: string;
  items: { id: string; name: string }[];
}

async function createBill(
  opts: { itemName?: string; currency?: string } = {},
): Promise<Bill & { i1: string; i2: string }> {
  const res = await call(bills.create, {
    as: host,
    method: 'POST',
    path: '/bills',
    headers: { 'Idempotency-Key': randomUUID() },
    body: {
      title: 'Оройн хоол',
      ...(opts.currency && { currency: opts.currency }),
      items: [
        { name: opts.itemName ?? 'Хуушуур', priceCents: 3_000_000 },
        { name: 'Кола', priceCents: 450_000 },
      ],
      payment,
    },
  });
  expect(res.status).toBe(201);
  const bill = res.body as Bill;
  const [i1, i2] = bill.items.map((item) => item.id) as [string, string];
  // The host had the first line.
  await hostCall(bills.updateGuest, 'PUT', { billId: bill.id, guestId: 'host' }, { itemIds: [i1] });
  return { ...bill, i1, i2 };
}

function hostCall(handler: Parameters<typeof call>[0], method: string, params: Record<string, string>, body?: unknown) {
  return call(handler, { as: host, method, params, body });
}

interface Sent {
  method: string;
  path: string;
  body: unknown;
  secret: string | undefined;
}

// The page's `fetch`. It turns a relative URL into a route template and params and calls the real router.
function realApi(token: string) {
  const requests: Sent[] = [];
  const pending = new Set<Promise<unknown>>();
  const fetch = (url: string, init: { method: string; body?: string; headers: Record<string, string> }) => {
    const path = new URL(url, 'https://api.example').pathname;
    const body = init.body ? JSON.parse(init.body) : undefined;
    requests.push({ method: init.method, path: path.replace(`/b/${token}`, ''), body, secret: init.headers['x-guest-secret'] });
    const match = /^\/b\/([^/]+)(\/data|\/guests)(?:\/([^/]+))?$/.exec(path);
    const run = async () => {
      if (!match) return { status: 404, body: { error: { code: 'ROUTE_NOT_FOUND' } } };
      const [, tok, rest, guestId] = match;
      const template = `/b/{token}${rest}${guestId ? '/{guestId}' : ''}`;
      const params: Record<string, string> = { token: tok! };
      if (guestId) params.guestId = decodeURIComponent(guestId);
      return call(api as never, { as: null, method: init.method, path: template, params, body, headers: init.headers });
    };
    const promise = run().then((res) => ({ ok: res.status < 400, status: res.status, json: async () => res.body }));
    pending.add(promise);
    void promise.finally(() => pending.delete(promise));
    return promise;
  };
  return { fetch, requests, pending };
}

type Api = ReturnType<typeof realApi>;
let dom: JSDOM | undefined;
let current: Api | undefined;
// Closing the window stops the page's polling timer.
afterEach(() => dom?.window.close());

// Lets the page's requests reach Mongo and come back, and its callbacks render.
async function settle() {
  for (let i = 0; i < 200; i++) {
    await new Promise((r) => setTimeout(r, 0));
    if (current!.pending.size === 0) {
      await new Promise((r) => setTimeout(r, 0));
      if (current!.pending.size === 0) return;
    }
    await Promise.allSettled([...current!.pending]);
  }
}

async function open(token: string, storage?: Record<string, string>) {
  dom?.window.close();
  current = realApi(token);
  const served = await call(api as never, { as: null, method: 'GET', path: '/b/{token}', params: { token } });
  expect(served.status).toBe(200);
  expect(served.headers['content-type']).toBe('text/html; charset=utf-8');
  const fetch = current.fetch;
  dom = new JSDOM(served.body as string, {
    url: `https://api.example/b/${token}`,
    runScripts: 'dangerously',
    beforeParse(window) {
      for (const [k, v] of Object.entries(storage ?? {})) window.localStorage.setItem(k, v);
      (window as unknown as { fetch: unknown }).fetch = fetch;
    },
  });
  await settle();
  return dom.window.document;
}

const buttons = (doc: Document, text: string) =>
  [...doc.querySelectorAll('button')].filter((b) => b.textContent === text) as HTMLButtonElement[];
const boxes = (doc: Document) => [...doc.querySelectorAll<HTMLInputElement>('.item input[type=checkbox]')];
const storeKey = (token: string) => `netzero.guest.${token}`;

async function joinAs(doc: Document, name: string) {
  (doc.querySelector('#name') as HTMLInputElement).value = name;
  buttons(doc, 'Нэгдэх')[0]!.click();
  await settle();
}

async function guestOnServer(billId: string, name: string) {
  const bill = (await hostCall(bills.get, 'GET', { billId })).body;
  return bill.guests.find((g: { name: string }) => g.name === name);
}

describe('the guest page against the real API', () => {
  it('shows a new visitor the bill and a name box, with lines locked until they join', async () => {
    const bill = await createBill();

    const doc = await open(bill.token);

    const text = doc.body.textContent!;
    expect(text).toContain('Оройн хоол');
    expect(text).toContain('34,500₮');
    expect(text).toContain('30,000₮');
    // Nobody has ticked the cola.
    expect(text).toContain('Хэн ч сонгоогүй');
    expect(doc.querySelector('#name')).not.toBeNull();
    expect(boxes(doc).every((b) => b.disabled)).toBe(true);
    expect(doc.querySelector('#pay')).toBeNull();
  });

  it('shows KRW amounts as whole won', async () => {
    // 3,000,000 won and 450,000 won, stored as-is because KRW has no minor unit.
    const bill = await createBill({ currency: 'KRW' });

    const doc = await open(bill.token);

    const text = doc.body.textContent!;
    expect(text).toContain('₩3,450,000');
    expect(text).toContain('₩3,000,000');
    expect(text).not.toContain('₩34,500');
    expect(text).not.toMatch(/₩[\d,]+\.\d/);
  });

  it('joins, ticks a shared line and marks paid with the amount shown', async () => {
    const bill = await createBill();
    const doc = await open(bill.token);
    await joinAs(doc, 'Бат');

    const join = current!.requests.find((r) => r.method === 'POST')!;
    const sent = join.body as { name: string; guestId: string; secret: string };
    expect(sent.name).toBe('Бат');
    expect(sent.guestId).toMatch(/^[A-Za-z0-9_-]{16,64}$/);
    expect(sent.secret).toMatch(/^[A-Za-z0-9_-]{32,128}$/);
    expect(JSON.parse(dom!.window.localStorage.getItem(storeKey(bill.token))!).guestId).toBe(sent.guestId);
    expect(boxes(doc).every((b) => !b.disabled)).toBe(true);

    // The khuushuur, which the host also had.
    boxes(doc)[0]!.click();
    await settle();
    const put = current!.requests.find((r) => r.method === 'PUT')!;
    expect(put.path).toBe(`/guests/${sent.guestId}`);
    expect(put.body).toEqual({ itemIds: [bill.i1] });
    expect(put.secret).toBe(sent.secret);

    const pay = doc.querySelector('#pay')!.textContent!;
    // Half of 30,000.
    expect(pay).toContain('15,000₮');
    expect(pay).toContain('Хаан банк');
    expect(pay).toContain('5000 1234 56');
    // The transfer note.
    expect(pay).toContain(`${bill.code} Бат`);
    expect(doc.body.textContent).toContain('Таны хэсэг: 15,000₮');

    buttons(doc, 'Би төлсөн')[0]!.click();
    await settle();
    expect(current!.requests.at(-1)!.body).toEqual({ paid: true, paidCents: 1_500_000 });
    expect(await guestOnServer(bill.id, 'Бат')).toMatchObject({ paid: true, paidCents: 1_500_000, dueCents: 0 });
    expect(doc.querySelector('#pay')!.textContent).toContain('Төлсөн гэж тэмдэглэсэн');
  });

  it('shows what is still due or overpaid when ticks change after paying', async () => {
    const bill = await createBill();
    const doc = await open(bill.token);
    await joinAs(doc, 'Сараа');
    // The cola, 4,500₮.
    boxes(doc)[1]!.click();
    await settle();
    buttons(doc, 'Би төлсөн')[0]!.click();
    await settle();

    // Plus half the khuushuur, 15,000₮ more.
    boxes(doc)[0]!.click();
    await settle();
    const due = doc.querySelector('#pay')!;
    expect(due.querySelector('h2')!.textContent).toBe('Үлдэгдэл төлөх');
    expect(due.querySelector('.big')!.textContent).toBe('15,000₮');
    expect(doc.querySelector('#due')!.textContent).toContain('4,500₮ төлсөн');
    expect(doc.querySelector('#bar')!.textContent).toContain('Үлдэгдэл');
    // The badge in the people list.
    expect(doc.body.textContent).toContain('Дутуу');

    // Paying the rest sends the new total the guest sees now.
    buttons(doc, 'Би төлсөн')[0]!.click();
    await settle();
    expect(current!.requests.at(-1)!.body).toEqual({ paid: true, paidCents: 1_950_000 });
    expect(await guestOnServer(bill.id, 'Сараа')).toMatchObject({ paid: true, dueCents: 0 });

    // Unticking the khuushuur means 15,000₮ too much.
    boxes(doc)[0]!.click();
    await settle();
    expect(doc.querySelector('#over')!.textContent).toBe('Та 15,000₮ илүү төлсөн байна. Билгүүн-тэй тохиролцоно уу.');
    expect(await guestOnServer(bill.id, 'Сараа')).toMatchObject({ paid: true, dueCents: -1_500_000 });
  });

  it('remembers the guest on reload', async () => {
    const bill = await createBill();
    let doc = await open(bill.token);
    await joinAs(doc, 'Сараа');
    const saved = dom!.window.localStorage.getItem(storeKey(bill.token))!;
    expect(JSON.parse(saved).joined).toBe(true);

    doc = await open(bill.token, { [storeKey(bill.token)]: saved });
    expect(doc.querySelector('#name')).toBeNull();
    expect(boxes(doc).every((b) => !b.disabled)).toBe(true);
    expect(current!.requests.filter((r) => r.method === 'POST')).toHaveLength(0);
  });

  it('recovers when the guest ticks a line the host has deleted', async () => {
    const bill = await createBill();
    const doc = await open(bill.token);
    await joinAs(doc, 'Бат');
    // The host deletes the cola, which this page still shows.
    await hostCall(bills.update, 'PUT', { billId: bill.id }, {
      title: 'Оройн хоол',
      items: [{ id: bill.i1, name: 'Хуушуур', priceCents: 3_000_000 }],
      payment,
    });
    boxes(doc)[1]!.click();
    await settle();
    expect(doc.querySelector('.error')).toBeNull();
    // The page now shows the bill as it is.
    expect(boxes(doc)).toHaveLength(1);
    boxes(doc)[0]!.click();
    await settle();
    expect((await guestOnServer(bill.id, 'Бат')).itemIds).toEqual([bill.i1]);
  });

  it('shows typed names and lines as text, never as markup', async () => {
    const bill = await createBill({ itemName: '<img src=x onerror=alert(1)>' });

    const doc = await open(bill.token);

    expect(doc.querySelector('img')).toBeNull();
    expect(doc.body.textContent).toContain('<img src=x onerror=alert(1)>');
  });

  it('shows a banner and no name box on a closed bill', async () => {
    const bill = await createBill();
    await hostCall(bills.setStatus, 'POST', { billId: bill.id }, { status: 'CLOSED' });

    const doc = await open(bill.token);

    expect(doc.body.textContent).toContain('Тооцоо хаагдсан');
    expect(doc.querySelector('#name')).toBeNull();
  });

  it('explains in Mongolian when the bill closed before the guest joined', async () => {
    const bill = await createBill();
    const doc = await open(bill.token);
    await hostCall(bills.setStatus, 'POST', { billId: bill.id }, { status: 'CLOSED' });

    await joinAs(doc, 'Бат');

    expect(doc.querySelector('.error')!.textContent).toBe('Тооцоо хаагдсан тул сонголтоо өөрчлөх боломжгүй.');
  });

  it('explains in Mongolian when the name is taken', async () => {
    const bill = await createBill();
    const doc = await open(bill.token);

    // The host's name, in another case.
    await joinAs(doc, ' билгүүн ');
    expect(doc.querySelector('.error')!.textContent).toContain('Энэ нэртэй хүн аль хэдийн нэгдсэн байна');
    expect(doc.querySelector('#name')).not.toBeNull();
    await joinAs(doc, 'Билгүүн Б.');
    expect(doc.querySelector('.error')).toBeNull();
    expect(doc.querySelector('#name')).toBeNull();
  });

  it('tells a removed guest on the next load and when they retry the old id', async () => {
    const bill = await createBill();
    let doc = await open(bill.token);
    await joinAs(doc, 'Бат');
    const saved = JSON.parse(dom!.window.localStorage.getItem(storeKey(bill.token))!);
    await hostCall(bills.removeGuest, 'DELETE', { billId: bill.id, guestId: saved.guestId });

    doc = await open(bill.token, { [storeKey(bill.token)]: JSON.stringify(saved) });
    expect(doc.querySelector('.error')!.textContent).toBe('Төлөгч таныг энэ тооцооноос хассан байна.');
    expect(doc.querySelector('#name')).not.toBeNull();

    // A browser that never saw its join confirmed retries with the same id, and the server refuses it.
    const unconfirmed = { guestId: saved.guestId, secret: saved.secret, name: 'Бат' };
    doc = await open(bill.token, { [storeKey(bill.token)]: JSON.stringify(unconfirmed) });
    expect((doc.querySelector('#name') as HTMLInputElement).value).toBe('Бат');
    buttons(doc, 'Нэгдэх')[0]!.click();
    await settle();
    expect(current!.requests.at(-1)!.body).toMatchObject({ guestId: saved.guestId });
    expect(doc.querySelector('.error')!.textContent).toBe('Төлөгч таныг энэ тооцооноос хассан байна.');
  });

  it('explains an expired link in Mongolian', async () => {
    const bill = await createBill();
    await (await getDb())
      .collection('bills')
      .updateOne({ _id: new ObjectId(bill.id) }, { $set: { createdAt: new Date(Date.now() - 91 * 86_400_000) } });

    const doc = await open(bill.token);

    expect(doc.body.textContent).toContain('Энэ тооцооны холбоосын хугацаа дууссан байна.');
    expect(doc.querySelector('#name')).toBeNull();
  });

  it('explains in Mongolian a link the host has replaced', async () => {
    const bill = await createBill();
    await hostCall(bills.rotateToken, 'POST', { billId: bill.id });

    const doc = await open(bill.token);

    expect(doc.body.textContent).toContain('Тооцоо олдсонгүй');
    expect(current!.requests).toHaveLength(1);
  });
});
