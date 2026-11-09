import { isDuplicateKeyError, users, type UserDoc } from './collections';

export async function upsertUser(input: { userId: string; email: string; name: string }): Promise<UserDoc> {
  const col = await users();
  const now = new Date();
  try {
    const doc = await col.findOneAndUpdate(
      { _id: input.userId },
      { $set: { email: input.email, name: input.name, updatedAt: now }, $setOnInsert: { createdAt: now } },
      { upsert: true, returnDocument: 'after' },
    );
    return doc!;
  } catch (err) {
    // Two concurrent first requests can both try the upsert; the loser just reads the winner's row.
    if (isDuplicateKeyError(err)) {
      const existing = await col.findOne({ _id: input.userId });
      if (existing) return existing;
    }
    throw err;
  }
}

export async function findUserByEmail(email: string): Promise<UserDoc | null> {
  return (await users()).findOne({ email: email.toLowerCase() }, { sort: { updatedAt: -1 } });
}
