import type { Document, ObjectId } from 'mongodb';
import { expenses } from '../repositories/collections';

/**
 * Balances are derived, never stored. Every read recomputes them from the ledger
 * (expenses + settlements), so they can't drift out of sync with the history.
 *
 * Read the pipeline as array ops running inside Mongo:
 *
 *   expenses.filter(e => e.groupId === g)                                    $match
 *     .flatMap(e => [{user: e.paidBy, +amount}, ...e.splits.map(-share)])     $project + $unwind
 *     .concat(settlements.filter(...).flatMap(s => [{from, +amt}, {to, -amt}]))  $unionWith
 *     .groupBy(entry => entry.userId).map(sum)                               $group
 *
 * Positive net: the group owes you. Negative: you owe the group. All nets sum to 0.
 */
export function balancesPipeline(groupId: ObjectId): Document[] {
  return [
    { $match: { groupId } },
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
          { $match: { groupId } },
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

export async function computeBalances(groupId: ObjectId): Promise<{ userId: string; netCents: number }[]> {
  return (await expenses()).aggregate<{ userId: string; netCents: number }>(balancesPipeline(groupId)).toArray();
}
