import { notFound } from '../domain/errors';
import type { AddMemberDto, CreateGroupDto } from '../dto';
import type { Caller } from '../lib/http';
import { toObjectId, type GroupDoc } from '../repositories/collections';
import * as groupsRepo from '../repositories/groups';
import { findUserByEmail, upsertUser } from '../repositories/users';

/**
 * The membership check every group-scoped route starts with.
 *
 * An outsider gets 404 GROUP_NOT_FOUND, exactly like a group that doesn't exist.
 * A 403 would confirm "this group is real, you just can't see it", which leaks that ids are valid.
 */
export async function requireMembership(groupId: string, caller: Caller): Promise<GroupDoc> {
  const id = toObjectId(groupId);
  const group = id ? await groupsRepo.findGroupForMember(id, caller.userId) : null;
  if (!group) throw notFound('GROUP_NOT_FOUND', 'Group not found');
  return group;
}

export function isMember(group: GroupDoc, userId: string): boolean {
  return group.members.some((m) => m.userId === userId);
}

export async function createGroup(caller: Caller, input: CreateGroupDto): Promise<GroupDoc> {
  await upsertUser(caller);
  const now = new Date();
  return groupsRepo.insertGroup({
    name: input.name,
    currency: input.currency,
    members: [{ userId: caller.userId, email: caller.email, name: caller.name, joinedAt: now }],
    createdBy: caller.userId,
    createdAt: now,
  });
}

export async function listMyGroups(caller: Caller): Promise<GroupDoc[]> {
  return groupsRepo.listGroupsForMember(caller.userId);
}

/** Any member can add someone by email. They must have signed in to NetZero at least once. */
export async function addMember(caller: Caller, groupId: string, input: AddMemberDto): Promise<GroupDoc> {
  const group = await requireMembership(groupId, caller);
  const user = await findUserByEmail(input.email);
  if (!user) {
    throw notFound('USER_NOT_FOUND', `No NetZero account for ${input.email}. Ask them to sign in to the app once first.`);
  }
  if (isMember(group, user._id)) return group;
  const updated = await groupsRepo.addMember(group._id, {
    userId: user._id,
    email: user.email,
    name: user.name,
    joinedAt: new Date(),
  });
  if (!updated) throw notFound('GROUP_NOT_FOUND', 'Group not found');
  return updated;
}
