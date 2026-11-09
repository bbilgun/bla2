import { createHash, randomBytes, randomInt, randomUUID, timingSafeEqual } from 'node:crypto';
import { computeBill } from '../domain/bill';
import { badRequest, conflict, notFound } from '../domain/errors';
import { BillContentDto, BillStatusDto, GuestUpdateDto, JoinBillDto, ReceiptUploadDto } from '../dto';
import type { AuthedRequest, Request, Response } from '../lib/http';
import { IMAGE_EXTENSIONS, signUpload, signView, UPLOAD_TTL_SECONDS } from '../lib/s3';
import { toObjectId, type BillDoc, type BillGuestDoc, type BillItemDoc } from '../repositories/collections';
import * as repo from '../repositories/bills';
import { upsertUser } from '../repositories/users';
import { idempotent } from './idempotency';

/**
 * QR bill splitting.
 *
 *   Host (app, signed in)        creates a bill: lines + where to pay. Gets a link + QR.
 *   Guests (browser, no account) open the link, type a name, tick what they had, see what they owe,
 *                                pay the host by bank transfer, tap "I paid".
 *
 * Totals are never stored: every response recomputes them from lines and ticks (domain/bill.ts).
 */

export const MAX_GUESTS = 50;
export const HOST_GUEST_ID = 'host';
const TOKEN_RE = /^[A-Za-z0-9_-]{22}$/;
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; // no 0/O, 1/I/L: it gets typed into bank apps

const newToken = () => randomBytes(16).toString('base64url'); // 128 bits, 22 chars
const newItemId = () => randomBytes(6).toString('base64url');
const newCode = () => Array.from({ length: 6 }, () => CODE_ALPHABET[randomInt(CODE_ALPHABET.length)]).join('');
const hashSecret = (secret: string) => createHash('sha256').update(secret).digest('hex');

function sameHash(a: string | null, b: string): boolean {
  if (!a || a.length !== b.length) return false;
  return timingSafeEqual(Buffer.from(a), Buffer.from(b));
}

const billNotFound = () => notFound('BILL_NOT_FOUND', 'Bill not found');
const billClosed = () => conflict('BILL_CLOSED', 'This bill is closed');

// ---------------------------------------------------------------- views

