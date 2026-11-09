import { MongoServerError, ObjectId, type Collection, type Filter, type OptionalUnlessRequiredId } from 'mongodb';
import type { SplitType } from '../domain/split';
import { getDb } from './db';

/** Document shapes as stored in MongoDB. Every amount is an integer number of cents. */

export interface PaymentInfo {
  bankName: string;
  accountNumber: string;
  accountName: string;
}

export interface UserDoc {
  _id: string; // Cognito sub
  email: string;
  name: string;
  /** Last bank details used on a bill: pre-fills the next one. */
  payment?: PaymentInfo;
  /** S3 key of a screenshot of the user's own bank-app "receive money" QR, shown to bill guests. */
  payQrKey?: string;
  createdAt: Date;
  updatedAt: Date;
}

export interface MemberDoc {
  userId: string;
  /** Snapshots from the member's token, refreshed by GET /me when they change. */
  email: string;
  name: string;
  joinedAt: Date;
}

/** A pending invite. Matched against the invitee's verified email, so it works before they sign up. */
export interface InviteDoc {
  id: string;
  email: string;
  invitedBy: string;
  invitedByName: string;
  createdAt: Date;
}

export interface GroupDoc {
  _id: ObjectId;
  name: string;
  currency: string;
  members: MemberDoc[]; // embedded: always read with the group, small and bounded
  /** Missing on groups created before invites existed. Members + invites <= MAX_GROUP_SIZE. */
  invites?: InviteDoc[];
  createdBy: string;
  createdAt: Date;
  updatedAt?: Date;
  /** Soft delete: a deleted group behaves exactly like a missing one. */
  deletedAt?: Date;
  deletedBy?: string;
}

export interface ExpenseContent {
  description: string;
  amountCents: number;
  paidBy: string;
  splitType: SplitType;
  splits: { userId: string; amountCents: number }[]; // embedded: computed once by the server
}

/** A replaced version of an expense, plus who replaced it and when. */
export interface ExpenseVersionDoc extends ExpenseContent {
  version: number;
  changedBy: string;
  changedAt: Date;
}

export interface ExpenseDoc extends ExpenseContent {
  _id: ObjectId;
  groupId: ObjectId;
  /** 1 on create, +1 on every edit. Missing on expenses created before edits existed (= 1). */
  version?: number;
  receiptKey?: string;
  createdBy: string;
  createdAt: Date;
  updatedAt?: Date;
  updatedBy?: string;
  /** The last MAX_EXPENSE_HISTORY versions, oldest first. Never sent to the app. */
  history?: ExpenseVersionDoc[];
  deletedAt?: Date;
  deletedBy?: string;
}

export interface SettlementDoc {
  _id: ObjectId;
  groupId: ObjectId;
  fromUserId: string;
  toUserId: string;
  amountCents: number;
  createdBy: string;
  createdAt: Date;
  deletedAt?: Date;
  deletedBy?: string;
}

export interface BillItemDoc {
  id: string;
  name: string;
  priceCents: number;
}

export interface BillGuestDoc {
  id: string;
  name: string;
  /** Lower-cased, trimmed name: no two people on a bill share one, so transfer notes stay distinguishable. */
  nameKey?: string;
  /** The host is a guest too (id "host"), so their own share of the food is counted like anyone's. */
  isHost: boolean;
  /** sha256 of the secret only the guest's browser knows. Null for the host, who uses their login. */
  secretHash: string | null;
  itemIds: string[];
  /** What the guest marked as paid (the amount they saw and transferred). 0 = not marked. */
  paidCents?: number;
  /** Legacy flag from before paidCents. `paid: true` without paidCents reads as "paid their current total". */
  paid?: boolean;
  joinedAt: Date;
  updatedAt: Date;
}

