// Derives every member's net balance from the ledger in one aggregation. Balances are never stored,
// so they can't drift from the history. docs/backend.md walks through the pipeline stage by stage.
import type { Document, ObjectId } from 'mongodb';
import { expenses } from '../repositories/collections';

/** A user's net position: positive when the group owes them, negative when they owe the group. */
export interface NetBalanceRow {
  userId: string;
  netCents: number;
}

/**
 * The pipeline, run on `expenses`. Each live expense credits its payer and debits each share; each live
 * settlement credits the payer and debits the receiver. Summed per user, the nets add up to zero.
 */
export function balancesPipeline(groupId: ObjectId): Document[] {
  return [
    // The {groupId, _id} index drives this match.
    { $match: { groupId, deletedAt: { $exists: false } } },
    {
      $project: {
        _id: 0,
        entries: {
          $concatArrays: [
            [{ userId: '$paidBy', amountCents: '$amountCents' }],
            {
              $map: {
                input: '$splits',
                as: 's',
                in: { userId: '$$s.userId', amountCents: { $subtract: [0, '$$s.amountCents'] } },
              },
            },
          ],
        },
      },
    },
    { $unwind: '$entries' },
    { $replaceWith: '$entries' },
    {
      $unionWith: {
        coll: 'settlements',
        pipeline: [
          { $match: { groupId, deletedAt: { $exists: false } } },
          {
            // Paying someone back raises your net and lowers theirs.
            $project: {
              _id: 0,
              entries: [
                { userId: '$fromUserId', amountCents: '$amountCents' },
                { userId: '$toUserId', amountCents: { $subtract: [0, '$amountCents'] } },
              ],
            },
          },
          { $unwind: '$entries' },
          { $replaceWith: '$entries' },
        ],
      },
    },
    { $group: { _id: '$userId', netCents: { $sum: '$amountCents' } } },
    { $project: { _id: 0, userId: '$_id', netCents: 1 } },
    { $sort: { userId: 1 } },
  ];
}

/** Net balances for everyone with any entry in the group's ledger, sorted by user id. */
export async function computeBalances(groupId: ObjectId): Promise<NetBalanceRow[]> {
  const col = await expenses();
  return col.aggregate<NetBalanceRow>(balancesPipeline(groupId)).toArray();
}
