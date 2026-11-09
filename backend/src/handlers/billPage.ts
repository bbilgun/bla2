// Public routes for bill guests: no login, the unguessable token in the link is the only key.
// The page lives at /b/{token} and its script calls the JSON routes next to it.
import { randomBytes } from 'node:crypto';
import { requireParam, withPublicHandler } from '../lib/http';
import { bucketOrigin } from '../lib/s3';
import * as bills from '../services/bills';
import { guestPageHtml } from '../web/guestPage';

/**
 * GET /b/{token}: the web page the QR code opens. The page is the same for every bill; its script
 * loads the bill itself. A fresh nonce per response locks the CSP to this page's own script and style.
 */
export const page = withPublicHandler(async () => {
  const nonce = randomBytes(16).toString('base64');
  // The only image is the host's bank QR, a signed URL on our own bucket, so allow that origin alone.
  const images = bucketOrigin() ?? "'none'";
  const csp = [
    "default-src 'none'",
    `script-src 'nonce-${nonce}'`,
    `style-src 'nonce-${nonce}'`,
    "connect-src 'self'",
    `img-src ${images}`,
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'none'",
  ].join('; ');

  return {
    status: 200,
    text: guestPageHtml(nonce),
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'content-security-policy': csp,
      'referrer-policy': 'no-referrer',
      'x-content-type-options': 'nosniff',
      'x-robots-tag': 'noindex',
      'cache-control': 'no-store',
    },
  };
});

/** GET /b/{token}/data: the bill as guests see it. */
export const data = withPublicHandler((req) => bills.getBillByToken(requireParam(req, 'token')));

/** POST /b/{token}/guests with { name, guestId, secret }. */
export const join = withPublicHandler((req) => bills.joinBill(req, requireParam(req, 'token')));

/** PUT /b/{token}/guests/{guestId} with header x-guest-secret and { itemIds?, paid?, paidCents? }. */
export const updateGuest = withPublicHandler((req) =>
  bills.updateGuestByToken(req, requireParam(req, 'token'), requireParam(req, 'guestId')),
);
