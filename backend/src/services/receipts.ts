// Receipt photos on group expenses, uploaded straight to S3 in two steps (see services/uploads.ts).
// Membership is checked before any URL is signed.
import { notFound } from '../domain/errors';
import { ConfirmUploadDto, ImageUploadDto } from '../dto';
import type { AuthedRequest, Response } from '../lib/http';
import { signUpload, signView, VIEW_TTL_SECONDS } from '../lib/s3';
import { toObjectId } from '../repositories/collections';
import type { ExpenseDoc } from '../repositories/documents';
import { findExpense, setReceiptKey } from '../repositories/expenses';
import { requireMembership } from './groups';
import { expenseJson } from './serializers';
import { discardReplaced, newImageKey, requireUploadedKey } from './uploads';

const expenseNotFound = () => notFound('EXPENSE_NOT_FOUND', 'Expense not found');

// Every receipt for an expense lives under its own prefix, so a key can't be confirmed on the wrong expense.
function receiptPrefix(expense: ExpenseDoc): string {
  return `groups/${expense.groupId.toHexString()}/expenses/${expense._id.toHexString()}/`;
}

async function loadExpense(req: AuthedRequest, groupId: string, expenseId: string): Promise<ExpenseDoc> {
  const group = await requireMembership(groupId, req.caller);
  const id = toObjectId(expenseId);
  // A deleted expense looks missing.
  const expense = id ? await findExpense(group._id, id) : null;
  if (!expense) throw expenseNotFound();
  return expense;
}

/** Signs an upload under this expense's prefix. Nothing is saved until the app confirms. */
export async function createReceiptUploadUrl(req: AuthedRequest, groupId: string, expenseId: string): Promise<Response> {
  const expense = await loadExpense(req, groupId, expenseId);
  const { contentType } = ImageUploadDto.parse(req.body);
  const key = newImageKey(receiptPrefix(expense), contentType);
  return { status: 200, body: await signUpload(key, contentType) };
}

/** Saves an uploaded receipt on the expense and deletes the one it replaced. */
export async function confirmReceipt(req: AuthedRequest, groupId: string, expenseId: string): Promise<Response> {
  const expense = await loadExpense(req, groupId, expenseId);
  const { key } = ConfirmUploadDto.parse(req.body);
  await requireUploadedKey(key, receiptPrefix(expense));

  const before = await setReceiptKey(expense.groupId, expense._id, key);
  // Deleted between our read and the write.
  if (!before) throw expenseNotFound();
  await discardReplaced(before.receiptKey, key, req.log);
  return { status: 200, body: expenseJson({ ...before, receiptKey: key }) };
}

/** Signs a short-lived URL to show the expense's receipt. 404 RECEIPT_NOT_FOUND if it has none. */
export async function createReceiptViewUrl(req: AuthedRequest, groupId: string, expenseId: string): Promise<Response> {
  const expense = await loadExpense(req, groupId, expenseId);
  if (!expense.receiptKey) throw notFound('RECEIPT_NOT_FOUND', 'This expense has no receipt');
  return { status: 200, body: { url: await signView(expense.receiptKey), expiresIn: VIEW_TTL_SECONDS } };
}
