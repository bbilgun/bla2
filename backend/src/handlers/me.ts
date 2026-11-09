// Routes for the caller's own account. Each one hands the request to services/account.ts.
import { withHandler } from '../lib/http';
import * as account from '../services/account';

/** GET /me: the caller from their token. Also records them and refreshes their name in groups. */
export const handler = withHandler((req) => account.getMe(req));

/** DELETE /me: leave every group and delete the caller's data and Cognito user. 409 while money is owed. */
export const remove = withHandler((req) => account.deleteAccount(req));

/** POST /me/pay-qr-url: a signed upload for a screenshot of the caller's bank QR. */
export const payQrUploadUrl = withHandler((req) => account.createPayQrUploadUrl(req));

/** PUT /me/pay-qr with { key }: the upload finished, show it on every bill. */
export const confirmPayQr = withHandler((req) => account.confirmPayQr(req));
