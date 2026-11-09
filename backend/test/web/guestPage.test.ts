import { JSDOM } from 'jsdom';
import { afterEach, describe, expect, it } from 'vitest';
import { computeBill } from '../../src/domain/bill';
import { guestPageHtml } from '../../src/web/guestPage';

/**
 * Runs the real guest page script in a DOM, against a fake API that keeps state and computes totals
 * with the real domain function, then clicks through it like a guest would.
 */

interface Guest {
  id: string;
  name: string;
  isHost: boolean;
  paid: boolean;
  itemIds: string[];
}

const TOKEN = 'AbCdEfGhIjKlMnOpQrStUv';

function fakeServer(opts: { status?: 'OPEN' | 'CLOSED'; itemName?: string } = {}) {
  const items = [
    { id: 'i1', name: opts.itemName ?? 'Хуушуур', priceCents: 3_000_000 },
    { id: 'i2', name: 'Кола', priceCents: 450_000 },
  ];
  const guests: Guest[] = [{ id: 'host', name: 'Билгүүн', isHost: true, paid: false, itemIds: ['i1'] }];
  const view = () => {
    const b = computeBill(items, guests);
    return {
      id: 'b1',
      code: '7KQ2HM',
      title: 'Оройн хоол',
      currency: 'MNT',
      status: opts.status ?? 'OPEN',
      hostName: 'Билгүүн',
      items: items.map((i) => ({
        ...i,
        claimedBy: b.claimers.get(i.id),
        shares: Object.fromEntries(b.shares.get(i.id)!),
      })),
      guests: guests.map((g) => ({ ...g, totalCents: b.guestTotals.get(g.id) })),
      totalCents: b.totalCents,
      unclaimedCents: b.unclaimedCents,
      payment: { bankName: 'Хаан банк', accountNumber: '5000 1234 56', accountName: 'Билгүүн' },
      payQrUrl: null,
    };
  };
  const requests: { method: string; path: string; body: unknown; secret: string | undefined }[] = [];

  const fetch = async (url: string, init: { method: string; body?: string; headers: Record<string, string> }) => {
    // The page calls its own relative paths ('/b/{token}/data'), like a browser would resolve them.
    const path = new URL(url, 'https://api.example').pathname.replace(`/b/${TOKEN}`, '');
    const body = init.body ? JSON.parse(init.body) : undefined;
    requests.push({ method: init.method, path, body, secret: init.headers['x-guest-secret'] });
    const reply = (status: number, data: unknown) => ({ ok: status < 400, status, json: async () => data });

    if (init.method === 'GET' && path === '/data') return reply(200, view());
    if (init.method === 'POST' && path === '/guests') {
      guests.push({ id: body.guestId, name: body.name, isHost: false, paid: false, itemIds: [] });
      return reply(201, { guestId: body.guestId, bill: view() });
    }
    const match = /^\/guests\/(.+)$/.exec(path);
    if (init.method === 'PUT' && match) {
      const g = guests.find((x) => x.id === decodeURIComponent(match[1]!))!;
      if (body.itemIds) g.itemIds = body.itemIds;
      if (body.paid !== undefined) g.paid = body.paid;
      return reply(200, view());
    }
    return reply(404, { error: { code: 'BILL_NOT_FOUND' } });
  };
  return { fetch, requests, guests };
}

let dom: JSDOM | undefined;
afterEach(() => dom?.window.close()); // stops the page's polling timer

const settle = async () => {
  for (let i = 0; i < 5; i++) await new Promise((r) => setTimeout(r, 0));
};

async function open(server: ReturnType<typeof fakeServer>) {
  dom = new JSDOM(guestPageHtml('test-nonce'), {
    url: `https://api.example/b/${TOKEN}`,
    runScripts: 'dangerously',
    beforeParse(window) {
      (window as unknown as { fetch: unknown }).fetch = server.fetch;
    },
  });
  await settle();
  return dom.window.document;
}

const buttons = (doc: Document, text: string) =>
  [...doc.querySelectorAll('button')].filter((b) => b.textContent === text) as HTMLButtonElement[];
const boxes = (doc: Document) => [...doc.querySelectorAll<HTMLInputElement>('.item input[type=checkbox]')];

