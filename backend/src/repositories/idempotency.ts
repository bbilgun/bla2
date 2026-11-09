import { ObjectId } from 'mongodb';
import { idempotencyKeys, isDuplicateKeyError, type IdempotencyDoc } from './collections';

export type Claim = { state: 'new'; doc: IdempotencyDoc } | { state: 'seen'; doc: IdempotencyDoc };

/**
 * Try to claim {userId, key}. The unique index makes this atomic: exactly one request wins the
 * insert; every other request with the same key gets a duplicate-key error and reads the winner's row.
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
    if (!existing) throw err; // TTL removed it between the two calls; let the client retry
    return { state: 'seen', doc: existing };
  }
}

export async function completeKey(id: ObjectId, response: { status: number; body: unknown }): Promise<void> {
  await (await idempotencyKeys()).updateOne({ _id: id }, { $set: { status: 'done', response } });
}

/** Account deletion: the user's keys would expire in 7 days anyway. */
export async function deleteKeysForUser(userId: string): Promise<void> {
  await (await idempotencyKeys()).deleteMany({ userId });
}