/** What both the host and the guests see. Secrets never leave the server. */
function baseView(bill: BillDoc, hasPayQr: boolean) {
  const b = computeBill(bill.items, bill.guests);
  const guests = bill.guests.map((g) => ({
    id: g.id,
    name: g.name,
    isHost: g.isHost,
    paid: g.paid,
    itemIds: g.itemIds,
    totalCents: b.guestTotals.get(g.id) ?? 0,
  }));
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
    paidCents: others.filter((g) => g.paid).reduce((acc, g) => acc + g.totalCents, 0),
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

function checkItemIds(bill: BillDoc, itemIds: readonly string[] | undefined): string[] | undefined {
  if (itemIds === undefined) return undefined;
  const known = new Set(bill.items.map((i) => i.id));
  const unknown = itemIds.filter((id) => !known.has(id));
  if (unknown.length > 0) throw badRequest('UNKNOWN_ITEM', 'Some items are not on this bill', { itemIds: unknown });
  return [...new Set(itemIds)];
}

/**
 * Changing your ticks changes what you owe, so a "paid" mark no longer means anything: it is cleared,
 * unless the same request sets it explicitly.
 */
function changesFor(guest: BillGuestDoc, itemIds: string[] | undefined, paid: boolean | undefined): repo.GuestChanges {
  const changes: repo.GuestChanges = {};
  if (itemIds !== undefined) {
    changes.itemIds = itemIds;
    const before = new Set(guest.itemIds);
    const changed = itemIds.length !== before.size || itemIds.some((id) => !before.has(id));
    if (changed && guest.paid) changes.paid = false;
  }
  if (paid !== undefined) changes.paid = paid;
  return changes;
}

export async function createBill(req: AuthedRequest): Promise<Response> {
  const input = BillContentDto.parse(req.body);
  await upsertUser(req.caller);

  return idempotent(req, async (resourceId) => {
    const now = new Date();
    const host: BillGuestDoc = {
      id: HOST_GUEST_ID,
      name: req.caller.name,
      isHost: true,
      secretHash: null,
      itemIds: [],
      paid: false,
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
  const docs = await repo.listBillsForHost(req.caller.userId, 50);
  return { status: 200, body: { items: docs.map(summaryView) } };
}

export async function getBill(req: AuthedRequest, billId: string): Promise<Response> {
  return { status: 200, body: await hostView(req, await requireOwnBill(req, billId)) };
}

/** Full replace of title, currency, lines and payment. Naturally idempotent: same body, same result. */
export async function updateBill(req: AuthedRequest, billId: string): Promise<Response> {
  const bill = await requireOwnBill(req, billId);
  const input = BillContentDto.parse(req.body);
  const updated = await repo.replaceContent(bill._id, req.caller.userId, {
    title: input.title,
    currency: input.currency,
    items: withItemIds(input.items, bill.items),
    payment: input.payment,
  });
  if (!updated) throw billNotFound();
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

/** The host ticking their own lines (guest "host"), fixing a guest's ticks, or marking a cash payment. */
export async function hostUpdateGuest(req: AuthedRequest, billId: string, guestId: string): Promise<Response> {
  const bill = await requireOwnBill(req, billId);
  const input = GuestUpdateDto.parse(req.body);
  const guest = bill.guests.find((g) => g.id === guestId);
  if (!guest) throw notFound('GUEST_NOT_FOUND', 'Guest not found');
  const changes = changesFor(guest, checkItemIds(bill, input.itemIds), input.paid);
  const updated = await repo.updateGuestAsHost(bill._id, req.caller.userId, guestId, changes);
  if (!updated) throw notFound('GUEST_NOT_FOUND', 'Guest not found');
  return { status: 200, body: await hostView(req, updated) };
}

export async function removeGuest(req: AuthedRequest, billId: string, guestId: string): Promise<Response> {
  const bill = await requireOwnBill(req, billId);
  if (guestId === HOST_GUEST_ID) throw badRequest('CANNOT_REMOVE_HOST', 'The host cannot be removed');
  const updated = await repo.removeGuest(bill._id, req.caller.userId, guestId);
  if (!updated) throw notFound('GUEST_NOT_FOUND', 'Guest not found');
  return { status: 200, body: await hostView(req, updated) };
}

/** Presigned PUT for a screenshot of the host's bank-app "receive money" QR. Shown on every bill. */
export async function createPayQrUploadUrl(req: AuthedRequest): Promise<Response> {
  const { contentType } = ReceiptUploadDto.parse(req.body);
  await upsertUser(req.caller);
  const key = `users/${req.caller.userId}/pay-qr/${randomUUID()}.${IMAGE_EXTENSIONS[contentType]}`;
  const uploadUrl = await signUpload(key, contentType);
  await repo.setPayQrKey(req.caller.userId, key);
  return {
    status: 200,
    body: { uploadUrl, method: 'PUT', headers: { 'content-type': contentType }, key, expiresIn: UPLOAD_TTL_SECONDS },
  };
}

// ---------------------------------------------------------------- guests (public, by link token)

async function requireBillByToken(token: string): Promise<BillDoc> {
  const bill = TOKEN_RE.test(token) ? await repo.findBillByToken(token) : null;
  if (!bill) throw billNotFound();
  return bill;
}

export async function guestGetBill(token: string): Promise<Response> {
  return { status: 200, body: await guestView(await requireBillByToken(token)) };
}

export async function guestJoin(req: Request, token: string): Promise<Response> {
  const bill = await requireBillByToken(token);
  const input = JoinBillDto.parse(req.body);
  const secretHash = hashSecret(input.secret);
  const now = new Date();

  const after = await repo.addGuest(
    token,
    {
      id: input.guestId,
      name: input.name,
      isHost: false,
      secretHash,
      itemIds: [],
      paid: false,
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
  if ((after ?? bill).status === 'CLOSED') throw billClosed();
  throw conflict('BILL_FULL', `A bill can have at most ${MAX_GUESTS} people`);
}

export async function guestUpdate(req: Request, token: string, guestId: string): Promise<Response> {
  const bill = await requireBillByToken(token);
  const secret = req.header('x-guest-secret') ?? '';
  const secretHash = hashSecret(secret);
  const guest = bill.guests.find((g) => g.id === guestId && !g.isHost);
  // A wrong secret looks exactly like a missing guest.
  if (!guest || !sameHash(guest.secretHash, secretHash)) throw notFound('GUEST_NOT_FOUND', 'Guest not found');

  const input = GuestUpdateDto.parse(req.body);
  if (input.itemIds !== undefined && bill.status === 'CLOSED') throw billClosed();
  const changes = changesFor(guest, checkItemIds(bill, input.itemIds), input.paid);

  const updated = await repo.updateGuestBySecret(token, guestId, secretHash, changes);
  if (!updated) {
    // Closed or removed between our read and the write.
    const now = await requireBillByToken(token);
    if (input.itemIds !== undefined && now.status === 'CLOSED') throw billClosed();
    throw notFound('GUEST_NOT_FOUND', 'Guest not found');
  }
  return { status: 200, body: await guestView(updated) };
}
