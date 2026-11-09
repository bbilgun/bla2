import { isDuplicateKeyError, users, type UserDoc } from './collections';

export interface UpsertedUser {
  user: UserDoc;
  /** The row as it was before this call; null on the user's first request. */
  before: UserDoc | null;
}

/** Records the caller from their token claims. Returns the row before and after, so callers can see what changed. */
export async function upsertUser(input: { userId: string; email: string; name: string }): Promise<UpsertedUser> {
  const col = await users();
  const now = new Date();
  const applied = (before: UserDoc | null): UserDoc =>
    before
      ? { ...before, email: input.email, name: input.name, updatedAt: now }
      : { _id: input.userId, email: input.email, name: input.name, createdAt: now, updatedAt: now };
  try {
    const before = await col.findOneAndUpdate(
      { _id: input.userId },
      { $set: { email: input.email, name: input.name, updatedAt: now }, $setOnInsert: { createdAt: now } },
      { upsert: true, returnDocument: 'before' },
    );
    return { user: applied(before), before };
  } catch (err) {
    // Two concurrent first requests can both try the upsert; the loser just reads the winner's row.
    if (isDuplicateKeyError(err)) {
      const existing = await col.findOne({ _id: input.userId });
      if (existing) return { user: existing, before: existing };
    }
    throw err;
  }
}

export async function findUser(userId: string): Promise<UserDoc | null> {
  return (await users()).findOne({ _id: userId });
}

/** Saves the confirmed bank-QR key and returns the key it replaced (to delete from S3), if any. */
export async function setPayQrKey(userId: string, key: string): Promise<string | null> {
  const before = await (await users()).findOneAndUpdate(
    { _id: userId },
    { $set: { payQrKey: key, updatedAt: new Date() } },
    { returnDocument: 'before', projection: { payQrKey: 1 } },
  );
  return before?.payQrKey ?? null;
}

export async function deleteUser(userId: string): Promise<void> {
  await (await users()).deleteOne({ _id: userId });
}
