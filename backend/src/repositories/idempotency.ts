// The idempotency_keys collection: who has sent which Idempotency-Key, and the response to replay.
import { ObjectId } from 'mongodb';
import { idempotencyKeys, isDuplicateKeyError } from './collections';
import type { IdempotencyDoc } from './documents';

/** The result of claiming a key: `new` if this request inserted it, `seen` if an earlier one did. */
export type Claim = { state: 'new'; doc: IdempotencyDoc } | { state: 'seen'; doc: IdempotencyDoc };

/**
 * Claims `{ userId, key }` for this request. The unique index lets exactly one request insert it;
 * every other request with the same key reads the winner's row instead.
 */
export async function claimKey(input: { userId: string; key: string; requestHash: string }): Promise<Claim> {
  const col = await idempotencyKeys();
  const doc: IdempotencyDoc = {
    _id: new ObjectId(),
    userId: input.userId,
    key: input.key,
    requestHash: input.requestHash,
    resourceId: new ObjectId(),
    status: 'pending',
    createdAt: new Date(),
  };

  try {
    await col.insertOne(doc);
    return { state: 'new', doc };
  } catch (err) {
    if (!isDuplicateKeyError(err)) throw err;
    const existing = await col.findOne({ userId: input.userId, key: input.key });
    // The TTL index removed it between the two calls. The client's retry will start fresh.
    if (!existing) throw err;
    return { state: 'seen', doc: existing };
  }
}

/** Marks a key done and stores the response, so the next retry is a pure replay. */
export async function completeKey(id: ObjectId, response: { status: number; body: unknown }): Promise<void> {
  await (await idempotencyKeys()).updateOne({ _id: id }, { $set: { status: 'done', response } });
}

/** Deletes every key a user sent. Used by account deletion; they'd expire within 7 days anyway. */
export async function deleteKeysForUser(userId: string): Promise<void> {
  await (await idempotencyKeys()).deleteMany({ userId });
}
