// Makes a create safe to retry: the same Idempotency-Key never writes twice and gets the same response back.
// docs/backend.md walks through every case.
import { createHash } from 'node:crypto';
import type { ObjectId } from 'mongodb';
import { badRequest, unprocessable } from '../domain/errors';
import type { AuthedRequest, Response } from '../lib/http';
import { claimKey, completeKey } from '../repositories/idempotency';

const KEY_RE = /^[A-Za-z0-9_-]{8,128}$/;

/**
 * Runs `write` at most once per Idempotency-Key and replays its response to every retry. `write` gets
 * the _id to give the new document. It must be insert-or-fetch on that _id (insertOnce does this),
 * because a retry after a crash runs it again with the same id. Throws 400 for a missing or malformed
 * key and 422 when the key was used for a different request.
 */
export async function idempotent(req: AuthedRequest, write: (resourceId: ObjectId) => Promise<Response>): Promise<Response> {
  const key = req.header('idempotency-key');
  if (!key) {
    throw badRequest('IDEMPOTENCY_KEY_REQUIRED', 'Send an Idempotency-Key header (a UUID) with this request');
  }
  if (!KEY_RE.test(key)) {
    throw badRequest('IDEMPOTENCY_KEY_INVALID', 'Idempotency-Key must be 8-128 letters, digits, - or _');
  }

  // Method and path are in the hash, so the same key sent to another route counts as a different request.
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
    // Claimed but never finished: an earlier attempt crashed, or is still running. Run it again with the
    // same resourceId; insert-or-fetch makes that safe.
    req.log.info('idempotency.resume', { key });
  }

  // If this throws, the key stays pending and the client's retry resumes it.
  const res = await write(claim.doc.resourceId);
  await completeKey(claim.doc._id, { status: res.status, body: res.body });
  return res;
}
