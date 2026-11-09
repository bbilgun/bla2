import { createHash, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
import { computeBill } from '../domain/bill';
import { badRequest, conflict, gone, notFound } from '../domain/errors';
import {
  BillContentDto,
  BillStatusDto,
  ConfirmUploadDto,
  GuestUpdateDto,
  JoinBillDto,
  PageQueryDto,
  ReceiptUploadDto,
} from '../dto';
import type { AuthedRequest, Request, Response } from '../lib/http';
import { signUpload, signView } from '../lib/s3';
import { toObjectId, type BillDoc, type BillGuestDoc, type BillItemDoc } from '../repositories/collections';
import * as repo from '../repositories/bills';
import { setPayQrKey } from '../repositories/users';
import { idempotent } from './idempotency';
import { discardReplaced, newImageKey, requireUploadedKey } from './uploads';
import { registerCaller } from './users';

/**
 * QR bill splitting.
 *
 *   Host (app, signed in)        creates a bill: lines + where to pay. Gets a link + QR.
 *   Guests (browser, no account) open the link, type a name, tick what they had, see what they owe,
 *                                pay the host by bank transfer, tap "I paid".
 *
 * Totals are never stored: every response recomputes them from lines and ticks (domain/bill.ts).
 * What *is* stored per guest is the amount they marked as paid, so a later change of ticks shows up as
 * "still due" or "paid too much" instead of silently un-marking them.
 */

export const MAX_GUESTS = 50;
export const HOST_GUEST_ID = 'host';
/** Guest links stop working this long after the bill was created (rotating the token doesn't extend it). */
export const BILL_LINK_TTL_DAYS = 90;
const DAY_MS = 24 * 60 * 60 * 1000;
const TOKEN_RE = /^[A-Za-z0-9_-]{22}$/;
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; // no 0/O, 1/I/L: it gets typed into bank apps
/** A guest write that keeps missing because the host keeps editing lines gives up the guard after this many tries. */
const GUEST_WRITE_ATTEMPTS = 3;

const newToken = () => randomBytes(16).toString('base64url'); // 128 bits, 22 chars
const newItemId = () => randomBytes(6).toString('base64url');
const newCode = () => Array.from({ length: 6 }, () => CODE_ALPHABET[randomInt(CODE_ALPHABET.length)]).join('');
const hashSecret = (secret: string) => createHash('sha256').update(secret).digest('hex');
/** "  Бат " and "бат" are the same person on a bank statement. */
const nameKeyOf = (name: string) => name.normalize('NFC').trim().replace(/\s+/g, ' ').toLowerCase();

function sameHash(a: string | null, b: string): boolean {
  if (!a || a.length !== b.length) return false;
  return timingSafeEqual(Buffer.from(a), Buffer.from(b));
}

const billNotFound = () => notFound('BILL_NOT_FOUND', 'Bill not found');
const billClosed = () => conflict('BILL_CLOSED', 'This bill is closed');
const guestNotFound = () => notFound('GUEST_NOT_FOUND', 'Guest not found');

/** Legacy guests have only `paid: true`: read that as "paid their current total". */
function paidCentsOf(guest: BillGuestDoc, totalCents: number): number {
  if (guest.paidCents !== undefined) return guest.paidCents;
  return guest.paid ? totalCents : 0;
}

// ---------------------------------------------------------------- views

/** What both the host and the guests see. Secrets never leave the server. */
function baseView(bill: BillDoc, hasPayQr: boolean) {
  const b = computeBill(bill.items, bill.guests);
  const known = new Set(bill.items.map((i) => i.id));
  const guests = bill.guests.map((g) => {
    const totalCents = b.guestTotals.get(g.id) ?? 0;
    const paidCents = paidCentsOf(g, totalCents);
    const dueCents = totalCents - paidCents; // negative: paid too much
    return {
      id: g.id,
      name: g.name,
      isHost: g.isHost,
      paid: paidCents > 0 && dueCents <= 0,
      paidCents,
      dueCents,
      itemIds: g.itemIds.filter((id) => known.has(id)),
      totalCents,
    };
  });
  const others = guests.filter((g) => !g.isHost);
  return {
    id: bill._id.toHexString(),
    code: bill.code,
    title: bill.title,
    currency: bill.currency,
    status: bill.status,
    hostName: bill.hostName,
    items: bill.items.map((i) => ({
      id: i.id,
      name: i.name,
      priceCents: i.priceCents,
      claimedBy: b.claimers.get(i.id) ?? [],
      shares: Object.fromEntries(b.shares.get(i.id) ?? []),
    })),
    guests,
    totalCents: b.totalCents,
    claimedCents: b.claimedCents,
    unclaimedCents: b.unclaimedCents,
    /** What guests (not the host) owe the host in total, and how much of it they've marked paid. */
    owedCents: others.reduce((acc, g) => acc + g.totalCents, 0),
    paidCents: others.reduce((acc, g) => acc + g.paidCents, 0),
    payment: bill.payment,
    hasPayQr,
    createdAt: bill.createdAt.toISOString(),
    updatedAt: bill.updatedAt.toISOString(),
  };
}

async function hostView(req: Request, bill: BillDoc) {
  const payQrKey = await repo.findPayQrKey(bill.hostUserId);
  return { ...baseView(bill, Boolean(payQrKey)), token: bill.token, url: `https://${req.host}/b/${bill.token}` };
}

async function guestView(bill: BillDoc) {
  const payQrKey = await repo.findPayQrKey(bill.hostUserId);
  return { ...baseView(bill, Boolean(payQrKey)), payQrUrl: payQrKey ? await signView(payQrKey) : null };
}

function summaryView(bill: BillDoc) {
  const v = baseView(bill, false);
  return {
    id: v.id,
    code: v.code,
    title: v.title,
    currency: v.currency,
    status: v.status,
    totalCents: v.totalCents,
    unclaimedCents: v.unclaimedCents,
    owedCents: v.owedCents,
    paidCents: v.paidCents,
    guestCount: v.guests.filter((g) => !g.isHost).length,
    paidCount: v.guests.filter((g) => !g.isHost && g.paid).length,
    createdAt: v.createdAt,
  };
}

// ---------------------------------------------------------------- guest updates (shared by host and guest routes)

/**
 * Turns a request into stored changes against one version of the bill:
 *  - ticks on lines that aren't on the bill are dropped (the host may have just deleted one), never a 400;
 *  - `paid: false` stores 0; `paidCents` is stored as sent; `paid: true` alone stores the guest's total
 *    (with this request's ticks applied).
 */
function changesFor(bill: BillDoc, guestId: string, input: GuestUpdateDto): repo.GuestChanges {
  const known = new Set(bill.items.map((i) => i.id));
  const changes: repo.GuestChanges = {};
  if (input.itemIds !== undefined) changes.itemIds = [...new Set(input.itemIds.filter((id) => known.has(id)))];
  if (input.paid === false) changes.paidCents = 0;
  else if (input.paidCents !== undefined) changes.paidCents = input.paidCents;
  else if (input.paid === true) {
    const guests = bill.guests.map((g) => (g.id === guestId && changes.itemIds ? { ...g, itemIds: changes.itemIds } : g));
    changes.paidCents = computeBill(bill.items, guests).guestTotals.get(guestId) ?? 0;
  }
  return changes;
}

/**
 * Writes a guest's changes. The write only lands if every tick is still a line on the bill; if the host
 * edited lines in between, it re-reads (which also re-checks the guest, the secret and the status, and
 * throws the right error) and tries again. The last attempt drops the guard: a tick on a vanished line
 * is harmless (totals ignore it) and better than failing the guest.
 */
async function writeGuest(
  bill: BillDoc,
  guestId: string,
  input: GuestUpdateDto,
  write: (changes: repo.GuestChanges, opts: repo.GuestWriteOptions) => Promise<BillDoc | null>,
  reload: () => Promise<BillDoc>,
): Promise<BillDoc> {
  let current = bill;
  for (let attempt = 1; ; attempt++) {
    const updated = await write(changesFor(current, guestId, input), { requireItems: attempt < GUEST_WRITE_ATTEMPTS });
    if (updated) return updated;
    current = await reload();
    if (attempt >= GUEST_WRITE_ATTEMPTS) throw guestNotFound();
  }
}

// ---------------------------------------------------------------- host (signed in)

/** Keeps the ids of lines that already exist (guests keep their ticks), new lines get new ids. */
function withItemIds(items: BillContentDto['items'], existing: readonly BillItemDoc[]): BillItemDoc[] {
  const known = new Set(existing.map((i) => i.id));
  const used = new Set<string>();
  return items.map((item) => {
    const id = item.id && known.has(item.id) && !used.has(item.id) ? item.id : newItemId();
    used.add(id);
    return { id, name: item.name, priceCents: item.priceCents };
  });
}

async function requireOwnBill(req: AuthedRequest, billId: string): Promise<BillDoc> {
  const id = toObjectId(billId);
  const bill = id ? await repo.findBillForHost(id, req.caller.userId) : null;
  if (!bill) throw billNotFound(); // someone else's bill looks exactly like a missing one
  return bill;
}

export async function createBill(req: AuthedRequest): Promise<Response> {
  const input = BillContentDto.parse(req.body);
  await registerCaller(req.caller);

  return idempotent(req, async (resourceId) => {
    const now = new Date();
    const host: BillGuestDoc = {
      id: HOST_GUEST_ID,
      name: req.caller.name,
      nameKey: nameKeyOf(req.caller.name),
      isHost: true,
      secretHash: null,
      itemIds: [],
      paidCents: 0,
      joinedAt: now,
      updatedAt: now,
    };
    const bill = await repo.insertBillOnce({
      _id: resourceId,
      hostUserId: req.caller.userId,
      hostName: req.caller.name,
      token: newToken(),
      code: newCode(),
      title: input.title,
      currency: input.currency,
      items: withItemIds(input.items, []),
      guests: [host],
      removedGuestIds: [],
      payment: input.payment,
      status: 'OPEN',
      createdAt: now,
      updatedAt: now,
    });
    if (input.payment) await repo.savePaymentProfile(req.caller.userId, input.payment);
    return { status: 201, body: await hostView(req, bill) };
  });
}

export async function listBills(req: AuthedRequest): Promise<Response> {
  const query = PageQueryDto.parse(req.query);
  const cursor = query.cursor ? (toObjectId(query.cursor) ?? undefined) : undefined;
  const page = await repo.listBillsForHost(req.caller.userId, { limit: query.limit, cursor });
  return { status: 200, body: { items: page.items.map(summaryView), nextCursor: page.nextCursor } };
}

export async function getBill(req: AuthedRequest, billId: string): Promise<Response> {
  return { status: 200, body: await hostView(req, await requireOwnBill(req, billId)) };
}

/**
 * Full replace of title, currency, lines and payment. Naturally idempotent: same body, same result.
 * Only while OPEN: closing freezes what guests agreed to, so editing needs a reopen first.
 */
export async function updateBill(req: AuthedRequest, billId: string): Promise<Response> {
  const bill = await requireOwnBill(req, billId);
  const input = BillContentDto.parse(req.body);
  if (bill.status === 'CLOSED') throw billClosed();
  const updated = await repo.replaceContent(bill._id, req.caller.userId, {
    title: input.title,
    currency: input.currency,
    items: withItemIds(input.items, bill.items),
    payment: input.payment,
  });
  if (!updated) {
    if ((await requireOwnBill(req, billId)).status === 'CLOSED') throw billClosed();
    throw billNotFound();
  }
  if (input.payment) await repo.savePaymentProfile(req.caller.userId, input.payment);
  return { status: 200, body: await hostView(req, updated) };
}

export async function setBillStatus(req: AuthedRequest, billId: string): Promise<Response> {
  const bill = await requireOwnBill(req, billId);
  const { status } = BillStatusDto.parse(req.body);
  const updated = await repo.setStatus(bill._id, req.caller.userId, status);
  if (!updated) throw billNotFound();
  return { status: 200, body: await hostView(req, updated) };
}

/** Hard delete: a bill is the host's own note, not a shared ledger. */
export async function deleteBill(req: AuthedRequest, billId: string): Promise<Response> {
  const id = toObjectId(billId);
  if (!id || !(await repo.deleteBill(id, req.caller.userId))) throw billNotFound();
  return { status: 200, body: { id: billId, deleted: true } };
}

/** A new link (and QR); the old one stops working. For a link that got shared too widely. */
export async function rotateBillToken(req: AuthedRequest, billId: string): Promise<Response> {
  const bill = await requireOwnBill(req, billId);
  const updated = await repo.rotateToken(bill._id, req.caller.userId, newToken());
  if (!updated) throw billNotFound();
  return { status: 200, body: await hostView(req, updated) };
}

/** The host ticking their own lines (guest "host"), fixing a guest's ticks, or marking a cash payment. */
export async function hostUpdateGuest(req: AuthedRequest, billId: string, guestId: string): Promise<Response> {
  const bill = await requireOwnBill(req, billId);
  const input = GuestUpdateDto.parse(req.body);
  const requireGuest = (b: BillDoc) => {
    if (!b.guests.some((g) => g.id === guestId)) throw guestNotFound();
    return b;
  };
  requireGuest(bill);
  const updated = await writeGuest(
    bill,
    guestId,
    input,
    (changes, opts) => repo.updateGuestAsHost(bill._id, req.caller.userId, guestId, changes, opts),
    async () => requireGuest(await requireOwnBill(req, billId)),
  );
  return { status: 200, body: await hostView(req, updated) };
}

export async function removeGuest(req: AuthedRequest, billId: string, guestId: string): Promise<Response> {
  const bill = await requireOwnBill(req, billId);
  if (guestId === HOST_GUEST_ID) throw badRequest('CANNOT_REMOVE_HOST', 'The host cannot be removed');
  const updated = await repo.removeGuest(bill._id, req.caller.userId, guestId);
  if (!updated) throw guestNotFound();
  return { status: 200, body: await hostView(req, updated) };
}

// ---------------------------------------------------------------- the host's bank QR (two-step upload)

const payQrPrefix = (userId: string) => `users/${userId}/pay-qr/`;

/** POST /me/pay-qr-url: a presigned POST for a screenshot of the host's bank-app "receive money" QR. */
export async function createPayQrUploadUrl(req: AuthedRequest): Promise<Response> {
  const { contentType } = ReceiptUploadDto.parse(req.body);
  const key = newImageKey(payQrPrefix(req.caller.userId), contentType);
  return { status: 200, body: await signUpload(key, contentType) };
}

/** PUT /me/pay-qr { key }: the upload finished. Shown on every bill from now on; the old image is deleted. */
export async function confirmPayQr(req: AuthedRequest): Promise<Response> {
  const { key } = ConfirmUploadDto.parse(req.body);
  await requireUploadedKey(key, payQrPrefix(req.caller.userId));
  await registerCaller(req.caller);
  const previous = await setPayQrKey(req.caller.userId, key);
  await discardReplaced(previous, key, req.log);
  return { status: 200, body: { payQrUrl: await signView(key) } };
}

// ---------------------------------------------------------------- guests (public, by link token)

async function requireBillByToken(token: string): Promise<BillDoc> {
  const bill = TOKEN_RE.test(token) ? await repo.findBillByToken(token) : null;
  if (!bill) throw billNotFound();
  if (Date.now() - bill.createdAt.getTime() > BILL_LINK_TTL_DAYS * DAY_MS) {
    throw gone('BILL_EXPIRED', 'This bill link has expired');
  }
  return bill;
}

export async function guestGetBill(token: string): Promise<Response> {
  return { status: 200, body: await guestView(await requireBillByToken(token)) };
}

export async function guestJoin(req: Request, token: string): Promise<Response> {
  const bill = await requireBillByToken(token);
  const input = JoinBillDto.parse(req.body);
  const secretHash = hashSecret(input.secret);
  const nameKey = nameKeyOf(input.name);
  const nameTaken = (b: BillDoc) => b.guests.some((g) => g.id !== input.guestId && (g.nameKey ?? nameKeyOf(g.name)) === nameKey);
  // Why a join didn't happen, most specific first.
  const refuse = (b: BillDoc) => {
    if (b.removedGuestIds?.includes(input.guestId)) return conflict('GUEST_REMOVED', 'The host removed you from this bill');
    if (b.status === 'CLOSED') return billClosed();
    if (nameTaken(b)) return conflict('NAME_TAKEN', 'Someone on this bill already has that name');
    return null;
  };

  // A retried join (same id) skips the checks: it either finds itself below or is refused there.
  // Otherwise check first: the atomic filter only knows names stored with a nameKey.
  if (!bill.guests.some((g) => g.id === input.guestId)) {
    const reason = refuse(bill);
    if (reason) throw reason;
  }

  const now = new Date();
  const after = await repo.addGuest(
    token,
    {
      id: input.guestId,
      name: input.name,
      nameKey,
      isHost: false,
      secretHash,
      itemIds: [],
      paidCents: 0,
      joinedAt: now,
      updatedAt: now,
    },
    MAX_GUESTS,
  );
  const me = after?.guests.find((g) => g.id === input.guestId);
  if (after && me) {
    // Joined now, or a retry of a join that already went through: same id and same secret.
    if (!sameHash(me.secretHash, secretHash)) throw conflict('GUEST_ID_TAKEN', 'Try joining again');
    return { status: 201, body: { guestId: me.id, bill: await guestView(after) } };
  }
  throw refuse(after ?? bill) ?? conflict('BILL_FULL', `A bill can have at most ${MAX_GUESTS} people`);
}

export async function guestUpdate(req: Request, token: string, guestId: string): Promise<Response> {
  const secretHash = hashSecret(req.header('x-guest-secret') ?? '');
  const input = GuestUpdateDto.safeParse(req.body);
  /** Re-checked on every read: a wrong secret looks exactly like a missing guest. */
  const load = async () => {
    const bill = await requireBillByToken(token);
    const guest = bill.guests.find((g) => g.id === guestId && !g.isHost);
    if (!guest || !sameHash(guest.secretHash, secretHash)) throw guestNotFound();
    if (input.success && input.data.itemIds !== undefined && bill.status === 'CLOSED') throw billClosed();
    return bill;
  };
  const bill = await load();
  if (!input.success) throw input.error;
  const updated = await writeGuest(
    bill,
    guestId,
    input.data,
    (changes, opts) => repo.updateGuestBySecret(token, guestId, secretHash, changes, opts),
    load,
  );
  return { status: 200, body: await guestView(updated) };
}