describe('guest page', () => {
  it('a new visitor sees the bill, who shares what, and a name box; items are locked until they join', async () => {
    const doc = await open(fakeServer());
    const text = doc.body.textContent!;
    expect(text).toContain('Оройн хоол');
    expect(text).toContain('34,500₮');
    expect(text).toContain('30,000₮');
    expect(text).toContain('Хэн ч сонгоогүй'); // the cola
    expect(doc.querySelector('#name')).not.toBeNull();
    expect(boxes(doc).every((b) => b.disabled)).toBe(true);
    expect(doc.querySelector('#pay')).toBeNull();
  });

  it('join, tick a shared line, see my share and how to pay, mark paid', async () => {
    const server = fakeServer();
    const doc = await open(server);

    (doc.querySelector('#name') as HTMLInputElement).value = 'Бат';
    buttons(doc, 'Нэгдэх')[0]!.click();
    await settle();

    const join = server.requests.find((r) => r.method === 'POST')!;
    const sent = join.body as { name: string; guestId: string; secret: string };
    expect(sent.name).toBe('Бат');
    expect(sent.guestId).toMatch(/^[A-Za-z0-9_-]{16,64}$/);
    expect(sent.secret).toMatch(/^[A-Za-z0-9_-]{32,128}$/);
    expect(JSON.parse(dom!.window.localStorage.getItem(`netzero.guest.${TOKEN}`)!).guestId).toBe(sent.guestId);
    expect(boxes(doc).every((b) => !b.disabled)).toBe(true);

    boxes(doc)[0]!.click(); // khuushuur, which the host also had
    await settle();
    const put = server.requests.find((r) => r.method === 'PUT')!;
    expect(put.path).toBe(`/guests/${sent.guestId}`);
    expect(put.body).toEqual({ itemIds: ['i1'] });
    expect(put.secret).toBe(sent.secret);

    const pay = doc.querySelector('#pay')!.textContent!;
    expect(pay).toContain('15,000₮'); // half of 30,000
    expect(pay).toContain('Хаан банк');
    expect(pay).toContain('5000 1234 56');
    expect(pay).toContain('7KQ2HM Бат'); // transfer note
    expect(doc.body.textContent).toContain('Таны хэсэг: 15,000₮');

    buttons(doc, 'Би төлсөн')[0]!.click();
    await settle();
    expect(server.guests.find((g) => g.name === 'Бат')!.paid).toBe(true);
    expect(doc.querySelector('#pay')!.textContent).toContain('Төлсөн гэж тэмдэглэсэн');
  });

  it('remembers the guest on reload', async () => {
    const server = fakeServer();
    let doc = await open(server);
    (doc.querySelector('#name') as HTMLInputElement).value = 'Сараа';
    buttons(doc, 'Нэгдэх')[0]!.click();
    await settle();
    const saved = dom!.window.localStorage.getItem(`netzero.guest.${TOKEN}`)!;
    dom!.window.close();

    dom = new JSDOM(guestPageHtml('n'), {
      url: `https://api.example/b/${TOKEN}`,
      runScripts: 'dangerously',
      beforeParse(window) {
        window.localStorage.setItem(`netzero.guest.${TOKEN}`, saved);
        (window as unknown as { fetch: unknown }).fetch = server.fetch;
      },
    });
    await settle();
    doc = dom.window.document;
    expect(doc.querySelector('#name')).toBeNull();
    expect(boxes(doc).every((b) => !b.disabled)).toBe(true);
    expect(server.requests.filter((r) => r.method === 'POST')).toHaveLength(1);
  });

  it('names and items typed by people are shown as text, never as HTML', async () => {
    const doc = await open(fakeServer({ itemName: '<img src=x onerror=alert(1)>' }));
    expect(doc.querySelector('img')).toBeNull();
    expect(doc.body.textContent).toContain('<img src=x onerror=alert(1)>');
  });

  it('a closed bill: a banner, and no way to join', async () => {
    const doc = await open(fakeServer({ status: 'CLOSED' }));
    expect(doc.body.textContent).toContain('Тооцоо хаагдсан');
    expect(doc.querySelector('#name')).toBeNull();
  });

  it('an unknown link says so in Mongolian', async () => {
    const server = fakeServer();
    const notFound = async () => ({ ok: false, status: 404, json: async () => ({ error: { code: 'BILL_NOT_FOUND' } }) });
    dom = new JSDOM(guestPageHtml('n'), {
      url: `https://api.example/b/${TOKEN}`,
      runScripts: 'dangerously',
      beforeParse(window) {
        (window as unknown as { fetch: unknown }).fetch = notFound;
      },
    });
    await settle();
    expect(dom.window.document.body.textContent).toContain('Тооцоо олдсонгүй');
    expect(server.requests).toHaveLength(0);
  });
});
