import { ObjectId, type Filter } from 'mongodb';
import {
  groups,
  NOT_DELETED,
  pageNewestFirst,
  type GroupDoc,
  type InviteDoc,
  type MemberDoc,
  type Page,
} from './collections';

export async function insertGroup(doc: Omit<GroupDoc, '_id'>): Promise<GroupDoc> {
  const withId: GroupDoc = { _id: new ObjectId(), ...doc };
  await (await groups()).insertOne(withId);
  return withId;
}

const memberOf = (groupId: ObjectId, userId: string): Filter<GroupDoc> => ({
  _id: groupId,
  'members.userId': userId,
  ...NOT_DELETED,
});

/** Returns the group only if `userId` is a member and it isn't deleted. Non-members can't tell it exists. */
export async function findGroupForMember(groupId: ObjectId, userId: string): Promise<GroupDoc | null> {
  return (await groups()).findOne(memberOf(groupId, userId));
}

/** A live group regardless of membership. Only for telling apart *why* an invite write missed. */
export async function findLiveGroup(groupId: ObjectId): Promise<GroupDoc | null> {
  return (await groups()).findOne({ _id: groupId, ...NOT_DELETED });
}

export async function listGroupsForMember(
  userId: string,
  opts: { limit: number; cursor?: ObjectId | undefined },
): Promise<Page<GroupDoc>> {
  return pageNewestFirst(await groups(), { 'members.userId': userId, ...NOT_DELETED }, opts);
}

/** Every live group the user is in, for account deletion. */
export async function listAllGroupsForMember(userId: string): Promise<GroupDoc[]> {
  return (await groups()).find({ 'members.userId': userId, ...NOT_DELETED }).toArray();
}

export async function renameGroup(groupId: ObjectId, userId: string, name: string): Promise<GroupDoc | null> {
  return (await groups()).findOneAndUpdate(
    memberOf(groupId, userId),
    { $set: { name, updatedAt: new Date() } },
    { returnDocument: 'after' },
  );
}

export async function softDeleteGroup(groupId: ObjectId, userId: string): Promise<boolean> {
  const now = new Date();
  const res = await (await groups()).updateOne(memberOf(groupId, userId), {
    $set: { deletedAt: now, deletedBy: userId, updatedAt: now },
  });
  return res.modifiedCount === 1;
}

/** members + invites < max, written as a query so the size check and the $push are one atomic step. */
const hasRoom = (max: number) => ({
  $expr: { $lt: [{ $add: [{ $size: '$members' }, { $size: { $ifNull: ['$invites', []] } }] }, max] },
});

/**
 * Adds an invite only if, at the moment of the write: the caller is a member, nobody in the group has
 * that email, it isn't invited yet, and there's room. Null when any of those failed; the service reads
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

export async function cancelInvite(groupId: ObjectId, callerId: string, inviteId: string): Promise<GroupDoc | null> {
  return (await groups()).findOneAndUpdate(
    { ...memberOf(groupId, callerId), 'invites.id': inviteId },
    { $pull: { invites: { id: inviteId } }, $set: { updatedAt: new Date() } },
    { returnDocument: 'after' },
  );
}

/** Live groups with a pending invite for this (verified) email. */
export async function findGroupsInviting(email: string): Promise<GroupDoc[]> {
  return (await groups()).find({ 'invites.email': email, ...NOT_DELETED }).sort({ _id: -1 }).limit(100).toArray();
}

/**
 * Accepting is one atomic update: the invite must still be there and addressed to this email, the
 * caller must not be a member yet, and there must be fewer than `maxMembers` members. Then the invite is
 * pulled and the member pushed together, so two taps (or two devices) can't add the same person twice.
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

/** Removes any invite for `email` from a group the caller already belongs to (a retried accept). */
export async function pullInvitesFor(groupId: ObjectId, userId: string, email: string): Promise<GroupDoc | null> {
  return (await groups()).findOneAndUpdate(
    memberOf(groupId, userId),
    { $pull: { invites: { email } } },
    { returnDocument: 'after' },
  );
}

export async function declineInvite(groupId: ObjectId, inviteId: string, email: string): Promise<boolean> {
  const res = await (await groups()).updateOne(
    { _id: groupId, ...NOT_DELETED, invites: { $elemMatch: { id: inviteId, email } } },
    { $pull: { invites: { id: inviteId } }, $set: { updatedAt: new Date() } },
  );
  return res.modifiedCount === 1;
}

/**
 * Removes `userId` from the group, provided `byUserId` (who may be the same person: leaving) is still a
 * member. The group is soft-deleted by the caller when nobody is left (see softDeleteIfEmpty).
 */
export async function removeMember(groupId: ObjectId, userId: string, byUserId: string): Promise<GroupDoc | null> {
  const required = [...new Set([userId, byUserId])];
  return (await groups()).findOneAndUpdate(
    { _id: groupId, ...NOT_DELETED, 'members.userId': { $all: required } },
    { $pull: { members: { userId } }, $set: { updatedAt: new Date() } },
    { returnDocument: 'after' },
  );
}

/** The last member left: the group is gone for everyone (pending invites with it). */
export async function softDeleteIfEmpty(groupId: ObjectId, byUserId: string): Promise<void> {
  const now = new Date();
  await (await groups()).updateOne(
    { _id: groupId, members: { $size: 0 }, ...NOT_DELETED },
    { $set: { deletedAt: now, deletedBy: byUserId, updatedAt: now } },
  );
}

/** Rewrites the member's name/email snapshot in every group where it's out of date. */
export async function refreshMemberSnapshots(userId: string, email: string, name: string): Promise<void> {
  await (await groups()).updateMany(
    { members: { $elemMatch: { userId, $or: [{ name: { $ne: name } }, { email: { $ne: email } }] } } },
    { $set: { 'members.$[m].name': name, 'members.$[m].email': email } },
    { arrayFilters: [{ 'm.userId': userId }] },
  );
}
