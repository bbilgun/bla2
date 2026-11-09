import { computeBalances } from '../aggregations/balances';
import { cents } from '../domain/money';
import { suggestTransfers, type Balance } from '../domain/settle';
import { compareIds } from '../domain/split';
import type { Caller } from '../lib/http';
import { requireMembership } from './groups';

export async function getBalances(caller: Caller, groupId: string) {
  const group = await requireMembership(groupId, caller);
  const rows = await computeBalances(group._id);
  const net = new Map(rows.map((r) => [r.userId, r.netCents]));

  // Every member appears, even with no activity yet. Former members appear only while non-zero
  // (leaving is blocked until then, so that's only legacy data or a race).
  const ids = new Set([...group.members.map((m) => m.userId), ...[...net].filter(([, n]) => n !== 0).map(([id]) => id)]);
  const names = new Map(group.members.map((m) => [m.userId, m.name]));
  const balances: (Balance & { name: string })[] = [...ids].sort(compareIds).map((userId) => ({
    userId,
    name: names.get(userId) ?? 'Former member',
    netCents: cents(net.get(userId) ?? 0),
  }));

  return {
    groupId: group._id.toHexString(),
    currency: group.currency,
    balances,
    // suggestTransfers also asserts the balances sum to exactly 0.
    transfers: suggestTransfers(balances),
  };
}
