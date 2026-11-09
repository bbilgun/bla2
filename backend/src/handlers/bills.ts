// Routes the host uses from the app (signed in). The public guest routes are in handlers/billPage.ts.
import { requireParam, withHandler } from '../lib/http';
import * as bills from '../services/bills';

/** POST /bills: needs an Idempotency-Key header. */
export const create = withHandler((req) => bills.createBill(req));

/** GET /bills?limit=20&cursor=<id>: the caller's bills, newest first. */
export const list = withHandler((req) => bills.listBills(req));

/** GET /bills/{billId} */
export const get = withHandler((req) => bills.getBill(req, requireParam(req, 'billId')));

/** PUT /bills/{billId}: replace the title, lines and payment details. */
export const update = withHandler((req) => bills.updateBill(req, requireParam(req, 'billId')));

/** DELETE /bills/{billId} */
export const remove = withHandler((req) => bills.deleteBill(req, requireParam(req, 'billId')));

/** POST /bills/{billId}/token: a new share link. The old one stops working. */
export const rotateToken = withHandler((req) => bills.rotateBillToken(req, requireParam(req, 'billId')));

/** POST /bills/{billId}/status with { status: "OPEN" | "CLOSED" }. */
export const setStatus = withHandler((req) => bills.setBillStatus(req, requireParam(req, 'billId')));

/** PUT /bills/{billId}/guests/{guestId}: the host's own ticks (guest "host"), fixes and cash payments. */
export const updateGuest = withHandler((req) =>
  bills.updateGuestAsHost(req, requireParam(req, 'billId'), requireParam(req, 'guestId')),
);

/** DELETE /bills/{billId}/guests/{guestId} */
export const removeGuest = withHandler((req) =>
  bills.removeGuest(req, requireParam(req, 'billId'), requireParam(req, 'guestId')),
);
