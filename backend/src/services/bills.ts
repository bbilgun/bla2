// QR bill splitting. The host creates a bill in the app and shares its link; guests open the link with no
// account, tick what they had and mark what they paid. Totals are never stored, only lines, ticks and
// paid amounts, so every response works them out again (services/serializers.ts billJson).
import { createHash, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
import { computeBill } from '../domain/bill';
import { badRequest, conflict, gone, notFound, type AppError } from '../domain/errors';
import { BillContentDto, BillStatusDto, GuestUpdateDto, JoinBillDto, PageQueryDto } from '../dto';
import type { AuthedRequest, Request, Response } from '../lib/http';
import { signView } from '../lib/s3';
import * as repo from '../repositories/bills';
import { toObjectId } from '../repositories/collections';
import type { BillDoc, BillGuestDoc, BillItemDoc } from '../repositories/documents';
import { findPayQrKey, savePaymentProfile } from '../repositories/users';
import { idempotent } from './idempotency';
import { billJson, billSummaryJson } from './serializers';
import { registerCaller } from './users';

/** Most people on one bill, the host included. */
const MAX_GUESTS = 50;
/** The host's guest id on every bill. */
const HOST_GUEST_ID = 'host';
/** Guest links stop working this many days after the bill was created. Rotating the token doesn't extend it. */
const BILL_LINK_TTL_DAYS = 90;
/** After this many misses, a guest write stops insisting that every ticked line still exists. */
const GUEST_WRITE_ATTEMPTS = 3;

const DAY_MS = 24 * 60 * 60 * 1000;
const TOKEN_RE = /^[A-Za-z0-9_-]{22}$/;
// No 0/O or 1/I/L, because people type the code into their bank app.
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

const billNotFound = () => notFound('BILL_NOT_FOUND', 'Bill not found');
const billClosed = () => conflict('BILL_CLOSED', 'This bill is closed');
const guestNotFound = () => notFound('GUEST_NOT_FOUND', 'Guest not found');

/** 128 random bits as 22 URL-safe characters. */
const newToken = () => randomBytes(16).toString('base64url');
const newItemId = () => randomBytes(6).toString('base64url');
const newCode = () => Array.from({ length: 6 }, () => CODE_ALPHABET[randomInt(CODE_ALPHABET.length)]).join('');
const hashSecret = (secret: string) => createHash('sha256').update(secret).digest('hex');

/** "  Бат " and "бат" are the same person on a bank statement. */
function nameKeyOf(name: string): string {
  return name.normalize('NFC').trim().replace(/\s+/g, ' ').toLowerCase();
}

function sameHash(stored: string | null, given: string): boolean {
  if (!stored || stored.length !== given.length) return false;
  return timingSafeEqual(Buffer.from(stored), Buffer.from(given));
}

// The bill as the host's app sees it, with the share link.
async function hostView(req: Request, bill: BillDoc) {
  const payQrKey = await findPayQrKey(bill.hostUserId);
  return { ...billJson(bill, Boolean(payQrKey)), token: bill.token, url: `https://${req.host}/b/${bill.token}` };
}

// The bill as a guest's browser sees it, with a short-lived URL for the host's bank QR.
async function guestView(bill: BillDoc) {
  const payQrKey = await findPayQrKey(bill.hostUserId);
  const payQrUrl = payQrKey ? await signView(payQrKey) : null;
  return { ...billJson(bill, Boolean(payQrKey)), payQrUrl };
}

// Guest updates, shared by the host and guest routes

/**
 * Works out what to store for a guest update. Ticks on lines the bill doesn't have are ignored,
 * because the host may have deleted the line while the guest was looking at it.
 * Marking paid without an amount records the guest's current total.
 */
function changesFor(bill: BillDoc, guestId: string, input: GuestUpdateDto): repo.GuestChanges {
  const lineIds = new Set(bill.items.map((item) => item.id));
  const changes: repo.GuestChanges = {};

  if (input.itemIds !== undefined) {
    const known = input.itemIds.filter((id) => lineIds.has(id));
    changes.itemIds = [...new Set(known)];
  }

  if (input.paid === false) {
    changes.paidCents = 0;
  } else if (input.paidCents !== undefined) {
    changes.paidCents = input.paidCents;
  } else if (input.paid === true) {
    // The total counts this request's ticks, if it has any.
    const itemIds = changes.itemIds;
    const guests = bill.guests.map((guest) => (guest.id === guestId && itemIds ? { ...guest, itemIds } : guest));
    changes.paidCents = computeBill(bill.items, guests).guestTotals.get(guestId) ?? 0;
  }
  return changes;
}

/**
 * Writes a guest update. The write only lands if every ticked line is still on the bill. If the host
 * edited lines in between, we reload, which re-checks the guest, the secret and the status, and try
 * again. The last attempt drops that guard: a tick on a vanished line is harmless and better than failing.
 */
async function writeGuest(
  bill: BillDoc,
  guestId: string,
  input: GuestUpdateDto,
  write: (changes: repo.GuestChanges, options: repo.GuestWriteOptions) => Promise<BillDoc | null>,
  reload: () => Promise<BillDoc>,
): Promise<BillDoc> {
  let current = bill;
  for (let attempt = 1; attempt <= GUEST_WRITE_ATTEMPTS; attempt++) {
    const isLastAttempt = attempt === GUEST_WRITE_ATTEMPTS;
    const updated = await write(changesFor(current, guestId, input), { requireItems: !isLastAttempt });
    if (updated) return updated;
    current = await reload();
  }
  throw guestNotFound();
}

// Host routes, signed in

// Keeps the ids of lines that already exist, so guests keep their ticks. New lines get new ids.
function withItemIds(items: BillContentDto['items'], existing: readonly BillItemDoc[]): BillItemDoc[] {
  const existingIds = new Set(existing.map((item) => item.id));
  const used = new Set<string>();
  return items.map((item) => {
    let id = item.id;
    if (!id || !existingIds.has(id) || used.has(id)) {
      id = newItemId();
    }
    used.add(id);
    return { id, name: item.name, priceCents: item.priceCents };
  });
}

// Someone else's bill gets exactly the same 404 as a missing one.
async function requireOwnBill(req: AuthedRequest, billId: string): Promise<BillDoc> {
  const id = toObjectId(billId);
  const bill = id ? await repo.findBillForHost(id, req.caller.userId) : null;
  if (!bill) throw billNotFound();
  return bill;
}

function requireGuest(bill: BillDoc, guestId: string): BillDoc {
  if (!bill.guests.some((guest) => guest.id === guestId)) throw guestNotFound();
  return bill;
}

/** Creates a bill with the host as its first guest. Needs an Idempotency-Key. */
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
    if (input.payment) await savePaymentProfile(req.caller.userId, input.payment);
    return { status: 201, body: await hostView(req, bill) };
  });
}

