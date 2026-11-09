import type { ObjectId } from 'mongodb';
import { bills, isDuplicateKeyError, users, type BillDoc, type BillGuestDoc, type PaymentInfo } from './collections';

/** Insert with the idempotency key's resourceId; a retry of the same create returns the stored bill. */
export async function insertBillOnce(doc: BillDoc): Promise<BillDoc> {
  const col = await bills();
  try {
    await col.insertOne(doc);
    return doc;
  } catch (err) {
    if (!isDuplicateKeyError(err)) throw err;
    const existing = await col.findOne({ _id: doc._id });
    if (!existing) throw err; // the clash was on the token: astronomically unlikely, let it surface
    return existing;
  }
}

export async function listBillsForHost(hostUserId: string, limit: number): Promise<BillDoc[]> {
  return (await bills()).find({ hostUserId }).sort({ _id: -1 }).limit(limit).toArray();
}

export async function findBillForHost(billId: ObjectId, hostUserId: string): Promise<BillDoc | null> {
  return (await bills()).findOne({ _id: billId, hostUserId });
}

export async function findBillByToken(token: string): Promise<BillDoc | null> {
  return (await bills()).findOne({ token });
}

/**
 * Replaces the editable content. In the same atomic update, ticks on lines that no longer exist
 * are removed from every guest, so no one is ever charged for a deleted line.
 */
export async function replaceContent(
  billId: ObjectId,
  hostUserId: string,
  content: Pick<BillDoc, 'title' | 'currency' | 'items' | 'payment'>,
): Promise<BillDoc | null> {
  const itemIds = content.items.map((i) => i.id);
  return (await bills()).findOneAndUpdate(
    { _id: billId, hostUserId },
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

/**
 * Adds a guest unless one with that id is already there (a retried join) or the bill is closed or full.
 * Returns the bill after the attempt either way; the caller checks which case it was.
 */
export async function addGuest(token: string, guest: BillGuestDoc, maxGuests: number): Promise<BillDoc | null> {
  const col = await bills();
  await col.updateOne(
    {
      token,
      status: 'OPEN',
      'guests.id': { $ne: guest.id },
      [`guests.${maxGuests - 1}`]: { $exists: false },
    },
    { $push: { guests: guest }, $set: { updatedAt: new Date() } },
  );
  return col.findOne({ token });
}

export interface GuestChanges {
  itemIds?: string[];
  paid?: boolean;
}

function guestSet(changes: GuestChanges, now: Date) {
  const set: Record<string, unknown> = { 'guests.$.updatedAt': now, updatedAt: now };
  if (changes.itemIds !== undefined) set['guests.$.itemIds'] = changes.itemIds;
  if (changes.paid !== undefined) set['guests.$.paid'] = changes.paid;
  return set;
}

/**
 * A guest changing their own ticks or paid flag. The filter matches the guest by id AND secret hash,
 * so knowing someone's guest id (it's visible to everyone on the bill) isn't enough to edit them.
 * Ticks can only change while the bill is open; marking paid still works after it's closed.
 */
export async function updateGuestBySecret(
  token: string,
  guestId: string,
  secretHash: string,
  changes: GuestChanges,
): Promise<BillDoc | null> {
  return (await bills()).findOneAndUpdate(
    {
      token,
      ...(changes.itemIds !== undefined && { status: 'OPEN' as const }),
      guests: { $elemMatch: { id: guestId, secretHash } },
    },
    { $set: guestSet(changes, new Date()) },
    { returnDocument: 'after' },
  );
}

/** The host fixing anyone's ticks, or marking a cash payment. Works on closed bills too. */
export async function updateGuestAsHost(
  billId: ObjectId,
  hostUserId: string,
  guestId: string,
  changes: GuestChanges,
): Promise<BillDoc | null> {
  return (await bills()).findOneAndUpdate(
    { _id: billId, hostUserId, 'guests.id': guestId },
    { $set: guestSet(changes, new Date()) },
    { returnDocument: 'after' },
  );
}

export async function removeGuest(billId: ObjectId, hostUserId: string, guestId: string): Promise<BillDoc | null> {
  return (await bills()).findOneAndUpdate(
    { _id: billId, hostUserId, guests: { $elemMatch: { id: guestId, isHost: false } } },
    { $pull: { guests: { id: guestId, isHost: false } }, $set: { updatedAt: new Date() } },
    { returnDocument: 'after' },
  );
}

export async function savePaymentProfile(userId: string, payment: PaymentInfo): Promise<void> {
  await (await users()).updateOne({ _id: userId }, { $set: { payment } });
}

export async function setPayQrKey(userId: string, key: string): Promise<void> {
  await (await users()).updateOne({ _id: userId }, { $set: { payQrKey: key } });
}

export async function findPayQrKey(userId: string): Promise<string | null> {
  const user = await (await users()).findOne({ _id: userId }, { projection: { payQrKey: 1 } });
  return user?.payQrKey ?? null;
}
