// Routes for receipt photos on expenses. Each one hands the request to services/receipts.ts.
import { requireParam, withHandler } from '../lib/http';
import * as receipts from '../services/receipts';

/** POST /groups/{groupId}/expenses/{expenseId}/receipt-url: a signed upload for the phone to post to. */
export const uploadUrl = withHandler((req) =>
  receipts.createReceiptUploadUrl(req, requireParam(req, 'groupId'), requireParam(req, 'expenseId')),
);

/** PUT /groups/{groupId}/expenses/{expenseId}/receipt with { key }: the upload finished, attach it. */
export const confirm = withHandler((req) =>
  receipts.confirmReceipt(req, requireParam(req, 'groupId'), requireParam(req, 'expenseId')),
);

/** GET /groups/{groupId}/expenses/{expenseId}/receipt-url: a short-lived URL to show the receipt. */
export const viewUrl = withHandler((req) =>
  receipts.createReceiptViewUrl(req, requireParam(req, 'groupId'), requireParam(req, 'expenseId')),
);
