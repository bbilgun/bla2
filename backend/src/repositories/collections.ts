// Typed handles to each collection, plus the small query helpers the repositories share.
import { MongoServerError, ObjectId, type Collection, type Filter, type OptionalUnlessRequiredId } from 'mongodb';
import { getDb } from './db';
import type { BillDoc, ExpenseDoc, GroupDoc, IdempotencyDoc, SettlementDoc, UserDoc } from './documents';

/** Users, keyed by Cognito sub. */
export async function users(): Promise<Collection<UserDoc>> {
  return (await getDb()).collection<UserDoc>('users');
}

/** Groups, with their members and invites embedded. */
export async function groups(): Promise<Collection<GroupDoc>> {
  return (await getDb()).collection<GroupDoc>('groups');
}

/** Expenses, one document each, pointing at their group. */
export async function expenses(): Promise<Collection<ExpenseDoc>> {
  return (await getDb()).collection<ExpenseDoc>('expenses');
}

/** Settlements (recorded payments), one document each, pointing at their group. */
export async function settlements(): Promise<Collection<SettlementDoc>> {
  return (await getDb()).collection<SettlementDoc>('settlements');
}

/** QR bills, with their lines and guests embedded. */
export async function bills(): Promise<Collection<BillDoc>> {
  return (await getDb()).collection<BillDoc>('bills');
}

/** Idempotency keys for money writes. A TTL index removes them after 7 days. */
export async function idempotencyKeys(): Promise<Collection<IdempotencyDoc>> {
  return (await getDb()).collection<IdempotencyDoc>('idempotency_keys');
}

/** Whether a write failed on a unique index. */
export function isDuplicateKeyError(err: unknown): boolean {
  return err instanceof MongoServerError && err.code === 11000;
}

/** Parses an id from a URL. Anything malformed comes back null and is treated as "doesn't exist". */
export function toObjectId(id: string): ObjectId | null {
  if (!/^[a-f0-9]{24}$/.test(id)) return null;
  return new ObjectId(id);
}

/** Filter fragment that keeps only documents that haven't been soft-deleted. */
export const NOT_DELETED = { deletedAt: { $exists: false } } as const;

/**
 * Inserts `doc` with its own _id, or returns the document already stored under that _id. A retry of
 * the same idempotent request therefore never writes twice (see services/idempotency.ts).
 */
export async function insertOnce<T extends { _id: ObjectId }>(col: Collection<T>, doc: T): Promise<T> {
  try {
    await col.insertOne(doc as OptionalUnlessRequiredId<T>);
    return doc;
  } catch (err) {
    if (!isDuplicateKeyError(err)) throw err;
    const existing = await col.findOne({ _id: doc._id } as Filter<T>);
    // The clash was on another unique index, such as a bill token. Let it surface.
    if (!existing) throw err;
    return existing as T;
  }
}

/** Which page of a newest-first list to read. `cursor` is the last _id of the previous page. */
export interface PageOptions {
  limit: number;
  cursor?: ObjectId | undefined;
}

/** One page of a list. `nextCursor` is null on the last page. */
export interface Page<T> {
  items: T[];
  nextCursor: string | null;
}

/**
 * Reads one page of `filter`, newest first, starting after the cursor. Seeking with `_id < cursor`
 * costs the same on page 500 as on page 1, unlike skip().
 */
export async function pageNewestFirst<T extends { _id: ObjectId }>(
  col: Collection<T>,
  filter: Filter<T>,
  page: PageOptions,
): Promise<Page<T>> {
  const query = page.cursor ? { $and: [filter, { _id: { $lt: page.cursor } }] } : filter;
  // One extra document tells us whether there's another page.
  const docs = await col
    .find(query as Filter<T>)
    .sort({ _id: -1 })
    .limit(page.limit + 1)
    .toArray();

  const items = docs.slice(0, page.limit) as T[];
  const hasMore = docs.length > page.limit;
  const last = items.at(-1);
  const nextCursor = hasMore && last ? last._id.toHexString() : null;
  return { items, nextCursor };
}
