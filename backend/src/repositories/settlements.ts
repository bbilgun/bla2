import type { ObjectId } from 'mongodb';
import { isDuplicateKeyError, settlements, type SettlementDoc } from './collections';

export async function insertSettlementOnce(doc: SettlementDoc): Promise<SettlementDoc> {
  const col = await settlements();
  try {
    await col.insertOne(doc);
    return doc;
  } catch (err) {
    if (!isDuplicateKeyError(err)) throw err;
    const existing = await col.findOne({ _id: doc._id });
    if (!existing) throw err;
    return existing;
  }
}

export async function listSettlements(groupId: ObjectId, limit = 100): Promise<SettlementDoc[]> {
  return (await settlements()).find({ groupId }).sort({ _id: -1 }).limit(limit).toArray();
}
