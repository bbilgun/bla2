import type { ObjectId } from 'mongodb';
import {
  expenses,
  insertOnce,
  NOT_DELETED,
  pageNewestFirst,
  type ExpenseContent,
  type ExpenseDoc,
  type ExpenseVersionDoc,
  type Page,
} from './collections';

/** How many replaced versions an expense keeps. Older ones fall off. */
export const MAX_EXPENSE_HISTORY = 20;

/** Insert-or-fetch on the idempotency key's resourceId (see services/idempotency.ts). */
export async function insertExpenseOnce(doc: ExpenseDoc): Promise<ExpenseDoc> {
  return insertOnce(await expenses(), doc);
}

/** Live expenses only, newest first. */
export async function listExpenses(
  groupId: ObjectId,
  opts: { limit: number; cursor?: ObjectId | undefined },
): Promise<Page<ExpenseDoc>> {
  return pageNewestFirst(await expenses(), { groupId, ...NOT_DELETED }, opts);
}

/** A live expense. Deleted ones look missing everywhere (edit, receipts). */
export async function findExpense(groupId: ObjectId, expenseId: ObjectId): Promise<ExpenseDoc | null> {
  return (await expenses()).findOne({ _id: expenseId, groupId, ...NOT_DELETED });
}

/** Deleted or not: DELETE uses it to answer a repeated delete with 200. */
export async function findExpenseAnyState(groupId: ObjectId, expenseId: ObjectId): Promise<ExpenseDoc | null> {
  return (await expenses()).findOne({ _id: expenseId, groupId });
}

/** Expenses created before versioning have no `version` field: they are version 1. */
const atVersion = (version: number) =>
  version === 1 ? { $or: [{ version: 1 }, { version: { $exists: false } }] } : { version };

/**
 * Compare-and-set: writes only if the stored version is still `expectedVersion`. Every edit bumps the
 * version, so a match also means the stored content is exactly `previous` (which goes into history).
 */
export async function updateExpenseIfVersion(
  groupId: ObjectId,
  expenseId: ObjectId,
  expectedVersion: number,
  content: ExpenseContent,
  previous: ExpenseVersionDoc,
): Promise<ExpenseDoc | null> {
  return (await expenses()).findOneAndUpdate(
    { _id: expenseId, groupId, ...NOT_DELETED, ...atVersion(expectedVersion) },
    {
      $set: {
        ...content,
        version: expectedVersion + 1,
        updatedAt: previous.changedAt,
        updatedBy: previous.changedBy,
      },
      $push: { history: { $each: [previous], $slice: -MAX_EXPENSE_HISTORY } },
    },
    { returnDocument: 'after' },
  );
}

export async function softDeleteExpense(groupId: ObjectId, expenseId: ObjectId, userId: string): Promise<void> {
  await (await expenses()).updateOne(
    { _id: expenseId, groupId, ...NOT_DELETED },
    { $set: { deletedAt: new Date(), deletedBy: userId } },
  );
}

/** Saves a confirmed receipt key on a live expense. Returns the expense before the change (null if gone). */
export async function setReceiptKey(groupId: ObjectId, expenseId: ObjectId, key: string): Promise<ExpenseDoc | null> {
  return (await expenses()).findOneAndUpdate(
    { _id: expenseId, groupId, ...NOT_DELETED },
    { $set: { receiptKey: key } },
    { returnDocument: 'before' },
  );
}
