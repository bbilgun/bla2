import type { Filter, ObjectId, UpdateFilter } from 'mongodb';
import { bills, insertOnce, pageNewestFirst, users, type BillDoc, type BillGuestDoc, type Page, type PaymentInfo } from './collections';

/** How many removed guest ids a bill remembers (the guests themselves are capped at 50). */
const MAX_REMOVED_GUEST_IDS = 200;

/** Insert-or-fetch on the idempotency key's resourceId (see services/idempotency.ts). */
export async function insertBillOnce(doc: BillDoc): Promise<BillDoc> {
  return insertOnce(await bills(), doc);
}

export async function listBillsForHost(
  hostUserId: string,
  opts: { limit: number; cursor?: ObjectId | undefined },
): Promise<Page<BillDoc>> {
  return pageNewestFirst(await bills(), { hostUserId }, opts);
}

export async function findBillForHost(billId: ObjectId, hostUserId: string): Promise<BillDoc | null> {
  return (await bills()).findOne({ _id: billId, hostUserId });
}

export async function findBillByToken(token: string): Promise<BillDoc | null> {
  return (await bills()).findOne({ token });
}

/**
 * Replaces the editable content of an OPEN bill (a closed one returns null: reopen it first). In the same
 * atomic update, ticks on lines that no longer exist are removed from every guest, so no one is ever
 * charged for a deleted line.
 */
export async function replaceContent(
  billId: ObjectId,
  hostUserId: string,
  content: Pick<BillDoc, 'title' | 'currency' | 'items' | 'payment'>,
): Promise<BillDoc | null> {
  const itemIds = content.items.map((i) => i.id);
  return (await bills()).findOneAndUpdate(
    { _id: billId, hostUserId, status: 'OPEN' },
    {
      $set: { ...content, updatedAt: new Date() },
      $pull: { 'guests.$[].itemIds': { $nin: itemIds } },
    },
    { returnDocument: 'after' },
  );
}

export async function setStatus(billId: ObjectId, hostUserId: string, status: BillDoc['status']): Promise<BillDoc | null> {
  return (await bills()).findOneAndUpdate(
    { _id: billId, hostUserId },
    { $set: { status, updatedAt: new Date() } },
    { returnDocument: 'after' },
  );
}

/** A new link token; the old link stops working at once. */
export async function rotateToken(billId: ObjectId, hostUserId: string, token: string): Promise<BillDoc | null> {
  return (await bills()).findOneAndUpdate(
    { _id: billId, hostUserId },
    { $set: { token, updatedAt: new Date() } },
    { returnDocument: 'after' },
  );
}

export async function deleteBill(billId: ObjectId, hostUserId: string): Promise<boolean> {
  return (await (await bills()).deleteOne({ _id: billId, hostUserId })).deletedCount === 1;
}

export async function deleteBillsForHost(hostUserId: string): Promise<void> {
  await (await bills()).deleteMany({ hostUserId });
}

/**
 * Adds a guest unless, at the moment of the write: one with that id is already there (a retried join),
 * someone already has that name, the host removed that id, or the bill is closed or full.
 * Returns the bill after the attempt either way; the caller checks which case it was.
 */
export async function addGuest(token: string, guest: BillGuestDoc, maxGuests: number): Promise<BillDoc | null> {
  const col = await bills();
  await col.updateOne(
    {
      token,
      status: 'OPEN',
      'guests.id': { $ne: guest.id },
      'guests.nameKey': { $ne: guest.nameKey },
      removedGuestIds: { $ne: guest.id },
      [`guests.${maxGuests - 1}`]: { $exists: false },
    },
    { $push: { guests: guest }, $set: { updatedAt: new Date() } },
  );
  return col.findOne({ token });
}

export interface GuestChanges {
  itemIds?: string[];
  paidCents?: number;
}

export interface GuestWriteOptions {
  /**
   * Only write if every ticked line is still on the bill. A host edit between our read and this write
   * makes it miss, and the service retries with the fresh lines instead of storing a dangling tick.
   */
  requireItems: boolean;
}

/** Guests are addressed with an array filter, not `guests.$`: the filter also looks at `items`, and `$` is ambiguous across two arrays. */
function guestUpdate(changes: GuestChanges): UpdateFilter<BillDoc> {
  const now = new Date();
  const set: Record<string, unknown> = { 'guests.$[g].updatedAt': now, updatedAt: now };
  const update: Record<string, unknown> = { $set: set };
  if (changes.itemIds !== undefined) set['guests.$[g].itemIds'] = changes.itemIds;
  if (changes.paidCents !== undefined) {
    set['guests.$[g].paidCents'] = changes.paidCents;
    update.$unset = { 'guests.$[g].paid': '' }; // the legacy flag is replaced by the amount
  }
  return update as UpdateFilter<BillDoc>;
}

function itemsGuard(changes: GuestChanges, opts: GuestWriteOptions): Filter<BillDoc> {
  if (!opts.requireItems || !changes.itemIds?.length) return {};
  return { 'items.id': { $all: changes.itemIds } };
}

/**
 * A guest changing their own ticks or paid amount. The filter matches the guest by id AND secret hash,
 * so knowing someone's guest id (it's visible to everyone on the bill) isn't enough to edit them.
 * Ticks can only change while the bill is open; marking paid still works after it's closed.
 */
export async function updateGuestBySecret(
  token: string,
  guestId: string,
  secretHash: string,
  changes: GuestChanges,
  opts: GuestWriteOptions,
): Promise<BillDoc | null> {
  return (await bills()).findOneAndUpdate(
    {
      token,
      ...(changes.itemIds !== undefined && { status: 'OPEN' as const }),
      guests: { $elemMatch: { id: guestId, secretHash } },
      ...itemsGuard(changes, opts),
    },
    guestUpdate(changes),
    { returnDocument: 'after', arrayFilters: [{ 'g.id': guestId }] },
  );
}

/** The host fixing anyone's ticks, or marking a cash payment. Works on closed bills too. */
export async function updateGuestAsHost(
  billId: ObjectId,
  hostUserId: string,
  guestId: string,
  changes: GuestChanges,
  opts: GuestWriteOptions,
): Promise<BillDoc | null> {
  return (await bills()).findOneAndUpdate(
    { _id: billId, hostUserId, 'guests.id': guestId, ...itemsGuard(changes, opts) },
    guestUpdate(changes),
    { returnDocument: 'after', arrayFilters: [{ 'g.id': guestId }] },
  );
}

/** Removes a guest and remembers the id, so that browser gets GUEST_REMOVED instead of quietly re-joining. */
export async function removeGuest(billId: ObjectId, hostUserId: string, guestId: string): Promise<BillDoc | null> {
  return (await bills()).findOneAndUpdate(
    { _id: billId, hostUserId, guests: { $elemMatch: { id: guestId, isHost: false } } },
    {
      $pull: { guests: { id: guestId, isHost: false } },
      $push: { removedGuestIds: { $each: [guestId], $slice: -MAX_REMOVED_GUEST_IDS } },
      $set: { updatedAt: new Date() },
    },
    { returnDocument: 'after' },
  );
}

export async function savePaymentProfile(userId: string, payment: PaymentInfo): Promise<void> {
  await (await users()).updateOne({ _id: userId }, { $set: { payment } });
}

export async function findPayQrKey(userId: string): Promise<string | null> {
  const user = await (await users()).findOne({ _id: userId }, { projection: { payQrKey: 1 } });
  return user?.payQrKey ?? null;
}
