// The groups collection. Members and invites live inside the group document, so each change to them is a
// single atomic update whose filter checks every rule at the moment of the write.
import { ObjectId, type Filter } from 'mongodb';
import { groups, NOT_DELETED, pageNewestFirst, type Page, type PageOptions } from './collections';
import type { GroupDoc, InviteDoc, MemberDoc } from './documents';

/** Inserts a new group and returns it with its _id. */
export async function insertGroup(doc: Omit<GroupDoc, '_id'>): Promise<GroupDoc> {
  const group: GroupDoc = { _id: new ObjectId(), ...doc };
  await (await groups()).insertOne(group);
  return group;
}

function memberOf(groupId: ObjectId, userId: string): Filter<GroupDoc> {
  return { _id: groupId, 'members.userId': userId, ...NOT_DELETED };
}

/** The group, if it isn't deleted and `userId` is a member. Otherwise null, so outsiders can't tell it exists. */
export async function findGroupForMember(groupId: ObjectId, userId: string): Promise<GroupDoc | null> {
  return (await groups()).findOne(memberOf(groupId, userId));
}

/** A live group whatever the caller's membership. Only for explaining why an invite write missed. */
export async function findLiveGroup(groupId: ObjectId): Promise<GroupDoc | null> {
  return (await groups()).findOne({ _id: groupId, ...NOT_DELETED });
}

/** One page of the user's live groups, newest first. */
export async function listGroupsForMember(userId: string, page: PageOptions): Promise<Page<GroupDoc>> {
  return pageNewestFirst(await groups(), { 'members.userId': userId, ...NOT_DELETED }, page);
}

/** Every live group the user is in. Used by account deletion. */
export async function listAllGroupsForMember(userId: string): Promise<GroupDoc[]> {
  return (await groups()).find({ 'members.userId': userId, ...NOT_DELETED }).toArray();
}

/** Renames the group if `userId` is still a member. Null otherwise. */
export async function renameGroup(groupId: ObjectId, userId: string, name: string): Promise<GroupDoc | null> {
  return (await groups()).findOneAndUpdate(
    memberOf(groupId, userId),
    { $set: { name, updatedAt: new Date() } },
    { returnDocument: 'after' },
  );
}

/** Marks the group deleted if `userId` is still a member. Returns whether it did. */
export async function softDeleteGroup(groupId: ObjectId, userId: string): Promise<boolean> {
  const now = new Date();
  const res = await (await groups()).updateOne(memberOf(groupId, userId), {
    $set: { deletedAt: now, deletedBy: userId, updatedAt: now },
  });
  return res.modifiedCount === 1;
}

// Members plus invites below `max`, as a filter, so the size check and the $push happen in one step.
function hasRoom(max: number): Filter<GroupDoc> {
  return {
    $expr: { $lt: [{ $add: [{ $size: '$members' }, { $size: { $ifNull: ['$invites', []] } }] }, max] },
  };
}

/**
 * Adds an invite if, at the moment of the write, the caller is a member, nobody in the group has that
 * email, it isn't already invited, and there's room. Null when any of those fails; the service reads
 * the group again to say which.
 */
export async function addInvite(
  groupId: ObjectId,
  callerId: string,
  invite: InviteDoc,
  maxSize: number,
): Promise<GroupDoc | null> {
  return (await groups()).findOneAndUpdate(
    {
      ...memberOf(groupId, callerId),
      'members.email': { $ne: invite.email },
      'invites.email': { $ne: invite.email },
      ...hasRoom(maxSize),
    },
    { $push: { invites: invite }, $set: { updatedAt: new Date() } },
    { returnDocument: 'after' },
  );
}

/** Removes an invite if the caller is a member and the invite exists. Null otherwise. */
export async function cancelInvite(groupId: ObjectId, callerId: string, inviteId: string): Promise<GroupDoc | null> {
  return (await groups()).findOneAndUpdate(
    { ...memberOf(groupId, callerId), 'invites.id': inviteId },
    { $pull: { invites: { id: inviteId } }, $set: { updatedAt: new Date() } },
    { returnDocument: 'after' },
  );
}

/** Live groups with a pending invite for this email, newest first, at most 100. */
export async function findGroupsInviting(email: string): Promise<GroupDoc[]> {
  return (await groups()).find({ 'invites.email': email, ...NOT_DELETED }).sort({ _id: -1 }).limit(100).toArray();
}

/**
 * Accepts an invite in one atomic update. The invite must still be there for this email, the user
 * must not be a member yet, and the group must have fewer than `maxMembers` members. The invite is
 * pulled and the member pushed together, so two taps or two devices can't add the same person twice.
 */
export async function acceptInvite(
  groupId: ObjectId,
  inviteId: string,
  member: MemberDoc,
  maxMembers: number,
): Promise<GroupDoc | null> {
  return (await groups()).findOneAndUpdate(
    {
      _id: groupId,
      ...NOT_DELETED,
      invites: { $elemMatch: { id: inviteId, email: member.email } },
      'members.userId': { $ne: member.userId },
      // No element at index maxMembers - 1 means fewer than maxMembers members.
      [`members.${maxMembers - 1}`]: { $exists: false },
    },
    {
      $pull: { invites: { email: member.email } },
      $push: { members: member },
      $set: { updatedAt: new Date() },
    },
    { returnDocument: 'after' },
  );
}

/** Removes any invite for `email` from a group the user already belongs to. Tidies up after a retried accept. */
export async function pullInvitesFor(groupId: ObjectId, userId: string, email: string): Promise<GroupDoc | null> {
  return (await groups()).findOneAndUpdate(
    memberOf(groupId, userId),
    { $pull: { invites: { email } } },
    { returnDocument: 'after' },
  );
}

/** Removes an invite addressed to `email`. Returns whether there was one. */
export async function declineInvite(groupId: ObjectId, inviteId: string, email: string): Promise<boolean> {
  const res = await (await groups()).updateOne(
    { _id: groupId, ...NOT_DELETED, invites: { $elemMatch: { id: inviteId, email } } },
    { $pull: { invites: { id: inviteId } }, $set: { updatedAt: new Date() } },
  );
  return res.modifiedCount === 1;
}

/**
 * Removes `userId` from the group, as long as `byUserId` is still a member. They're the same person
 * when someone leaves. Null when either isn't a member.
 */
export async function removeMember(groupId: ObjectId, userId: string, byUserId: string): Promise<GroupDoc | null> {
  const required = [...new Set([userId, byUserId])];
  return (await groups()).findOneAndUpdate(
    { _id: groupId, ...NOT_DELETED, 'members.userId': { $all: required } },
    { $pull: { members: { userId } }, $set: { updatedAt: new Date() } },
    { returnDocument: 'after' },
  );
}

/** Deletes the group if nobody is left in it. Its pending invites go with it. */
export async function softDeleteIfEmpty(groupId: ObjectId, byUserId: string): Promise<void> {
  const now = new Date();
  await (await groups()).updateOne(
    { _id: groupId, members: { $size: 0 }, ...NOT_DELETED },
    { $set: { deletedAt: now, deletedBy: byUserId, updatedAt: now } },
  );
}

/** Rewrites the member's name and email in every group where they're out of date. */
export async function refreshMemberSnapshots(userId: string, email: string, name: string): Promise<void> {
  await (await groups()).updateMany(
    { members: { $elemMatch: { userId, $or: [{ name: { $ne: name } }, { email: { $ne: email } }] } } },
    { $set: { 'members.$[m].name': name, 'members.$[m].email': email } },
    { arrayFilters: [{ 'm.userId': userId }] },
  );
}
