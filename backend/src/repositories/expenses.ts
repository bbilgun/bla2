// The expenses collection. Expenses are soft-deleted, and edits are compare-and-set on `version`.
import type { ObjectId } from 'mongodb';
import { expenses, insertOnce, NOT_DELETED, pageNewestFirst, type Page, type PageOptions } from './collections';
import type { ExpenseContent, ExpenseDoc, ExpenseVersionDoc } from './documents';

/** How many replaced versions an expense keeps. Older ones fall off. */
export const MAX_EXPENSE_HISTORY = 20;

/** Insert-or-fetch on the _id the idempotency key reserved (see services/idempotency.ts). */
export async function insertExpenseOnce(doc: ExpenseDoc): Promise<ExpenseDoc> {
  return insertOnce(await expenses(), doc);
}

/** One page of the group's live expenses, newest first. */
export async function listExpenses(groupId: ObjectId, page: PageOptions): Promise<Page<ExpenseDoc>> {
  return pageNewestFirst(await expenses(), { groupId, ...NOT_DELETED }, page);
}

/** A live expense in the group, or null. A deleted expense looks missing everywhere. */
export async function findExpense(groupId: ObjectId, expenseId: ObjectId): Promise<ExpenseDoc | null> {
  return (await expenses()).findOne({ _id: expenseId, groupId, ...NOT_DELETED });
}

/** An expense in the group, deleted or not. DELETE uses it to answer a repeated delete with 200. */
export async function findExpenseAnyState(groupId: ObjectId, expenseId: ObjectId): Promise<ExpenseDoc | null> {
  return (await expenses()).findOne({ _id: expenseId, groupId });
}

// Expenses without a `version` field are version 1.
function atVersion(version: number) {
  if (version === 1) return { $or: [{ version: 1 }, { version: { $exists: false } }] };
  return { version };
}

/**
 * Replaces the content only if the stored version is still `expectedVersion`, and bumps it. Every edit
 * bumps the version, so a match also means the stored content is exactly `previous`, which goes into
 * the history. Null when someone else got there first or the expense was deleted.
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

/** Marks a live expense deleted. Does nothing if it already is. */
export async function softDeleteExpense(groupId: ObjectId, expenseId: ObjectId, userId: string): Promise<void> {
  await (await expenses()).updateOne(
    { _id: expenseId, groupId, ...NOT_DELETED },
    { $set: { deletedAt: new Date(), deletedBy: userId } },
  );
}

/** Saves a confirmed receipt key on a live expense. Returns the expense as it was before, or null if it's gone. */
export async function setReceiptKey(groupId: ObjectId, expenseId: ObjectId, key: string): Promise<ExpenseDoc | null> {
  return (await expenses()).findOneAndUpdate(
    { _id: expenseId, groupId, ...NOT_DELETED },
    { $set: { receiptKey: key } },
    { returnDocument: 'before' },
  );
}
