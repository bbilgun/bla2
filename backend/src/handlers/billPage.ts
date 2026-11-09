import { randomBytes } from 'node:crypto';
import { requireParam, withPublicHandler } from '../lib/http';
import * as bills from '../services/bills';
import { guestPageHtml } from '../web/guestPage';

/**
 * Guest routes: no login, the unguessable token in the link is the only key.
 * The page lives at /b/{token}; its script calls the JSON routes next to it.
 */

/** GET /b/{token} — the web page the QR code opens */
export const page = withPublicHandler(async () => {
  const nonce = randomBytes(16).toString('base64');
  return {
    status: 200,
    text: guestPageHtml(nonce),
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'content-security-policy': [
        "default-src 'none'",
        `script-src 'nonce-${nonce}'`,
        `style-src 'nonce-${nonce}'`,
        "connect-src 'self'",
        'img-src https://*.amazonaws.com',
        "base-uri 'none'",
        "form-action 'none'",
        "frame-ancestors 'none'",
      ].join('; '),
      'referrer-policy': 'no-referrer',
      'x-content-type-options': 'nosniff',
      'x-robots-tag': 'noindex',
      'cache-control': 'no-store',
    },
  };
});

/** GET /b/{token}/data */
export const data = withPublicHandler((req) => bills.guestGetBill(requireParam(req, 'token')));

/** POST /b/{token}/guests — { name, guestId, secret } */
export const join = withPublicHandler((req) => bills.guestJoin(req, requireParam(req, 'token')));

/** PUT /b/{token}/guests/{guestId} — header x-guest-secret; { itemIds?, paid? } */
export const updateGuest = withPublicHandler((req) =>
  bills.guestUpdate(req, requireParam(req, 'token'), requireParam(req, 'guestId')),
);
