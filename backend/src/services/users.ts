import type { Caller } from '../lib/http';
import type { UserDoc } from '../repositories/collections';
import { refreshMemberSnapshots } from '../repositories/groups';
import { upsertUser } from '../repositories/users';

/**
 * Records the caller from their token (every route that needs a users row goes through here).
 * Groups keep a name/email snapshot per member; when the token says something different from last time,
 * those snapshots are rewritten. Comparing with the row *before* the upsert keeps this to one write
 * per actual change instead of an updateMany on every request.
 */
export async function registerCaller(caller: Caller): Promise<UserDoc> {
  const { user, before } = await upsertUser(caller);
  if (!before || before.name !== caller.name || before.email !== caller.email) {
    await refreshMemberSnapshots(caller.userId, caller.email, caller.name);
  }
  return user;
}
