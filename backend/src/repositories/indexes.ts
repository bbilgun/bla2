// Every index the app relies on, created on each container's first connect. createIndexes does nothing
// for an index that already exists. Never change the key of an existing name: Mongo refuses that.
import type { Db, IndexDescription } from 'mongodb';

const INDEXES: Record<string, IndexDescription[]> = {
  groups: [
    // "My groups" and every membership check.
    { key: { 'members.userId': 1 }, name: 'members_userId' },
    // Invites waiting for a verified email.
    { key: { 'invites.email': 1 }, name: 'invites_email' },
  ],
  // Newest-first pages and the balances $match.
  expenses: [{ key: { groupId: 1, _id: -1 }, name: 'groupId_id' }],
  settlements: [{ key: { groupId: 1, _id: -1 }, name: 'groupId_id' }],
  bills: [
    // "My bills", newest first.
    { key: { hostUserId: 1, _id: -1 }, name: 'hostUserId_id' },
    // The guest page looks bills up by link token.
    { key: { token: 1 }, unique: true, name: 'token_unique' },
  ],
  idempotency_keys: [
    // Exactly one request can claim a key.
    { key: { userId: 1, key: 1 }, unique: true, name: 'userId_key_unique' },
    // Old keys clean themselves up after 7 days.
    { key: { createdAt: 1 }, expireAfterSeconds: 7 * 24 * 3600, name: 'createdAt_ttl' },
  ],
};

/**
 * Creates any missing index. One collection at a time on purpose: in parallel, each command would open
 * its own pooled connection and pay a TLS and auth handshake to Atlas, which slows the cold start.
 */
export async function ensureIndexes(db: Db): Promise<void> {
  for (const [collection, specs] of Object.entries(INDEXES)) {
    await db.collection(collection).createIndexes(specs);
  }
}
