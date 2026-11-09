/**
 * The page a guest sees after scanning the bill QR. One self-contained HTML document: no build step,
 * no external requests except its own API and the host's QR image on S3, so it opens instantly on
 * restaurant wifi.
 *
 * Safety: every name and item comes from people typing, so the script only ever sets textContent,
 * never innerHTML. The CSP allows only this page's own nonce'd script and style.
 *
 * The script avoids template literals on purpose: this whole file is a TS template literal.
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
  var me = null;         // { guestId, secret, name } kept in this browser only
  var desired = null;    // ticks waiting to be sent
  var sending = false;
  var errorText = null;
  var qrImg = null;      // kept across renders so the image doesn't reload every poll

  var ERRORS = {
    BILL_NOT_FOUND: 'Тооцоо олдсонгүй. Холбоосоо шалгана уу.',
    BILL_CLOSED: 'Тооцоо хаагдсан тул сонголтоо өөрчлөх боломжгүй.',
    BILL_FULL: 'Энэ тооцоонд хэт олон хүн нэгдсэн байна.',
    GUEST_NOT_FOUND: 'Таныг энэ тооцооноос хассан байна. Дахин нэгдэнэ үү.',
    VALIDATION_ERROR: 'Оруулсан мэдээллээ шалгана уу.',
    NETWORK: 'Интернэт холболт алга. Дахин оролдоно уу.'
  };
  function errorMessage(code) { return ERRORS[code] || 'Алдаа гарлаа. Дахин оролдоно уу.'; }

  // ---- money: integer cents in, text out. Same rules as the app; no float math.
  var SYMBOLS = { USD: '$', EUR: '€', GBP: '£', MNT: '₮', KRW: '₩', CNY: '¥', JPY: '¥' };
  function splitCents(c) {
    var abs = Math.abs(c), frac = abs % 100;
    return { sign: c < 0 ? '-' : '', whole: String((abs - frac) / 100), frac: (frac < 10 ? '0' : '') + frac };
  }
  function money(c, currency) {
    var p = splitCents(c);
    var grouped = p.whole.replace(/\\B(?=(\\d{3})+(?!\\d))/g, ',');
    var sym = SYMBOLS[currency];
    // Tugrik amounts are almost always whole: "42,500₮", not "42,500.00₮". Same rule as the app.
    if (currency === 'MNT') return p.sign + grouped + (p.frac === '00' ? '' : '.' + p.frac) + '₮';
    return p.sign + (sym || currency + ' ') + grouped + '.' + p.frac;
  }
  /** For typing into a bank app: "12500" or "12500.50". */
  function plainAmount(c) {
    var p = splitCents(c);
    return p.frac === '00' ? p.whole : p.whole + '.' + p.frac;
  }

  // ---- tiny DOM helper: text only, never HTML
  function h(tag, props) {
    var el = document.createElement(tag);
    if (props) for (var k in props) {
      if (k === 'text') el.textContent = props[k];
      else if (k === 'cls') el.className = props[k];
      else if (k.slice(0, 2) === 'on') el.addEventListener(k.slice(2), props[k]);
      else if (props[k] !== false && props[k] != null) el.setAttribute(k, props[k] === true ? '' : props[k]);
    }
    var add = function (c) {
      if (c == null || c === false) return;
      if (Array.isArray(c)) { c.forEach(add); return; }
      el.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    };
    for (var i = 2; i < arguments.length; i++) add(arguments[i]);
    return el;
  }

  function toast(text) {
    toastEl.textContent = text;
    toastEl.hidden = false;
    clearTimeout(toast.t);
    toast.t = setTimeout(function () { toastEl.hidden = true; }, 1600);
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

  // ---- actions

  function refresh() {
    return api('GET', '/data').then(function (data) {
      bill = data;
      if (me && !myGuest()) { forgetMe(); me = null; }
      render();
    }, function (e) {
      if (!bill) { renderFatal(errorMessage(e.code)); }
    });
  }

  function join(name) {
    if (!me || me.name !== name) me = { guestId: randomId(12), secret: randomId(32), name: name };
    saveMe(me); // before sending: a retry after a dropped connection reuses the same id
    errorText = null;
    render();
    return api('POST', '/guests', { name: name, guestId: me.guestId, secret: me.secret }).then(function (res) {
      bill = res.bill;
      render();
    }, function (e) {
      if (e.code !== 'NETWORK') { forgetMe(); me = null; }
      errorText = errorMessage(e.code);
      render();
    });
  }

  function toggle(itemId) {
    var g = myGuest();
    if (!g || bill.status !== 'OPEN') return;
    var set = {};
    var current = desired || g.itemIds;
    for (var i = 0; i < current.length; i++) set[current[i]] = true;
    if (set[itemId]) delete set[itemId]; else set[itemId] = true;
    desired = Object.keys(set);
    g.itemIds = desired; // show the tick now; totals update when the server answers
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

  function setPaid(paid) {
    sending = true;
    api('PUT', '/guests/' + encodeURIComponent(me.guestId), { paid: paid }, { 'x-guest-secret': me.secret })
      .then(function (data) { bill = data; errorText = null; }, function (e) { errorText = errorMessage(e.code); })
      .then(function () { sending = false; render(); });
  }

  // ---- rendering

  function renderFatal(text) {
    bar.hidden = true;
    app.replaceChildren(h('div', { cls: 'card center' }, h('h2', { text: 'NetZero' }), h('p', { cls: 'muted', text: text })));
  }

  function render() {
    if (!bill) return;
    var g = myGuest();
    var open = bill.status === 'OPEN';
    var nodes = [];

    nodes.push(h('h1', { text: bill.title }));
    nodes.push(h('p', { cls: 'muted' }, 'Төлсөн: ' + bill.hostName + ' · Нийт ', h('span', { cls: 'num', text: money(bill.totalCents, bill.currency) })));
    if (!open) nodes.push(h('div', { cls: 'banner', text: 'Тооцоо хаагдсан. Сонголтоо өөрчлөх боломжгүй, гэхдээ төлбөрөө тэмдэглэж болно.' }));
    if (errorText) nodes.push(h('div', { cls: 'error', text: errorText }));

    if (!g && open) nodes.push(joinCard());
    nodes.push(itemsCard(g, open));
    if (g) nodes.push(payCard(g));
    nodes.push(peopleCard());

    app.replaceChildren.apply(app, nodes);
    renderBar(g);
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

  function itemsCard(g, open) {
    var mine = {};
    if (g) for (var i = 0; i < g.itemIds.length; i++) mine[g.itemIds[i]] = true;
    var rows = bill.items.map(function (item) {
      var checked = !!mine[item.id];
      var locked = !g || !open;
      var names = item.claimedBy.map(guestName).filter(Boolean);
      var share = g && item.shares[g.id];
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
      h('p', { cls: 'muted small', text: g ? 'Өөрийнхөө зүйлсийг сонгоно уу. Хэд хэдэн хүн сонгосон зүйл тэдний дунд тэнцүү хуваагдана.' : 'Эхлээд нэрээ оруулаад нэгдэнэ үү.' }),
      rows);
  }

  function payCard(g) {
    var children = [h('h2', { text: 'Таны төлөх дүн' }), h('div', { cls: 'big', text: money(g.totalCents, bill.currency) })];
    if (g.totalCents === 0) {
      children.push(h('p', { cls: 'muted small', text: 'Дээрээс идсэн, уусан зүйлээ сонгоход дүн гарна.' }));
      return h('div', { cls: 'card', id: 'pay' }, children);
    }
    var hero = true;
    var p = bill.payment;
    var note = bill.code + ' ' + g.name;
    var kv = function (k, v, copyText) {
      return h('div', { cls: 'kv' },
        h('div', null, h('div', { cls: 'k', text: k }), h('div', { cls: 'v', text: v })),
        copyText ? h('button', { cls: 'link', text: 'Хуулах', onclick: function () { copy(copyText); } }) : null);
    };
    if (p) {
      children.push(kv('Банк', p.bankName));
      children.push(kv('Дансны дугаар', p.accountNumber, p.accountNumber.replace(/\\s+/g, '')));
      children.push(kv('Данс эзэмшигч', p.accountName));
    } else {
      children.push(h('p', { cls: 'muted small', text: bill.hostName + '-тэй төлбөрөө тохиролцоно уу.' }));
    }
    children.push(kv('Дүн', money(g.totalCents, bill.currency), plainAmount(g.totalCents)));
    children.push(kv('Гүйлгээний утга', note, note));
    if (bill.payQrUrl) {
      if (!qrImg) qrImg = h('img', { cls: 'qr', alt: 'Төлбөрийн QR', src: bill.payQrUrl, referrerpolicy: 'no-referrer' });
      children.push(qrImg);
      children.push(h('p', { cls: 'muted small center', text: 'QR зургийг удаан дарж хадгалаад, банкны аппаараа уншуулна уу.' }));
    }
    if (g.paid) {
      children.push(h('p', { cls: 'center mine', text: 'Төлсөн гэж тэмдэглэсэн ✓' }));
      children.push(h('button', { cls: 'ghost', text: 'Буцаах', disabled: sending, onclick: function () { setPaid(false); } }));
    } else {
      children.push(h('button', { text: 'Би төлсөн', disabled: sending, onclick: function () { setPaid(true); } }));
    }
    return h('div', { cls: hero ? 'card hero' : 'card', id: 'pay' }, children);
  }

  function peopleCard() {
    var rows = bill.guests.map(function (p) {
      var label = p.name + (p.isHost ? ' (төлөгч)' : '') + (me && p.id === me.guestId ? ' (та)' : '');
      return h('div', { cls: 'person' },
        h('span', null, label, p.paid && !p.isHost ? h('span', { cls: 'badge', text: 'Төлсөн' }) : null),
        h('span', { cls: 'num', text: money(p.totalCents, bill.currency) }));
    });
    if (bill.unclaimedCents > 0) {
      rows.push(h('div', { cls: 'person muted' }, h('span', { text: 'Хэн ч сонгоогүй' }), h('span', { cls: 'num', text: money(bill.unclaimedCents, bill.currency) })));
    }
    return h('div', { cls: 'card' }, h('h2', { text: 'Бүгд' }), rows);
  }

  function renderBar(g) {
    if (!g || g.totalCents === 0) { bar.hidden = true; return; }
    bar.hidden = false;
    bar.replaceChildren(h('div', { cls: 'in' },
      h('div', { cls: 'total' }, h('div', { cls: 'muted small', text: g.paid ? 'Төлсөн' : 'Таны дүн' }), h('strong', { cls: 'num', text: money(g.totalCents, bill.currency) })),
      h('button', { text: 'Төлөх', onclick: function () { document.getElementById('pay').scrollIntoView({ behavior: 'smooth' }); } })));
  }

  // ---- start

  me = loadMe();
  refresh();
  // Others tick lines too; shared lines re-split as they do. Poll while the page is visible.
  setInterval(function () {
    if (document.hidden || sending || desired || (!myGuest() && document.activeElement && document.activeElement.id === 'name')) return;
    refresh();
  }, 5000);
})();
</script>
</body>
</html>`;
}
