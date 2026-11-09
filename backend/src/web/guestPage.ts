// The page a guest sees after scanning a bill's QR code: one self-contained HTML document with no build
// step and no requests except to its own API and the host's QR image. Every name and line on it was typed
// by someone, so the script only ever sets textContent, never innerHTML.

/**
 * The guest page's HTML. `nonce` must match the one in the CSP header the handler sends. The script
 * inside uses no template literals and doubles its regex backslashes, because this whole page is itself
 * a TypeScript template literal.
 */
export function guestPageHtml(nonce: string): string {
  return `<!doctype html>
<html lang="mn">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="referrer" content="no-referrer">
<meta name="robots" content="noindex">
<meta name="theme-color" content="#1F7A5C">
<title>NetZero · Тооцоо хуваах</title>
<style nonce="${nonce}">
:root {
  --bg: #F4F6F5; --card: #FFFFFF; --text: #0E1512; --muted: #5B6B62; --line: #E2E8E5; --field: #EBEFED;
  --brand: #00885A; --on-brand: #FFFFFF; --brand-soft: #DDF5EA; --on-brand-soft: #00573A;
  --warn: #8A5300; --warn-soft: #FFF0D6; --red: #E5383B; --red-soft: #FDE7E7; --on-red-soft: #8C1D1F;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0B0F0D; --card: #141A17; --text: #E8EEEB; --muted: #9DB0A6; --line: #243029; --field: #1D2622;
    --brand: #3DDC97; --on-brand: #0E1512; --brand-soft: #123526; --on-brand-soft: #3DDC97;
    --warn: #F7C46C; --warn-soft: #33270F; --red: #FF8A8C; --red-soft: #3B1516; --on-red-soft: #FFB3B4;
  }
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body {
  margin: 0; background: var(--bg); color: var(--text);
  font: 16px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, "Noto Sans", sans-serif;
}
.brand { max-width: 520px; margin: 0 auto; padding: 14px 16px 0; display: flex; align-items: center; gap: 10px; }
.brand span { font-weight: 800; font-size: 20px; letter-spacing: -0.02em; }
.mark { width: 30px; height: 30px; display: block; }
.mark-bg { fill: var(--brand); }
.mark-fg { fill: var(--on-brand); }
main { max-width: 520px; margin: 0 auto; padding: 4px 16px 120px; }
h1 { font-size: 30px; font-weight: 800; letter-spacing: -0.03em; margin: 14px 0 2px; line-height: 1.15; }
h2 { font-size: 19px; font-weight: 800; letter-spacing: -0.01em; margin: 0 0 4px; }
.muted { color: var(--muted); }
.small { font-size: 14px; }
.center { text-align: center; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 24px; padding: 18px; margin-top: 14px; }
.hero { background: var(--brand); color: var(--on-brand); border: 0; border-radius: 28px; padding: 20px; }
.hero .muted, .hero .kv .k { color: color-mix(in srgb, var(--on-brand) 78%, transparent); }
.hero .kv { border-color: color-mix(in srgb, var(--on-brand) 20%, transparent); }
.hero button { background: var(--on-brand); color: var(--brand); }
.hero button.link { background: color-mix(in srgb, var(--on-brand) 16%, transparent); color: var(--on-brand); }
.hero button.ghost { background: color-mix(in srgb, var(--on-brand) 16%, transparent); color: var(--on-brand); }
.hero .mine { color: var(--on-brand); }
.banner { background: var(--warn-soft); color: var(--warn); border-radius: 16px; padding: 12px 14px; margin-top: 12px; font-size: 14px; font-weight: 600; }
.error { background: var(--red-soft); color: var(--on-red-soft); border-radius: 16px; padding: 12px 14px; margin-top: 12px; font-size: 14px; font-weight: 600; }
input[type=text] {
  width: 100%; font: inherit; padding: 14px 16px; border-radius: 16px; border: 2px solid transparent;
  background: var(--field); color: var(--text); margin: 10px 0 12px; outline: none;
}
input[type=text]:focus { border-color: var(--brand); }
button {
  font: inherit; font-weight: 700; border: 0; border-radius: 18px; padding: 15px 16px; cursor: pointer;
  background: var(--brand); color: var(--on-brand); width: 100%;
}
button.ghost { background: var(--brand-soft); color: var(--on-brand-soft); }
button.link { background: var(--brand-soft); color: var(--on-brand-soft); padding: 6px 12px; width: auto; font-size: 14px; border-radius: 999px; }
button:disabled { opacity: .5; cursor: default; }
.item { display: flex; gap: 12px; align-items: flex-start; padding: 14px 0; border-top: 1px solid var(--line); cursor: pointer; }
.item:first-of-type { border-top: 0; }
.item input { width: 24px; height: 24px; margin: 1px 0 0; accent-color: var(--brand); flex: none; }
.item .body { flex: 1; min-width: 0; }
.item .row { display: flex; justify-content: space-between; gap: 8px; }
.item .name { font-weight: 700; overflow-wrap: anywhere; }
.item.locked { cursor: default; }
.price, .num { font-variant-numeric: tabular-nums; white-space: nowrap; font-weight: 700; }
.mine { color: var(--brand); font-weight: 700; }
.big { font-size: 40px; font-weight: 800; letter-spacing: -0.03em; margin: 2px 0 10px; font-variant-numeric: tabular-nums; line-height: 1.1; }
.kv { display: flex; justify-content: space-between; align-items: center; gap: 8px; padding: 11px 0; border-top: 1px solid var(--line); }
.kv .k { color: var(--muted); font-size: 13px; }
.kv .v { font-weight: 700; overflow-wrap: anywhere; }
.qr { display: block; width: 100%; max-width: 280px; margin: 16px auto 6px; border-radius: 16px; background: #fff; }
.person { display: flex; justify-content: space-between; align-items: center; gap: 8px; padding: 10px 0; border-top: 1px solid var(--line); }
.person:first-of-type { border-top: 0; }
.badge { font-size: 12px; font-weight: 800; padding: 3px 9px; border-radius: 999px; background: var(--brand-soft); color: var(--on-brand-soft); margin-left: 8px; }
#bar {
  position: fixed; left: 0; right: 0; bottom: 0; background: var(--card); border-top: 1px solid var(--line);
  padding: 12px 16px calc(12px + env(safe-area-inset-bottom));
}
#bar .in { max-width: 520px; margin: 0 auto; display: flex; gap: 12px; align-items: center; }
#bar .total { flex: 1; }
#bar .total strong { font-size: 22px; font-weight: 800; letter-spacing: -0.02em; }
#bar button { width: auto; padding: 13px 26px; }
#toast {
  position: fixed; left: 50%; bottom: 100px; transform: translateX(-50%); background: var(--text); color: var(--bg);
  padding: 9px 16px; border-radius: 999px; font-size: 14px; font-weight: 600;
}
[hidden] { display: none !important; }
</style>
</head>
<body>
<header class="brand"><svg class="mark" viewBox="0 0 48 48" aria-hidden="true"><defs><clipPath id="nzA"><rect x="-48" y="-48" width="96" height="46.68"/></clipPath><clipPath id="nzB"><rect x="-48" y="1.32" width="96" height="46.68"/></clipPath><path id="nzR" fill-rule="evenodd" d="M-12.00 0A12.00 14.88 0 1 0 12.00 0A12.00 14.88 0 1 0 -12.00 0ZM-5.76 0A5.76 8.64 0 1 0 5.76 0A5.76 8.64 0 1 0 -5.76 0Z"/></defs><rect width="48" height="48" rx="14.4" class="mark-bg"/><g class="mark-fg" transform="translate(24 24) rotate(-45)"><g transform="translate(-1.68 0)" clip-path="url(#nzA)"><use href="#nzR" transform="rotate(45)"/></g><g transform="translate(1.68 0)" clip-path="url(#nzB)"><use href="#nzR" transform="rotate(45)"/></g></g></svg><span>NetZero</span></header>
<main id="app"><p class="muted center">Ачааллаж байна…</p></main>
<div id="bar" hidden></div>
<div id="toast" hidden></div>
<script nonce="${nonce}">
(function () {
  'use strict';
  var base = location.pathname.replace(/\\/+$/, '');
  var token = base.split('/').pop();
  var STORE = 'netzero.guest.' + token;
  var app = document.getElementById('app');
  var bar = document.getElementById('bar');
  var toastEl = document.getElementById('toast');

  var bill = null;       // latest server state
  var me = null;         // { guestId, secret, name, joined } kept in this browser only
  var desired = null;    // ticks waiting to be sent
  var sending = false;
  var errorText = null;
  var qrImg = null;      // kept across renders so the image doesn't reload on every poll
  var stopped = false;   // the link is dead, so stop polling
  var toastTimer = null;

  var ERRORS = {
    BILL_NOT_FOUND: 'Тооцоо олдсонгүй. Холбоосоо шалгана уу.',
    BILL_EXPIRED: 'Энэ тооцооны холбоосын хугацаа дууссан байна.',
    BILL_CLOSED: 'Тооцоо хаагдсан тул сонголтоо өөрчлөх боломжгүй.',
    BILL_FULL: 'Энэ тооцоонд хэт олон хүн нэгдсэн байна.',
    NAME_TAKEN: 'Энэ нэртэй хүн аль хэдийн нэгдсэн байна. Өөр нэр оруулна уу (жишээ нь: Бат Д.).',
    GUEST_REMOVED: 'Төлөгч таныг энэ тооцооноос хассан байна.',
    GUEST_NOT_FOUND: 'Таныг энэ тооцооноос хассан байна. Дахин нэгдэнэ үү.',
    VALIDATION_ERROR: 'Оруулсан мэдээллээ шалгана уу.',
    NETWORK: 'Интернэт холболт алга. Дахин оролдоно уу.'
  };
  // These mean the link itself is dead, so nothing else on the page can help.
  var FATAL = { BILL_NOT_FOUND: true, BILL_EXPIRED: true };
  function errorMessage(code) { return ERRORS[code] || 'Алдаа гарлаа. Дахин оролдоно уу.'; }

  // Money: integer minor units in, text out, with the same rules as the app and no float math.
  var SYMBOLS = { USD: '$', EUR: '€', GBP: '£', MNT: '₮', KRW: '₩', CNY: '¥', JPY: '¥' };
  // KRW and JPY have no minor unit, so their amounts are whole won and yen. Same table as the app.
  var ZERO_DECIMAL = { KRW: true, JPY: true };
  function splitAmount(amount, currency) {
    var abs = Math.abs(amount);
    var sign = amount < 0 ? '-' : '';
    if (ZERO_DECIMAL[currency]) return { sign: sign, whole: String(abs), frac: '' };
    var frac = abs % 100;
    return { sign: sign, whole: String((abs - frac) / 100), frac: (frac < 10 ? '0' : '') + frac };
  }
  function money(amount, currency) {
    var parts = splitAmount(amount, currency);
    var grouped = parts.whole.replace(/\\B(?=(\\d{3})+(?!\\d))/g, ',');
    // Tugrik amounts are almost always whole: "42,500₮", not "42,500.00₮". Same rule as the app.
    if (currency === 'MNT') return parts.sign + grouped + (parts.frac === '00' ? '' : '.' + parts.frac) + '₮';
    var symbol = SYMBOLS[currency] || currency + ' ';
    return parts.sign + symbol + grouped + (parts.frac ? '.' + parts.frac : '');
  }
  /** For typing into a bank app: "12500" or "12500.50". */
  function plainAmount(amount, currency) {
    var parts = splitAmount(amount, currency);
    if (parts.frac === '00' || parts.frac === '') return parts.whole;
    return parts.whole + '.' + parts.frac;
  }

  // A tiny DOM helper. It only ever creates text nodes and sets textContent, never markup.
  function h(tag, props) {
    var el = document.createElement(tag);
    if (props) for (var key in props) {
      var value = props[key];
      if (key === 'text') el.textContent = value;
      else if (key === 'cls') el.className = value;
      else if (key.slice(0, 2) === 'on') el.addEventListener(key.slice(2), value);
      else if (value !== false && value != null) el.setAttribute(key, value === true ? '' : value);
    }
    var add = function (child) {
      if (child == null || child === false) return;
      if (Array.isArray(child)) { child.forEach(add); return; }
      el.appendChild(typeof child === 'string' ? document.createTextNode(child) : child);
    };
    for (var i = 2; i < arguments.length; i++) add(arguments[i]);
    return el;
  }

  function toast(text) {
    toastEl.textContent = text;
    toastEl.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.hidden = true; }, 1600);
  }

  function copy(text) {
    var done = function () { toast('Хууллаа'); };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function () { fallbackCopy(text); done(); });
    } else { fallbackCopy(text); done(); }
  }
  function fallbackCopy(text) {
    var ta = h('textarea', { readonly: true });
    ta.value = text;
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); } catch (e) {}
    ta.remove();
  }

  function randomId(bytes) {
    var a = new Uint8Array(bytes);
    crypto.getRandomValues(a);
    var s = '';
    for (var i = 0; i < a.length; i++) s += String.fromCharCode(a[i]);
    return btoa(s).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
  }

  function loadMe() { try { return JSON.parse(localStorage.getItem(STORE) || 'null'); } catch (e) { return null; } }
  function saveMe(v) { try { localStorage.setItem(STORE, JSON.stringify(v)); } catch (e) {} }
  function forgetMe() { try { localStorage.removeItem(STORE); } catch (e) {} }

  function api(method, path, body, headers) {
    var init = { method: method, cache: 'no-store', headers: { 'content-type': 'application/json' } };
    if (headers) for (var k in headers) init.headers[k] = headers[k];
    if (body !== undefined) init.body = JSON.stringify(body);
    return fetch(base + path, init).then(function (res) {
      return res.json().catch(function () { return {}; }).then(function (data) {
        if (!res.ok) {
          var err = new Error('api');
          err.code = (data && data.error && data.error.code) || 'HTTP_' + res.status;
          throw err;
        }
        return data;
      });
    }, function () {
      var err = new Error('network');
      err.code = 'NETWORK';
      throw err;
    });
  }

  function myGuest() {
    if (!me || !bill) return null;
    for (var i = 0; i < bill.guests.length; i++) if (bill.guests[i].id === me.guestId) return bill.guests[i];
    return null;
  }
  function guestName(id) {
    for (var i = 0; i < bill.guests.length; i++) if (bill.guests[i].id === id) return bill.guests[i].name;
    return '';
  }

  // Actions

  function refresh() {
    return api('GET', '/data').then(function (data) {
      bill = data;
      // We joined earlier but aren't on the bill, so the host removed us. A join that never went
      // through keeps its stored id, so retrying it can't add us twice.
      if (me && me.joined && !myGuest()) { forgetMe(); me = null; errorText = errorMessage('GUEST_REMOVED'); }
      render();
    }, function (e) {
      if (!bill || FATAL[e.code]) renderFatal(errorMessage(e.code));
    });
  }

  function join(name) {
    if (!me || me.name !== name) me = { guestId: randomId(12), secret: randomId(32), name: name };
    // Saved before sending, so a retry after a dropped connection reuses the same id.
    saveMe(me);
    errorText = null;
    render();
    return api('POST', '/guests', { name: name, guestId: me.guestId, secret: me.secret }).then(function (res) {
      me.joined = true;
      saveMe(me);
      bill = res.bill;
      render();
    }, function (e) {
      if (FATAL[e.code]) { renderFatal(errorMessage(e.code)); return; }
      if (e.code !== 'NETWORK') { forgetMe(); me = null; }
      errorText = errorMessage(e.code);
      render();
    });
  }

  function toggle(itemId) {
    var guest = myGuest();
    if (!guest || bill.status !== 'OPEN') return;
    var ticked = {};
    var current = desired || guest.itemIds;
    for (var i = 0; i < current.length; i++) ticked[current[i]] = true;
    if (ticked[itemId]) delete ticked[itemId]; else ticked[itemId] = true;
    desired = Object.keys(ticked);
    // Show the tick now. Totals update when the server answers.
    guest.itemIds = desired;
    render();
    pushTicks();
  }

  function pushTicks() {
    if (sending) return;
    sending = true;
    errorText = null;
    var next = function () {
      if (!desired) { sending = false; render(); return; }
      var ids = desired;
      desired = null;
      api('PUT', '/guests/' + encodeURIComponent(me.guestId), { itemIds: ids }, { 'x-guest-secret': me.secret })
        .then(function (data) { bill = data; next(); }, function (e) {
          sending = false;
          desired = null;
          errorText = errorMessage(e.code);
          refresh();
        });
    };
    next();
  }

  /** "I paid" sends the total on screen: that's what the guest transferred, even if ticks change later. */
  function setPaid(paid) {
    var guest = myGuest();
    if (!guest) return;
    var body = paid ? { paid: true, paidCents: guest.totalCents } : { paid: false };
    sending = true;
    api('PUT', '/guests/' + encodeURIComponent(me.guestId), body, { 'x-guest-secret': me.secret })
      .then(function (data) { bill = data; errorText = null; }, function (e) {
        if (FATAL[e.code]) { renderFatal(errorMessage(e.code)); return; }
        errorText = errorMessage(e.code);
      })
      .then(function () { sending = false; if (!stopped) render(); });
  }

  // Rendering

  function renderFatal(text) {
    stopped = true;
    bar.hidden = true;
    app.replaceChildren(h('div', { cls: 'card center' }, h('h2', { text: 'NetZero' }), h('p', { cls: 'muted', text: text })));
  }

  function render() {
    if (!bill) return;
    var guest = myGuest();
    var open = bill.status === 'OPEN';
    var nodes = [];

    nodes.push(h('h1', { text: bill.title }));
    nodes.push(h('p', { cls: 'muted' }, 'Төлсөн: ' + bill.hostName + ' · Нийт ', h('span', { cls: 'num', text: money(bill.totalCents, bill.currency) })));
    if (!open) nodes.push(h('div', { cls: 'banner', text: 'Тооцоо хаагдсан. Сонголтоо өөрчлөх боломжгүй, гэхдээ төлбөрөө тэмдэглэж болно.' }));
    if (errorText) nodes.push(h('div', { cls: 'error', text: errorText }));

    if (!guest && open) nodes.push(joinCard());
    nodes.push(itemsCard(guest, open));
    if (guest) nodes.push(payCard(guest));
    nodes.push(peopleCard());

    app.replaceChildren.apply(app, nodes);
    renderBar(guest);
  }

  function joinCard() {
    var input = h('input', { type: 'text', id: 'name', maxlength: '40', autocomplete: 'given-name', placeholder: 'Жишээ нь: Бат', enterkeyhint: 'go' });
    if (me && !myGuest()) input.value = me.name;
    var btn = h('button', { text: 'Нэгдэх' });
    var go = function () {
      var name = input.value.trim();
      if (!name) { input.focus(); return; }
      btn.disabled = true;
      join(name);
    };
    btn.addEventListener('click', go);
    input.addEventListener('keydown', function (e) { if (e.key === 'Enter') go(); });
    return h('div', { cls: 'card' },
      h('h2', { text: 'Таны нэр' }),
      h('p', { cls: 'muted small', text: 'Бүртгүүлэх шаардлагагүй. Бусад хүмүүс таныг энэ нэрээр харна.' }),
      input, btn);
  }

  function itemsCard(guest, open) {
    var mine = {};
    if (guest) for (var i = 0; i < guest.itemIds.length; i++) mine[guest.itemIds[i]] = true;
    var locked = !guest || !open;
    var rows = bill.items.map(function (item) {
      var checked = !!mine[item.id];
      var names = item.claimedBy.map(guestName).filter(Boolean);
      var share = guest && item.shares[guest.id];
      var box = h('input', { type: 'checkbox', checked: checked, disabled: locked, 'aria-label': item.name });
      var row = h('label', { cls: 'item' + (locked ? ' locked' : '') },
        box,
        h('div', { cls: 'body' },
          h('div', { cls: 'row' }, h('span', { cls: 'name', text: item.name }), h('span', { cls: 'price', text: money(item.priceCents, bill.currency) })),
          names.length ? h('div', { cls: 'muted small', text: names.join(', ') + (names.length > 1 ? ' хуваана' : '') }) : null,
          checked && share ? h('div', { cls: 'small mine', text: 'Таны хэсэг: ' + money(share, bill.currency) }) : null));
      box.addEventListener('change', function () { toggle(item.id); });
      return row;
    });
    return h('div', { cls: 'card' },
      h('h2', { text: 'Юу идэж, уусан бэ?' }),
      h('p', { cls: 'muted small', text: guest ? 'Өөрийнхөө зүйлсийг сонгоно уу. Хэд хэдэн хүн сонгосон зүйл тэдний дунд тэнцүү хуваагдана.' : 'Эхлээд нэрээ оруулаад нэгдэнэ үү.' }),
      rows);
  }

  /** Marked paid, then ticked more: only the difference is left to send. */
  function stillDue(guest) { return guest.paidCents > 0 && guest.dueCents > 0; }
  function amountToSend(guest) { return stillDue(guest) ? guest.dueCents : guest.totalCents; }

  function payCard(guest) {
    var title = stillDue(guest) ? 'Үлдэгдэл төлөх' : 'Таны төлөх дүн';
    var children = [h('h2', { text: title }), h('div', { cls: 'big', text: money(amountToSend(guest), bill.currency) })];
    if (guest.totalCents === 0 && guest.paidCents === 0) {
      children.push(h('p', { cls: 'muted small', text: 'Дээрээс идсэн, уусан зүйлээ сонгоход дүн гарна.' }));
      return h('div', { cls: 'card', id: 'pay' }, children);
    }
    var payment = bill.payment;
    var note = bill.code + ' ' + guest.name;
    var row = function (label, value, copyText) {
      return h('div', { cls: 'kv' },
        h('div', null, h('div', { cls: 'k', text: label }), h('div', { cls: 'v', text: value })),
        copyText ? h('button', { cls: 'link', text: 'Хуулах', onclick: function () { copy(copyText); } }) : null);
    };
    if (payment) {
      children.push(row('Банк', payment.bankName));
      children.push(row('Дансны дугаар', payment.accountNumber, payment.accountNumber.replace(/\\s+/g, '')));
      children.push(row('Данс эзэмшигч', payment.accountName));
    } else {
      children.push(h('p', { cls: 'muted small', text: bill.hostName + '-тэй төлбөрөө тохиролцоно уу.' }));
    }
    children.push(row('Дүн', money(amountToSend(guest), bill.currency), plainAmount(amountToSend(guest), bill.currency)));
    children.push(row('Гүйлгээний утга', note, note));
    if (bill.payQrUrl) {
      if (!qrImg) qrImg = h('img', { cls: 'qr', alt: 'Төлбөрийн QR', src: bill.payQrUrl, referrerpolicy: 'no-referrer' });
      children.push(qrImg);
      children.push(h('p', { cls: 'muted small center', text: 'QR зургийг удаан дарж хадгалаад, банкны аппаараа уншуулна уу.' }));
    }
    if (guest.paid) {
      children.push(h('p', { cls: 'center mine', text: 'Төлсөн гэж тэмдэглэсэн ✓' }));
      if (guest.dueCents < 0) {
        children.push(h('p', { cls: 'center small', id: 'over',
          text: 'Та ' + money(-guest.dueCents, bill.currency) + ' илүү төлсөн байна. ' + bill.hostName + '-тэй тохиролцоно уу.' }));
      }
      children.push(h('button', { cls: 'ghost', text: 'Буцаах', disabled: sending, onclick: function () { setPaid(false); } }));
    } else {
      if (stillDue(guest)) {
        children.push(h('p', { cls: 'center small', id: 'due',
          text: 'Та ' + money(guest.paidCents, bill.currency) + ' төлсөн. Сонголт өөрчлөгдсөн тул ' + money(guest.dueCents, bill.currency) + ' дутуу байна.' }));
      }
      children.push(h('button', { text: 'Би төлсөн', disabled: sending, onclick: function () { setPaid(true); } }));
    }
    return h('div', { cls: 'card hero', id: 'pay' }, children);
  }

  function peopleCard() {
    var rows = bill.guests.map(function (person) {
      var label = person.name + (person.isHost ? ' (төлөгч)' : '') + (me && person.id === me.guestId ? ' (та)' : '');
      return h('div', { cls: 'person' },
        h('span', null, label,
          person.paid && !person.isHost ? h('span', { cls: 'badge', text: 'Төлсөн' }) : null,
          !person.paid && !person.isHost && person.paidCents > 0 ? h('span', { cls: 'badge', text: 'Дутуу' }) : null),
        h('span', { cls: 'num', text: money(person.totalCents, bill.currency) }));
    });
    if (bill.unclaimedCents > 0) {
      rows.push(h('div', { cls: 'person muted' }, h('span', { text: 'Хэн ч сонгоогүй' }), h('span', { cls: 'num', text: money(bill.unclaimedCents, bill.currency) })));
    }
    return h('div', { cls: 'card' }, h('h2', { text: 'Бүгд' }), rows);
  }

  function renderBar(guest) {
    if (!guest || (guest.totalCents === 0 && guest.paidCents === 0)) { bar.hidden = true; return; }
    bar.hidden = false;
    var label = 'Таны дүн';
    if (guest.paid) label = 'Төлсөн';
    else if (stillDue(guest)) label = 'Үлдэгдэл';
    bar.replaceChildren(h('div', { cls: 'in' },
      h('div', { cls: 'total' }, h('div', { cls: 'muted small', text: label }), h('strong', { cls: 'num', text: money(amountToSend(guest), bill.currency) })),
      h('button', { text: 'Төлөх', onclick: function () { document.getElementById('pay').scrollIntoView({ behavior: 'smooth' }); } })));
  }

  // Start

  me = loadMe();
  refresh();
  // Others tick lines too, and shared lines re-split as they do, so poll while the page is visible.
  // Skip a poll while a write is in flight or while someone is typing their name.
  setInterval(function () {
    var typingName = !myGuest() && document.activeElement && document.activeElement.id === 'name';
    if (stopped || document.hidden || sending || desired || typingName) return;
    refresh();
  }, 5000);
})();
</script>
</body>
</html>`;
}
