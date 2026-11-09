// The balances screen: each person's net position in a group and a suggested way to settle up.
import { computeBalances } from '../aggregations/balances';
import { cents } from '../domain/money';
import { compareIds } from '../domain/split';
import { suggestTransfers } from '../domain/settle';
import type { AuthedRequest, Response } from '../lib/http';
import { requireMembership } from './groups';

/**
 * Every member's balance, derived from the ledger on this read, plus suggested payments. Former members
 * appear only while their balance isn't zero, which leaving normally prevents.
 */
export async function getBalances(req: AuthedRequest, groupId: string): Promise<Response> {
  const group = await requireMembership(groupId, req.caller);
  const rows = await computeBalances(group._id);
  const netByUser = new Map(rows.map((row) => [row.userId, row.netCents]));

  // Every member is listed, even with no activity yet.
  const userIds = new Set(group.members.map((member) => member.userId));
  for (const [userId, net] of netByUser) {
    if (net !== 0) userIds.add(userId);
  }

  const names = new Map(group.members.map((member) => [member.userId, member.name]));
  const balances = [...userIds].sort(compareIds).map((userId) => ({
    userId,
    name: names.get(userId) ?? 'Former member',
    netCents: cents(netByUser.get(userId) ?? 0),
  }));

  return {
    status: 200,
    body: {
      groupId: group._id.toHexString(),
      currency: group.currency,
      balances,
      // This also checks that the balances add up to exactly zero.
      transfers: suggestTransfers(balances),
    },
  };
}
