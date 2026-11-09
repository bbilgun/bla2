import { requireParam, withHandler } from '../lib/http';
import * as receipts from '../services/receipts';

/** POST /groups/{groupId}/expenses/{expenseId}/receipt-url — presigned POST for the phone to upload to */
export const uploadUrl = withHandler(async (req) => ({
  status: 200,
  body: await receipts.createUploadUrl(req, requireParam(req, 'groupId'), requireParam(req, 'expenseId')),
}));

/** PUT /groups/{groupId}/expenses/{expenseId}/receipt — { key }: the upload finished, attach it */
export const confirm = withHandler(async (req) => ({
  status: 200,
  body: await receipts.confirmReceipt(req, requireParam(req, 'groupId'), requireParam(req, 'expenseId')),
}));

/** GET /groups/{groupId}/expenses/{expenseId}/receipt-url — presigned GET to display it */
export const viewUrl = withHandler(async (req) => ({
  status: 200,
  body: await receipts.createViewUrl(req, requireParam(req, 'groupId'), requireParam(req, 'expenseId')),
}));
