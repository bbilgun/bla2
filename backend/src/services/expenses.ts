// Group expenses: create (idempotent), list, edit (compare-and-set on version) and soft delete.
// The server computes every split; the app only says how to split.
import { badRequest, conflict, notFound } from '../domain/errors';
import { cents } from '../domain/money';
import { computeSplit, splitUserIds } from '../domain/split';
import { CreateExpenseDto, PageQueryDto, UpdateExpenseDto } from '../dto';
import type { AuthedRequest, Response } from '../lib/http';
import { toObjectId } from '../repositories/collections';
import type { ExpenseContent, ExpenseDoc, ExpenseVersionDoc, GroupDoc } from '../repositories/documents';
import * as expensesRepo from '../repositories/expenses';
import { isMember, requireMembership } from './groups';
import { idempotent } from './idempotency';
import { expenseJson } from './serializers';

const expenseNotFound = () => notFound('EXPENSE_NOT_FOUND', 'Expense not found');
const expenseChanged = () => conflict('EXPENSE_CHANGED', 'Someone else changed this expense. Reload it and try again.');

// Checks everyone named is in the group, then computes every share.
function contentFor(group: GroupDoc, input: CreateExpenseDto): ExpenseContent {
  if (!isMember(group, input.paidBy)) {
    throw badRequest('PAYER_NOT_MEMBER', 'The person who paid must be in the group');
  }
  const outsiders = splitUserIds(input.split).filter((userId) => !isMember(group, userId));
  if (outsiders.length > 0) {
    throw badRequest('SPLIT_USER_NOT_MEMBER', 'Everyone in the split must be in the group', { userIds: outsiders });
  }

  return {
    description: input.description,
    amountCents: input.amountCents,
    paidBy: input.paidBy,
    splitType: input.split.type,
    splits: computeSplit(cents(input.amountCents), input.split),
  };
}

function sameContent(stored: ExpenseDoc, next: ExpenseContent): boolean {
  const sameSplits =
    stored.splits.length === next.splits.length &&
    stored.splits.every((share, i) => share.userId === next.splits[i]!.userId && share.amountCents === next.splits[i]!.amountCents);
  return (
    stored.description === next.description &&
    stored.amountCents === next.amountCents &&
    stored.paidBy === next.paidBy &&
    stored.splitType === next.splitType &&
    sameSplits
  );
}

/** Adds an expense to the group. Needs an Idempotency-Key, so a retried create writes it once. */
export async function createExpense(req: AuthedRequest, groupId: string): Promise<Response> {
  const group = await requireMembership(groupId, req.caller);
  const content = contentFor(group, CreateExpenseDto.parse(req.body));

  return idempotent(req, async (resourceId) => {
    const expense = await expensesRepo.insertExpenseOnce({
      _id: resourceId,
      groupId: group._id,
      ...content,
      version: 1,
      createdBy: req.caller.userId,
      createdAt: new Date(),
    });
    return { status: 201, body: expenseJson(expense) };
  });
}

/** One page of the group's expenses, newest first. */
export async function listExpenses(req: AuthedRequest, groupId: string): Promise<Response> {
  const group = await requireMembership(groupId, req.caller);
  const query = PageQueryDto.parse(req.query);
  const page = await expensesRepo.listExpenses(group._id, query);
  return { status: 200, body: { items: page.items.map(expenseJson), nextCursor: page.nextCursor } };
}

/**
 * Replaces an expense. Any member may edit any expense. The request carries the version it was based
 * on, and a stale version is 409 EXPENSE_CHANGED, unless the stored expense already matches the
 * request (our own earlier attempt went through), which is a 200.
 */
export async function updateExpense(req: AuthedRequest, groupId: string, expenseId: string): Promise<Response> {
  const group = await requireMembership(groupId, req.caller);
  const input = UpdateExpenseDto.parse(req.body);
  const id = toObjectId(expenseId);
  const expense = id ? await expensesRepo.findExpense(group._id, id) : null;
  if (!expense) throw expenseNotFound();
  const content = contentFor(group, input);

  if (sameContent(expense, content)) return { status: 200, body: expenseJson(expense) };
  const storedVersion = expense.version ?? 1;
  if (storedVersion !== input.version) throw expenseChanged();

  const previous: ExpenseVersionDoc = {
    version: storedVersion,
    description: expense.description,
    amountCents: expense.amountCents,
    paidBy: expense.paidBy,
    splitType: expense.splitType,
    splits: expense.splits,
    changedBy: req.caller.userId,
    changedAt: new Date(),
  };
  const updated = await expensesRepo.updateExpenseIfVersion(group._id, expense._id, input.version, content, previous);
  if (updated) return { status: 200, body: expenseJson(updated) };

  // Someone else wrote between our read and our write.
  const latest = await expensesRepo.findExpense(group._id, expense._id);
  if (!latest) throw expenseNotFound();
  if (sameContent(latest, content)) return { status: 200, body: expenseJson(latest) };
  throw expenseChanged();
}

/** Soft-deletes an expense: kept for history, gone from lists and balances. Deleting twice is fine. */
export async function deleteExpense(req: AuthedRequest, groupId: string, expenseId: string): Promise<Response> {
  const group = await requireMembership(groupId, req.caller);
  const id = toObjectId(expenseId);
  const expense = id ? await expensesRepo.findExpenseAnyState(group._id, id) : null;
  if (!expense) throw expenseNotFound();

  if (!expense.deletedAt) {
    await expensesRepo.softDeleteExpense(group._id, expense._id, req.caller.userId);
  }
  return { status: 200, body: { id: expense._id.toHexString(), deleted: true } };
}
