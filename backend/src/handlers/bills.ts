import { requireParam, withHandler } from '../lib/http';
import * as bills from '../services/bills';

/** Host routes (signed in). The bill flow for guests is in handlers/billPage.ts. */

/** POST /bills — needs an Idempotency-Key */
export const create = withHandler((req) => bills.createBill(req));

/** GET /bills?limit=20&cursor=<id> — my bills, newest first */
export const list = withHandler((req) => bills.listBills(req));

/** GET /bills/{billId} */
export const get = withHandler((req) => bills.getBill(req, requireParam(req, 'billId')));

/** PUT /bills/{billId} — replace title, lines and payment details */
export const update = withHandler((req) => bills.updateBill(req, requireParam(req, 'billId')));

/** DELETE /bills/{billId} */
export const remove = withHandler((req) => bills.deleteBill(req, requireParam(req, 'billId')));

/** POST /bills/{billId}/token — a new share link; the old one stops working */
export const rotateToken = withHandler((req) => bills.rotateBillToken(req, requireParam(req, 'billId')));

/** POST /bills/{billId}/status — { status: "OPEN" | "CLOSED" } */
export const setStatus = withHandler((req) => bills.setBillStatus(req, requireParam(req, 'billId')));

/** PUT /bills/{billId}/guests/{guestId} — the host's own ticks (guestId "host"), fixes, cash payments */
export const updateGuest = withHandler((req) =>
  bills.hostUpdateGuest(req, requireParam(req, 'billId'), requireParam(req, 'guestId')),
);

/** DELETE /bills/{billId}/guests/{guestId} */
export const removeGuest = withHandler((req) =>
  bills.removeGuest(req, requireParam(req, 'billId'), requireParam(req, 'guestId')),
);

/** POST /me/pay-qr-url — presigned POST for the host's bank QR screenshot */
export const payQrUploadUrl = withHandler((req) => bills.createPayQrUploadUrl(req));

/** PUT /me/pay-qr — { key }: the upload finished, use it on every bill */
export const confirmPayQr = withHandler((req) => bills.confirmPayQr(req));
