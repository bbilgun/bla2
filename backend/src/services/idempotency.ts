import { createHash } from 'node:crypto';
import type { ObjectId } from 'mongodb';
import { badRequest, unprocessable } from '../domain/errors';
import type { AuthedRequest, Response } from '../lib/http';
import { claimKey, completeKey } from '../repositories/idempotency';

const KEY_RE = /^[A-Za-z0-9_-]{8,128}$/;

/**
 * Runs a money write at most once per Idempotency-Key.
 *
 *  1. Insert {userId, key} into idempotency_keys. The unique index means only one request wins.
 *  2. Lost the race / seen before?  Same body + finished -> replay the stored response.
 *                                   Same body + unfinished -> re-run with the SAME resourceId.
 *                                   Different body -> 422, the key was reused for something else.
 *  3. `write(resourceId)` must be insert-or-fetch on that _id, so re-running it can't double-write.
 *  4. Store the response on the key so the next retry is a pure replay.
 */
export async function idempotent(req: AuthedRequest, write: (resourceId: ObjectId) => Promise<Response>): Promise<Response> {
  const key = req.header('idempotency-key');
  if (!key) throw badRequest('IDEMPOTENCY_KEY_REQUIRED', 'Send an Idempotency-Key header (a UUID) with this request');
  if (!KEY_RE.test(key)) throw badRequest('IDEMPOTENCY_KEY_INVALID', 'Idempotency-Key must be 8-128 letters, digits, - or _');

  const requestHash = createHash('sha256').update(`${req.method} ${req.path}\n${req.rawBody}`).digest('hex');
  const claim = await claimKey({ userId: req.caller.userId, key, requestHash });

  if (claim.state === 'seen') {
    if (claim.doc.requestHash !== requestHash) {
      throw unprocessable('IDEMPOTENCY_KEY_REUSED', 'This Idempotency-Key was already used for a different request');
    }
    if (claim.doc.status === 'done' && claim.doc.response) {
      req.log.info('idempotency.replay', { key });
      return { ...claim.doc.response, headers: { 'idempotent-replayed': 'true' } };
    }
    req.log.info('idempotency.resume', { key });
  }

  // If this throws, the key stays pending; the client's retry resumes with the same resourceId.
  const res = await write(claim.doc.resourceId);
  await completeKey(claim.doc._id, { status: res.status, body: res.body });
  return res;
}