/** One page of the caller's bills, newest first. */
export async function listBills(req: AuthedRequest): Promise<Response> {
  const query = PageQueryDto.parse(req.query);
  const page = await repo.listBillsForHost(req.caller.userId, query);
  return { status: 200, body: { items: page.items.map(billSummaryJson), nextCursor: page.nextCursor } };
}

/** One of the caller's bills. */
export async function getBill(req: AuthedRequest, billId: string): Promise<Response> {
  const bill = await requireOwnBill(req, billId);
  return { status: 200, body: await hostView(req, bill) };
}

/**
 * Replaces the title, currency, lines and payment details. Sending the same body twice gives the same
 * result. Only while the bill is open: closing freezes what guests agreed to, so the host reopens first.
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
    // Closed or deleted between our read and the write.
    const latest = await requireOwnBill(req, billId);
    if (latest.status === 'CLOSED') throw billClosed();
    throw billNotFound();
  }

  if (input.payment) await savePaymentProfile(req.caller.userId, input.payment);
  return { status: 200, body: await hostView(req, updated) };
}

/** Opens or closes the bill. Guests can't join or change ticks on a closed bill, but can still mark paid. */
export async function setBillStatus(req: AuthedRequest, billId: string): Promise<Response> {
  const bill = await requireOwnBill(req, billId);
  const { status } = BillStatusDto.parse(req.body);

  const updated = await repo.setStatus(bill._id, req.caller.userId, status);
  if (!updated) throw billNotFound();
  return { status: 200, body: await hostView(req, updated) };
}

/** Deletes the bill for good. A bill is the host's own note, not a shared ledger, so there's no soft delete. */
export async function deleteBill(req: AuthedRequest, billId: string): Promise<Response> {
  const id = toObjectId(billId);
  const deleted = id ? await repo.deleteBill(id, req.caller.userId) : false;
  if (!deleted) throw billNotFound();
  return { status: 200, body: { id: billId, deleted: true } };
}

/** Gives the bill a new link and QR, and the old link stops working. For a link that was shared too widely. */
export async function rotateBillToken(req: AuthedRequest, billId: string): Promise<Response> {
  const bill = await requireOwnBill(req, billId);
  const updated = await repo.rotateToken(bill._id, req.caller.userId, newToken());
  if (!updated) throw billNotFound();
  return { status: 200, body: await hostView(req, updated) };
}

/** The host ticking their own lines (guest "host"), fixing a guest's ticks, or marking a cash payment. */
export async function updateGuestAsHost(req: AuthedRequest, billId: string, guestId: string): Promise<Response> {
  const bill = await requireOwnBill(req, billId);
  const input = GuestUpdateDto.parse(req.body);
  requireGuest(bill, guestId);

  const updated = await writeGuest(
    bill,
    guestId,
    input,
    (changes, options) => repo.updateGuestAsHost(bill._id, req.caller.userId, guestId, changes, options),
    async () => requireGuest(await requireOwnBill(req, billId), guestId),
  );
  return { status: 200, body: await hostView(req, updated) };
}

