import type { ObjectId } from 'mongodb';
import { expenses, isDuplicateKeyError, type ExpenseDoc } from './collections';

/**
 * Insert with a caller-chosen _id. If that _id already exists (a retry of the same idempotent
 * request), return the stored document instead of writing a second one.
 */
export async function insertExpenseOnce(doc: ExpenseDoc): Promise<ExpenseDoc> {
  const col = await expenses();
  try {
    await col.insertOne(doc);
    return doc;
  } catch (err) {
    if (!isDuplicateKeyError(err)) throw err;
    const existing = await col.findOne({ _id: doc._id });
    if (!existing) throw err;
    return existing;
  }
}

/**
 * Cursor pagination, newest first. `cursor` is the last _id the client saw.
 * Unlike skip(n), which walks past n documents every time, `_id < cursor` is a single index seek,
 * so page 500 costs the same as page 1.
 */
export async function listExpenses(
  groupId: ObjectId,
  opts: { limit: number; cursor?: ObjectId },
): Promise<{ items: ExpenseDoc[]; nextCursor: string | null }> {
  const filter = opts.cursor ? { groupId, _id: { $lt: opts.cursor } } : { groupId };
  const docs = await (await expenses())
    .find(filter)
    .sort({ _id: -1 })
    .limit(opts.limit + 1)
    .toArray();
  const hasMore = docs.length > opts.limit;
  const items = hasMore ? docs.slice(0, opts.limit) : docs;
  return { items, nextCursor: hasMore ? items[items.length - 1]!._id.toHexString() : null };
}

export async function findExpense(groupId: ObjectId, expenseId: ObjectId): Promise<ExpenseDoc | null> {
  return (await expenses()).findOne({ _id: expenseId, groupId });
}

export async function setReceiptKey(groupId: ObjectId, expenseId: ObjectId, key: string): Promise<void> {
  await (await expenses()).updateOne({ _id: expenseId, groupId }, { $set: { receiptKey: key } });
}
