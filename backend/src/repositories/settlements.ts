// The settlements collection: payments members recorded between themselves. Soft-deleted like expenses.
import type { ObjectId } from 'mongodb';
import { insertOnce, NOT_DELETED, pageNewestFirst, settlements, type Page, type PageOptions } from './collections';
import type { SettlementDoc } from './documents';

/** Insert-or-fetch on the _id the idempotency key reserved (see services/idempotency.ts). */
export async function insertSettlementOnce(doc: SettlementDoc): Promise<SettlementDoc> {
  return insertOnce(await settlements(), doc);
}

/** One page of the group's live settlements, newest first. */
export async function listSettlements(groupId: ObjectId, page: PageOptions): Promise<Page<SettlementDoc>> {
  return pageNewestFirst(await settlements(), { groupId, ...NOT_DELETED }, page);
}

/** A settlement in the group, deleted or not, so a repeated DELETE can answer 200 again. */
export async function findSettlementAnyState(groupId: ObjectId, settlementId: ObjectId): Promise<SettlementDoc | null> {
  return (await settlements()).findOne({ _id: settlementId, groupId });
}

/** Marks a live settlement deleted. Does nothing if it already is. */
export async function softDeleteSettlement(groupId: ObjectId, settlementId: ObjectId, userId: string): Promise<void> {
  await (await settlements()).updateOne(
    { _id: settlementId, groupId, ...NOT_DELETED },
    { $set: { deletedAt: new Date(), deletedBy: userId } },
  );
}
