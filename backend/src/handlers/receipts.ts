import { requireParam, withHandler } from '../lib/http';
import * as receipts from '../services/receipts';

/** POST /groups/{groupId}/expenses/{expenseId}/receipt-url — presigned PUT for the phone to upload to */
export const uploadUrl = withHandler(async (req) => ({
  status: 200,
  body: await receipts.createUploadUrl(req, requireParam(req, 'groupId'), requireParam(req, 'expenseId')),
}));

/** GET /groups/{groupId}/expenses/{expenseId}/receipt-url — presigned GET to display it */
export const viewUrl = withHandler(async (req) => ({
  status: 200,
  body: await receipts.createViewUrl(req, requireParam(req, 'groupId'), requireParam(req, 'expenseId')),
}));
