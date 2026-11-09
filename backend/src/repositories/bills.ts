// The bills collection. Lines and guests live inside the bill document, so every change to a guest is a
// single atomic update whose filter checks the rules (open, not full, right secret) at the moment of the write.
import type { Filter, ObjectId, UpdateFilter } from 'mongodb';
import { bills, insertOnce, pageNewestFirst, type Page, type PageOptions } from './collections';
import type { BillDoc, BillGuestDoc } from './documents';

/** How many removed guest ids a bill remembers. Guests themselves are capped at 50. */
const MAX_REMOVED_GUEST_IDS = 200;

/** Insert-or-fetch on the _id the idempotency key reserved (see services/idempotency.ts). */
export async function insertBillOnce(doc: BillDoc): Promise<BillDoc> {
  return insertOnce(await bills(), doc);
}

/** One page of the host's bills, newest first. */
export async function listBillsForHost(hostUserId: string, page: PageOptions): Promise<Page<BillDoc>> {
  return pageNewestFirst(await bills(), { hostUserId }, page);
}

/** The bill if `hostUserId` owns it, otherwise null. */
export async function findBillForHost(billId: ObjectId, hostUserId: string): Promise<BillDoc | null> {
  return (await bills()).findOne({ _id: billId, hostUserId });
}

/** The bill behind a share link, or null. */
export async function findBillByToken(token: string): Promise<BillDoc | null> {
  return (await bills()).findOne({ token });
}

/**
 * Replaces the editable content of an open bill. In the same update, ticks on lines that are gone are
 * removed from every guest, so nobody is charged for a deleted line. Null if the bill is closed or missing.
 */
export async function replaceContent(
  billId: ObjectId,
  hostUserId: string,
  content: Pick<BillDoc, 'title' | 'currency' | 'items' | 'payment'>,
): Promise<BillDoc | null> {
  const itemIds = content.items.map((item) => item.id);
  return (await bills()).findOneAndUpdate(
    { _id: billId, hostUserId, status: 'OPEN' },
    {
      $set: { ...content, updatedAt: new Date() },
      $pull: { 'guests.$[].itemIds': { $nin: itemIds } },
    },
    { returnDocument: 'after' },
  );
}

/** Opens or closes the bill. Null if the host doesn't own it. */
export async function setStatus(billId: ObjectId, hostUserId: string, status: BillDoc['status']): Promise<BillDoc | null> {
  return (await bills()).findOneAndUpdate(
    { _id: billId, hostUserId },
    { $set: { status, updatedAt: new Date() } },
    { returnDocument: 'after' },
  );
}

/** Gives the bill a new link token. The old link stops working at once. */
export async function rotateToken(billId: ObjectId, hostUserId: string, token: string): Promise<BillDoc | null> {
  return (await bills()).findOneAndUpdate(
    { _id: billId, hostUserId },
    { $set: { token, updatedAt: new Date() } },
    { returnDocument: 'after' },
  );
}

/** Deletes the bill for good. Returns whether there was one to delete. */
export async function deleteBill(billId: ObjectId, hostUserId: string): Promise<boolean> {
  const res = await (await bills()).deleteOne({ _id: billId, hostUserId });
  return res.deletedCount === 1;
}

/** Deletes every bill the user hosts. Used by account deletion. */
export async function deleteBillsForHost(hostUserId: string): Promise<void> {
  await (await bills()).deleteMany({ hostUserId });
}

/**
 * Adds a guest unless, at the moment of the write, one with that id is already there (a retried join),
 * someone already has that name, the host removed that id, or the bill is closed or full. Returns the
 * bill after the attempt either way; the caller works out which case it was.
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
      // No element at index maxGuests - 1 means fewer than maxGuests guests.
      [`guests.${maxGuests - 1}`]: { $exists: false },
    },
    { $push: { guests: guest }, $set: { updatedAt: new Date() } },
  );
  return col.findOne({ token });
}

/** What to change on one guest. Missing fields stay as they are. */
export interface GuestChanges {
  itemIds?: string[];
  paidCents?: number;
}

/** Options for a guest write. */
export interface GuestWriteOptions {
  /**
   * Only write if every ticked line is still on the bill. A host edit between our read and this write
   * makes it miss, and the service retries with the fresh lines.
   */
  requireItems: boolean;
}

// The guest is addressed with an array filter ($[g]) because `guests.$` would be ambiguous: the filter
// can also match on `items`.
function guestUpdate(changes: GuestChanges): UpdateFilter<BillDoc> {
  const now = new Date();
  const set: Record<string, unknown> = { 'guests.$[g].updatedAt': now, updatedAt: now };
  const update: Record<string, unknown> = { $set: set };

  if (changes.itemIds !== undefined) {
    set['guests.$[g].itemIds'] = changes.itemIds;
  }
  if (changes.paidCents !== undefined) {
    set['guests.$[g].paidCents'] = changes.paidCents;
    // The older `paid` flag gives way to the amount.
    update.$unset = { 'guests.$[g].paid': '' };
  }
  return update as UpdateFilter<BillDoc>;
}

function itemsGuard(changes: GuestChanges, options: GuestWriteOptions): Filter<BillDoc> {
  if (!options.requireItems || !changes.itemIds?.length) return {};
  return { 'items.id': { $all: changes.itemIds } };
}

/**
 * A guest changing their own ticks or paid amount. The filter matches the guest by id and secret hash,
 * so knowing someone's guest id, which everyone on the bill can see, isn't enough to edit them.
 * Ticks only change while the bill is open; marking paid still works after it's closed.
 */
export async function updateGuestBySecret(
  token: string,
  guestId: string,
  secretHash: string,
  changes: GuestChanges,
  options: GuestWriteOptions,
): Promise<BillDoc | null> {
  const filter: Filter<BillDoc> = {
    token,
    guests: { $elemMatch: { id: guestId, secretHash } },
    ...itemsGuard(changes, options),
  };
  if (changes.itemIds !== undefined) {
    filter.status = 'OPEN';
  }

  return (await bills()).findOneAndUpdate(filter, guestUpdate(changes), {
    returnDocument: 'after',
    arrayFilters: [{ 'g.id': guestId }],
  });
}

/** The host fixing anyone's ticks or marking a cash payment. Works on closed bills too. */
export async function updateGuestAsHost(
  billId: ObjectId,
  hostUserId: string,
  guestId: string,
  changes: GuestChanges,
  options: GuestWriteOptions,
): Promise<BillDoc | null> {
  return (await bills()).findOneAndUpdate(
    { _id: billId, hostUserId, 'guests.id': guestId, ...itemsGuard(changes, options) },
    guestUpdate(changes),
    { returnDocument: 'after', arrayFilters: [{ 'g.id': guestId }] },
  );
}

/** Removes a guest and remembers the id, so that browser is told GUEST_REMOVED if it tries to rejoin. */
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
