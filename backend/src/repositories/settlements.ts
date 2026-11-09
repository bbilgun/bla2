import type { ObjectId } from 'mongodb';
import { insertOnce, NOT_DELETED, pageNewestFirst, settlements, type Page, type SettlementDoc } from './collections';

/** Insert-or-fetch on the idempotency key's resourceId (see services/idempotency.ts). */
export async function insertSettlementOnce(doc: SettlementDoc): Promise<SettlementDoc> {
  return insertOnce(await settlements(), doc);
}

/** Live settlements only, newest first. */
export async function listSettlements(
  groupId: ObjectId,
  opts: { limit: number; cursor?: ObjectId | undefined },
): Promise<Page<SettlementDoc>> {
  return pageNewestFirst(await settlements(), { groupId, ...NOT_DELETED }, opts);
}

/** Deleted or not: a repeated DELETE answers 200 again. */
export async function findSettlementAnyState(groupId: ObjectId, settlementId: ObjectId): Promise<SettlementDoc | null> {
  return (await settlements()).findOne({ _id: settlementId, groupId });
}

export async function softDeleteSettlement(groupId: ObjectId, settlementId: ObjectId, userId: string): Promise<void> {
  await (await settlements()).updateOne(
    { _id: settlementId, groupId, ...NOT_DELETED },
    { $set: { deletedAt: new Date(), deletedBy: userId } },
  );
}
