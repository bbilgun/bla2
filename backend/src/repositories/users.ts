// The users collection: one row per Cognito user, plus their saved bank details and bank QR.
import { isDuplicateKeyError, users } from './collections';
import type { PaymentInfo, UserDoc } from './documents';

/** The user row after an upsert, and as it was before. */
export interface UpsertedUser {
  user: UserDoc;
  /** Null on the user's first request. */
  before: UserDoc | null;
}

/** Creates or updates the user from their token's claims. Returns the row before and after the write. */
export async function upsertUser(input: { userId: string; email: string; name: string }): Promise<UpsertedUser> {
  const col = await users();
  const now = new Date();

  try {
    const before = await col.findOneAndUpdate(
      { _id: input.userId },
      { $set: { email: input.email, name: input.name, updatedAt: now }, $setOnInsert: { createdAt: now } },
      { upsert: true, returnDocument: 'before' },
    );
    const user: UserDoc = before
      ? { ...before, email: input.email, name: input.name, updatedAt: now }
      : { _id: input.userId, email: input.email, name: input.name, createdAt: now, updatedAt: now };
    return { user, before };
  } catch (err) {
    // Two first requests at once can both try to insert. The loser reads the winner's row.
    if (isDuplicateKeyError(err)) {
      const existing = await col.findOne({ _id: input.userId });
      if (existing) return { user: existing, before: existing };
    }
    throw err;
  }
}

/** A user row, or null. */
export async function findUser(userId: string): Promise<UserDoc | null> {
  return (await users()).findOne({ _id: userId });
}

/** Saves the bank details from a bill, to pre-fill the user's next one. */
export async function savePaymentProfile(userId: string, payment: PaymentInfo): Promise<void> {
  await (await users()).updateOne({ _id: userId }, { $set: { payment } });
}

/** The S3 key of the user's bank QR image, or null if they haven't uploaded one. */
export async function findPayQrKey(userId: string): Promise<string | null> {
  const user = await (await users()).findOne({ _id: userId }, { projection: { payQrKey: 1 } });
  return user?.payQrKey ?? null;
}

/** Saves a confirmed bank QR key. Returns the key it replaced, if any, so the caller can delete that object. */
export async function setPayQrKey(userId: string, key: string): Promise<string | null> {
  const before = await (await users()).findOneAndUpdate(
    { _id: userId },
    { $set: { payQrKey: key, updatedAt: new Date() } },
    { returnDocument: 'before', projection: { payQrKey: 1 } },
  );
  return before?.payQrKey ?? null;
}

/** Deletes the user row. */
export async function deleteUser(userId: string): Promise<void> {
  await (await users()).deleteOne({ _id: userId });
}
