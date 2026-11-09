import { randomUUID } from 'node:crypto';
import { notFound } from '../domain/errors';
import { ReceiptUploadDto } from '../dto';
import type { AuthedRequest } from '../lib/http';
import { IMAGE_EXTENSIONS, signUpload, signView, UPLOAD_TTL_SECONDS, VIEW_TTL_SECONDS } from '../lib/s3';
import { toObjectId } from '../repositories/collections';
import { findExpense, setReceiptKey } from '../repositories/expenses';
import { requireMembership } from './groups';

/** Receipt photos on group expenses. Membership is checked before any URL is signed. */

async function loadExpense(req: AuthedRequest, groupId: string, expenseId: string) {
  // Membership first: no URL is ever signed for a group the caller isn't in.
  const group = await requireMembership(groupId, req.caller);
  const id = toObjectId(expenseId);
  const expense = id ? await findExpense(group._id, id) : null;
  if (!expense) throw notFound('EXPENSE_NOT_FOUND', 'Expense not found');
  return { group, expense };
}

export async function createUploadUrl(req: AuthedRequest, groupId: string, expenseId: string) {
  const { group, expense } = await loadExpense(req, groupId, expenseId);
  const { contentType } = ReceiptUploadDto.parse(req.body);

  const key = `groups/${group._id.toHexString()}/expenses/${expense._id.toHexString()}/${randomUUID()}.${IMAGE_EXTENSIONS[contentType]}`;
  const uploadUrl = await signUpload(key, contentType);
  await setReceiptKey(group._id, expense._id, key);

  return { uploadUrl, method: 'PUT', headers: { 'content-type': contentType }, key, expiresIn: UPLOAD_TTL_SECONDS };
}

export async function createViewUrl(req: AuthedRequest, groupId: string, expenseId: string) {
  const { expense } = await loadExpense(req, groupId, expenseId);
  if (!expense.receiptKey) throw notFound('RECEIPT_NOT_FOUND', 'This expense has no receipt');
  return { url: await signView(expense.receiptKey), expiresIn: VIEW_TTL_SECONDS };
}
