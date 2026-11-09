import { notFound } from '../domain/errors';
import { ConfirmUploadDto, ReceiptUploadDto } from '../dto';
import type { AuthedRequest } from '../lib/http';
import { signUpload, signView, VIEW_TTL_SECONDS, type SignedUpload } from '../lib/s3';
import { toObjectId } from '../repositories/collections';
import { findExpense, setReceiptKey } from '../repositories/expenses';
import { requireMembership } from './groups';
import { expenseJson } from './serializers';
import { discardReplaced, newImageKey, requireUploadedKey } from './uploads';

/** Receipt photos on group expenses. Membership is checked before any URL is signed. */

const expenseNotFound = () => notFound('EXPENSE_NOT_FOUND', 'Expense not found');

async function loadExpense(req: AuthedRequest, groupId: string, expenseId: string) {
  // Membership first: no URL is ever signed for a group the caller isn't in.
  const group = await requireMembership(groupId, req.caller);
  const id = toObjectId(expenseId);
  const expense = id ? await findExpense(group._id, id) : null; // deleted expenses look missing
  if (!expense) throw expenseNotFound();
  return { group, expense };
}

const receiptPrefix = (groupId: string, expenseId: string) => `groups/${groupId}/expenses/${expenseId}/`;

/** POST …/receipt-url: a presigned POST under this expense's prefix. Nothing is saved yet. */
export async function createUploadUrl(req: AuthedRequest, groupId: string, expenseId: string): Promise<SignedUpload> {
  const { group, expense } = await loadExpense(req, groupId, expenseId);
  const { contentType } = ReceiptUploadDto.parse(req.body);
  const key = newImageKey(receiptPrefix(group._id.toHexString(), expense._id.toHexString()), contentType);
  return signUpload(key, contentType);
}

/** PUT …/receipt { key }: the upload finished. Saves the key and deletes the receipt it replaced. */
export async function confirmReceipt(req: AuthedRequest, groupId: string, expenseId: string) {
  const { group, expense } = await loadExpense(req, groupId, expenseId);
  const { key } = ConfirmUploadDto.parse(req.body);
  await requireUploadedKey(key, receiptPrefix(group._id.toHexString(), expense._id.toHexString()));
  const before = await setReceiptKey(group._id, expense._id, key);
  if (!before) throw expenseNotFound(); // deleted meanwhile
  await discardReplaced(before.receiptKey, key, req.log);
  return expenseJson({ ...before, receiptKey: key });
}

export async function createViewUrl(req: AuthedRequest, groupId: string, expenseId: string) {
  const { expense } = await loadExpense(req, groupId, expenseId);
  if (!expense.receiptKey) throw notFound('RECEIPT_NOT_FOUND', 'This expense has no receipt');
  return { url: await signView(expense.receiptKey), expiresIn: VIEW_TTL_SECONDS };
}