/** Removes a guest. Their browser can't rejoin with the same id, but their name is free for someone new. */
export async function removeGuest(req: AuthedRequest, billId: string, guestId: string): Promise<Response> {
  const bill = await requireOwnBill(req, billId);
  if (guestId === HOST_GUEST_ID) {
    throw badRequest('CANNOT_REMOVE_HOST', 'The host cannot be removed');
  }

  const updated = await repo.removeGuest(bill._id, req.caller.userId, guestId);
  if (!updated) throw guestNotFound();
  return { status: 200, body: await hostView(req, updated) };
}

// Guest routes, public: the link token is the only key

async function requireBillByToken(token: string): Promise<BillDoc> {
  const bill = TOKEN_RE.test(token) ? await repo.findBillByToken(token) : null;
  if (!bill) throw billNotFound();

  const ageMs = Date.now() - bill.createdAt.getTime();
  if (ageMs > BILL_LINK_TTL_DAYS * DAY_MS) {
    throw gone('BILL_EXPIRED', 'This bill link has expired');
  }
  return bill;
}

/** The bill behind a share link, as guests see it. */
export async function getBillByToken(token: string): Promise<Response> {
  const bill = await requireBillByToken(token);
  return { status: 200, body: await guestView(bill) };
}

/**
 * Adds a guest from the web page. The browser picks its own guest id and secret, so a retried join
 * finds the guest it already created, as long as the secret matches.
 */
export async function joinBill(req: Request, token: string): Promise<Response> {
  const bill = await requireBillByToken(token);
  const input = JoinBillDto.parse(req.body);
  const secretHash = hashSecret(input.secret);
  const nameKey = nameKeyOf(input.name);

  // Why this join can't go ahead, most specific reason first. Null when nothing stands in the way.
  const refusal = (current: BillDoc): AppError | null => {
    if (current.removedGuestIds?.includes(input.guestId)) {
      return conflict('GUEST_REMOVED', 'The host removed you from this bill');
    }
    if (current.status === 'CLOSED') return billClosed();
    const nameTaken = current.guests.some(
      (guest) => guest.id !== input.guestId && (guest.nameKey ?? nameKeyOf(guest.name)) === nameKey,
    );
    if (nameTaken) return conflict('NAME_TAKEN', 'Someone on this bill already has that name');
    return null;
  };

  // A retried join skips these checks and finds itself below. A new guest is checked here as well as in
  // the atomic write, because the write's filter only sees names stored with a nameKey.
  const isRetry = bill.guests.some((guest) => guest.id === input.guestId);
  if (!isRetry) {
    const reason = refusal(bill);
    if (reason) throw reason;
  }

  const now = new Date();
  const guest: BillGuestDoc = {
    id: input.guestId,
    name: input.name,
    nameKey,
    isHost: false,
    secretHash,
    itemIds: [],
    paidCents: 0,
    joinedAt: now,
    updatedAt: now,
  };
  const after = await repo.addGuest(token, guest, MAX_GUESTS);
  const joined = after?.guests.find((g) => g.id === input.guestId);
  if (after && joined) {
    // Either we just joined, or this retries a join that already went through. The secret must match.
    if (!sameHash(joined.secretHash, secretHash)) throw conflict('GUEST_ID_TAKEN', 'Try joining again');
    return { status: 201, body: { guestId: joined.id, bill: await guestView(after) } };
  }

  // The write didn't happen. Say why, checking the bill as it is now.
  const reason = refusal(after ?? bill);
  throw reason ?? conflict('BILL_FULL', `A bill can have at most ${MAX_GUESTS} people`);
}

/**
 * A guest changing their own ticks or paid mark. The x-guest-secret header proves who they are, and
 * a wrong secret looks exactly like a missing guest.
 */
export async function updateGuestByToken(req: Request, token: string, guestId: string): Promise<Response> {
  const secretHash = hashSecret(req.header('x-guest-secret') ?? '');
  // Parsed now but reported after the guest and secret check out.
  const parsed = GuestUpdateDto.safeParse(req.body);
  const changesTicks = parsed.success && parsed.data.itemIds !== undefined;

  // Runs again before every retry in writeGuest.
  const loadBill = async () => {
    const bill = await requireBillByToken(token);
    const guest = bill.guests.find((g) => g.id === guestId && !g.isHost);
    if (!guest || !sameHash(guest.secretHash, secretHash)) throw guestNotFound();
    if (changesTicks && bill.status === 'CLOSED') throw billClosed();
    return bill;
  };

  const bill = await loadBill();
  if (!parsed.success) throw parsed.error;

  const updated = await writeGuest(
    bill,
    guestId,
    parsed.data,
    (changes, options) => repo.updateGuestBySecret(token, guestId, secretHash, changes, options),
    loadBill,
  );
  return { status: 200, body: await guestView(updated) };
}
