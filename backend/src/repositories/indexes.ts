import type { Db, IndexDescription } from 'mongodb';

/**
 * Every index the app relies on. Checked once per Lambda container on first connect;
 * createIndexes is a no-op when the index already exists.
 *
 *   users            { email: 1, updatedAt: -1 }    add member by email (not unique: a re-created
 *                                                 Cognito account gets a new sub, same email)
 *   groups           { 'members.userId': 1 }        "my groups", membership check
 *   expenses         { groupId: 1, _id: -1 }        newest-first page, balances $match
 *   settlements      { groupId: 1, _id: -1 }        same
 *   bills            { hostUserId: 1, _id: -1 }     "my bills", newest first
 *   bills            { token: 1 } unique            the guest page looks bills up by link token
 *   idempotency_keys { userId: 1, key: 1 } unique   replay protection on money writes
 *   idempotency_keys { createdAt: 1 } TTL 7 days    old keys clean themselves up
 */
const INDEXES: Record<string, IndexDescription[]> = {
  users: [{ key: { email: 1, updatedAt: -1 }, name: 'email_updatedAt' }],
  groups: [{ key: { 'members.userId': 1 }, name: 'members_userId' }],
  expenses: [{ key: { groupId: 1, _id: -1 }, name: 'groupId_id' }],
  settlements: [{ key: { groupId: 1, _id: -1 }, name: 'groupId_id' }],
  bills: [
    { key: { hostUserId: 1, _id: -1 }, name: 'hostUserId_id' },
    { key: { token: 1 }, unique: true, name: 'token_unique' },
  ],
  idempotency_keys: [
    { key: { userId: 1, key: 1 }, unique: true, name: 'userId_key_unique' },
    { key: { createdAt: 1 }, expireAfterSeconds: 7 * 24 * 3600, name: 'createdAt_ttl' },
  ],
};

/**
 * One createIndexes command per collection, one after another, so they all reuse the single
 * connection the client just opened. Sent in parallel, each would open its own pooled connection,
 * and every new connection to Atlas pays a TLS + SCRAM handshake: that doubled the cold start.
 */
export async function ensureIndexes(db: Db): Promise<void> {
  for (const [collection, specs] of Object.entries(INDEXES)) {
    await db.collection(collection).createIndexes(specs);
  }
}