/** A one-off bill. Guests are embedded: bounded (max 50) and always read with the bill. */
export interface BillDoc {
  _id: ObjectId;
  hostUserId: string;
  hostName: string;
  /** Unguessable, in the share link and QR. Anyone holding it can see the bill and join. */
  token: string;
  /** Short human code for the bank transfer note ("NZ-7KQ2HM Бат"). */
  code: string;
  title: string;
  currency: string;
  items: BillItemDoc[];
  guests: BillGuestDoc[];
  /** Guest ids the host removed: those browsers can't silently re-join (capped). */
  removedGuestIds?: string[];
  payment: PaymentInfo | null;
  status: 'OPEN' | 'CLOSED';
  createdAt: Date;
  updatedAt: Date;
}

export interface IdempotencyDoc {
  _id: ObjectId;
  userId: string;
  key: string;
  requestHash: string;
  /** The _id the write will use. Retries reuse it, so the write itself is insert-or-fetch. */
  resourceId: ObjectId;
  status: 'pending' | 'done';
  response?: { status: number; body: unknown };
  createdAt: Date;
}

export const users = async (): Promise<Collection<UserDoc>> => (await getDb()).collection<UserDoc>('users');
export const groups = async (): Promise<Collection<GroupDoc>> => (await getDb()).collection<GroupDoc>('groups');
export const expenses = async (): Promise<Collection<ExpenseDoc>> => (await getDb()).collection<ExpenseDoc>('expenses');
export const settlements = async (): Promise<Collection<SettlementDoc>> =>
  (await getDb()).collection<SettlementDoc>('settlements');
export const bills = async (): Promise<Collection<BillDoc>> => (await getDb()).collection<BillDoc>('bills');
export const idempotencyKeys = async (): Promise<Collection<IdempotencyDoc>> =>
  (await getDb()).collection<IdempotencyDoc>('idempotency_keys');

export function isDuplicateKeyError(err: unknown): boolean {
  return err instanceof MongoServerError && err.code === 11000;
}

/** Parses a path id; anything malformed is treated as "doesn't exist". */
export function toObjectId(id: string): ObjectId | null {
  return /^[a-f0-9]{24}$/.test(id) ? new ObjectId(id) : null;
}

/** Filter fragment for soft-deleted collections: only live documents. */
export const NOT_DELETED = { deletedAt: { $exists: false } } as const;

/**
 * Insert with a caller-chosen _id. If that _id already exists (a retry of the same idempotent request),
 * return the stored document instead of writing a second one. This is what makes `idempotent()` safe
 * to re-run after a crash: see services/idempotency.ts.
 */
export async function insertOnce<T extends { _id: ObjectId }>(col: Collection<T>, doc: T): Promise<T> {
  try {
    await col.insertOne(doc as OptionalUnlessRequiredId<T>);
    return doc;
  } catch (err) {
    if (!isDuplicateKeyError(err)) throw err;
    const existing = await col.findOne({ _id: doc._id } as Filter<T>);
    if (!existing) throw err; // the clash was on another unique index (e.g. a bill token): let it surface
    return existing as T;
  }
}

export interface Page<T> {
  items: T[];
  nextCursor: string | null;
}

/**
 * Cursor pagination, newest first. `cursor` is the last _id the client saw.
 * Unlike skip(n), which walks past n documents every time, `_id < cursor` is a single index seek,
 * so page 500 costs the same as page 1.
 */
export async function pageNewestFirst<T extends { _id: ObjectId }>(
  col: Collection<T>,
  filter: Filter<T>,
  opts: { limit: number; cursor?: ObjectId | undefined },
): Promise<Page<T>> {
  const query = (opts.cursor ? { $and: [filter, { _id: { $lt: opts.cursor } }] } : filter) as Filter<T>;
  const docs = (await col
    .find(query)
    .sort({ _id: -1 })
    .limit(opts.limit + 1)
    .toArray()) as T[];
  const hasMore = docs.length > opts.limit;
  const items = hasMore ? docs.slice(0, opts.limit) : docs;
  return { items, nextCursor: hasMore ? items[items.length - 1]!._id.toHexString() : null };
}
