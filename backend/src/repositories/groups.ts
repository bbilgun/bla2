import { ObjectId } from 'mongodb';
import { groups, type GroupDoc, type MemberDoc } from './collections';

export async function insertGroup(doc: Omit<GroupDoc, '_id'>): Promise<GroupDoc> {
  const withId: GroupDoc = { _id: new ObjectId(), ...doc };
  await (await groups()).insertOne(withId);
  return withId;
}

/** Returns the group only if `userId` is a member. Non-members can't tell it exists. */
export async function findGroupForMember(groupId: ObjectId, userId: string): Promise<GroupDoc | null> {
  return (await groups()).findOne({ _id: groupId, 'members.userId': userId });
}

export async function listGroupsForMember(userId: string): Promise<GroupDoc[]> {
  return (await groups()).find({ 'members.userId': userId }).sort({ _id: -1 }).limit(200).toArray();
}

/** Adds a member unless they're already in. Returns the updated group. */
export async function addMember(groupId: ObjectId, member: MemberDoc): Promise<GroupDoc | null> {
  const col = await groups();
  await col.updateOne({ _id: groupId, 'members.userId': { $ne: member.userId } }, { $push: { members: member } });
  return col.findOne({ _id: groupId });
}
