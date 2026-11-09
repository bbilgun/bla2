// Keeps the users row, and the name and email copied into each group, in step with the caller's token.
import type { Caller } from '../lib/http';
import type { UserDoc } from '../repositories/documents';
import { refreshMemberSnapshots } from '../repositories/groups';
import { upsertUser } from '../repositories/users';

/**
 * Records the caller from their token and returns their users row. When the token's name or email
 * differs from the stored row, every group's copy is rewritten too. Comparing with the row first
 * keeps that to one group write per real change.
 */
export async function registerCaller(caller: Caller): Promise<UserDoc> {
  const { user, before } = await upsertUser(caller);
  const changed = !before || before.name !== caller.name || before.email !== caller.email;
  if (changed) {
    await refreshMemberSnapshots(caller.userId, caller.email, caller.name);
  }
  return user;
}
