import { randomBytes } from 'node:crypto';
import { computeBalances } from '../aggregations/balances';
import { badRequest, conflict, notFound } from '../domain/errors';
import type { CreateGroupDto, InviteDto, PageQueryDto, RenameGroupDto } from '../dto';
import type { Caller } from '../lib/http';
import { toObjectId, type GroupDoc, type Page } from '../repositories/collections';
import * as groupsRepo from '../repositories/groups';
import { registerCaller } from './users';

/** Members + pending invites. Keeps the embedded arrays (and every split) small. */
export const MAX_GROUP_SIZE = 50;

const groupNotFound = () => notFound('GROUP_NOT_FOUND', 'Group not found');
const inviteNotFound = () => notFound('INVITE_NOT_FOUND', 'Invite not found');
const groupFull = () => conflict('GROUP_FULL', `A group can have at most ${MAX_GROUP_SIZE} members and invites`);
const newInviteId = () => randomBytes(12).toString('base64url');

/**
 * The membership check every group-scoped route starts with.
 *
 * An outsider gets 404 GROUP_NOT_FOUND, exactly like a group that doesn't exist (or was deleted).
 * A 403 would confirm "this group is real, you just can't see it", which leaks that ids are valid.
 */
export async function requireMembership(groupId: string, caller: Caller): Promise<GroupDoc> {
  const id = toObjectId(groupId);
  const group = id ? await groupsRepo.findGroupForMember(id, caller.userId) : null;
  if (!group) throw groupNotFound();
  return group;
}

export function isMember(group: GroupDoc, userId: string): boolean {
  return group.members.some((m) => m.userId === userId);
}

/** userId -> net cents, derived from the ledger right now. Missing = 0. */
async function netByUser(group: GroupDoc): Promise<Map<string, number>> {
  const rows = await computeBalances(group._id);
  return new Map(rows.map((r) => [r.userId, r.netCents]));
}

/** Leaving with a non-zero balance would strand that money: the others couldn't settle with you. */
export async function netOf(group: GroupDoc, userId: string): Promise<number> {
  return (await netByUser(group)).get(userId) ?? 0;
}

export async function createGroup(caller: Caller, input: CreateGroupDto): Promise<GroupDoc> {
  await registerCaller(caller);
  const now = new Date();
  return groupsRepo.insertGroup({
    name: input.name,
    currency: input.currency,
    members: [{ userId: caller.userId, email: caller.email, name: caller.name, joinedAt: now }],
    invites: [],
    createdBy: caller.userId,
    createdAt: now,
  });
}

export async function listMyGroups(caller: Caller, query: PageQueryDto): Promise<Page<GroupDoc>> {
  return groupsRepo.listGroupsForMember(caller.userId, {
    limit: query.limit,
    cursor: query.cursor ? (toObjectId(query.cursor) ?? undefined) : undefined,
  });
}

export async function renameGroup(caller: Caller, groupId: string, input: RenameGroupDto): Promise<GroupDoc> {
  const group = await requireMembership(groupId, caller);
  const updated = await groupsRepo.renameGroup(group._id, caller.userId, input.name);
  if (!updated) throw groupNotFound();
  return updated;
}

/** Any member may delete the group, but only once every balance in it is zero. */
export async function deleteGroup(caller: Caller, groupId: string): Promise<{ id: string; deleted: true }> {
  const group = await requireMembership(groupId, caller);
  const net = await netByUser(group);
  if ([...net.values()].some((n) => n !== 0)) {
    throw conflict('BALANCES_NOT_ZERO', 'Settle up first: someone in this group still owes or is owed money');
  }
  if (!(await groupsRepo.softDeleteGroup(group._id, caller.userId))) throw groupNotFound();
  return { id: group._id.toHexString(), deleted: true };
}

// ---------------------------------------------------------------- invites

/**
 * Any member can invite an email. Nothing checks whether that email has an account: the invite waits
 * until someone signs in with it verified. Inviting the same email twice is a no-op.
 */
export async function inviteToGroup(caller: Caller, groupId: string, input: InviteDto): Promise<GroupDoc> {
  const group = await requireMembership(groupId, caller);
  const invite = {
    id: newInviteId(),
    email: input.email,
    invitedBy: caller.userId,
    invitedByName: caller.name,
    createdAt: new Date(),
  };
  const updated = await groupsRepo.addInvite(group._id, caller.userId, invite, MAX_GROUP_SIZE);
  if (updated) return updated;

  // The atomic write said no; read again to say why.
  const now = await requireMembership(groupId, caller);
  if (now.members.some((m) => m.email === input.email)) {
    throw conflict('ALREADY_MEMBER', 'Someone in this group already has that email');
  }
  if ((now.invites ?? []).some((i) => i.email === input.email)) return now;
  throw groupFull();
}

export async function cancelInvite(caller: Caller, groupId: string, inviteId: string): Promise<GroupDoc> {
  const group = await requireMembership(groupId, caller);
  const updated = await groupsRepo.cancelInvite(group._id, caller.userId, inviteId);
  if (!updated) throw inviteNotFound();
  return updated;
}

/** Invites addressed to the caller's verified email. An unverified email sees none (anyone can type any email at sign-up). */
export async function listMyInvites(caller: Caller) {
  if (!caller.emailVerified) return [];
  const found = await groupsRepo.findGroupsInviting(caller.email);
  return found
    .filter((g) => !isMember(g, caller.userId))
    .flatMap((g) =>
      (g.invites ?? [])
        .filter((i) => i.email === caller.email)
        .map((i) => ({
          id: i.id,
          groupId: g._id.toHexString(),
          groupName: g.name,
          currency: g.currency,
          memberCount: g.members.length,
          invitedByName: g.members.find((m) => m.userId === i.invitedBy)?.name ?? i.invitedByName,
          createdAt: i.createdAt.toISOString(),
        })),
    );
}

/**
 * Joins the group through an invite addressed to the caller's verified email. Anyone else gets
 * 404 INVITE_NOT_FOUND (never 403): the invite id alone proves nothing.
 */
export async function acceptInvite(caller: Caller, groupId: string, inviteId: string): Promise<GroupDoc> {
  const id = toObjectId(groupId);
  if (!id || !caller.emailVerified) throw inviteNotFound();
  await registerCaller(caller);

  const member = { userId: caller.userId, email: caller.email, name: caller.name, joinedAt: new Date() };
  const joined = await groupsRepo.acceptInvite(id, inviteId, member, MAX_GROUP_SIZE);
  if (joined) return joined;

  const group = await groupsRepo.findLiveGroup(id);
  if (!group) throw inviteNotFound();
  if (isMember(group, caller.userId)) {
    // A retried accept whose first attempt went through: you're in. Tidy any invite still addressed to you.
    return (await groupsRepo.pullInvitesFor(id, caller.userId, caller.email)) ?? group;
  }
  if ((group.invites ?? []).some((i) => i.id === inviteId && i.email === caller.email)) throw groupFull();
  throw inviteNotFound();
}

export async function declineInvite(caller: Caller, groupId: string, inviteId: string): Promise<{ declined: true }> {
  const id = toObjectId(groupId);
  if (!id || !caller.emailVerified || !(await groupsRepo.declineInvite(id, inviteId, caller.email))) {
    throw inviteNotFound();
  }
  return { declined: true };
}

// ---------------------------------------------------------------- leaving

const balanceNotZero = () =>
  conflict('BALANCE_NOT_ZERO', 'Settle up first: this person still owes or is owed money in the group');

/**
 * Leaves a group. Blocked while the caller's balance isn't zero. The last member out soft-deletes it.
 * (Balance check and removal are two steps; a write landing in between could still involve the leaver.
 * Expenses check membership on write, so that window is one in-flight request wide.)
 */
export async function leaveGroup(caller: Caller, groupId: string): Promise<{ left: true }> {
  const group = await requireMembership(groupId, caller);
  if ((await netOf(group, caller.userId)) !== 0) throw balanceNotZero();
  await leaveUnchecked(group, caller.userId);
  return { left: true };
}

/** Removes the user and deletes the group if they were the last one. Shared with account deletion. */
export async function leaveUnchecked(group: GroupDoc, userId: string): Promise<void> {
  const after = await groupsRepo.removeMember(group._id, userId, userId);
  if (after && after.members.length === 0) await groupsRepo.softDeleteIfEmpty(group._id, userId);
}

/** A member removing someone else (to remove yourself, leave). Blocked while their balance isn't zero. */
export async function removeMember(caller: Caller, groupId: string, userId: string): Promise<GroupDoc> {
  const group = await requireMembership(groupId, caller);
  if (userId === caller.userId) throw badRequest('CANNOT_REMOVE_SELF', 'To remove yourself, leave the group');
  if (!isMember(group, userId)) throw notFound('MEMBER_NOT_FOUND', 'That person is not in this group');
  if ((await netOf(group, userId)) !== 0) throw balanceNotZero();
  const updated = await groupsRepo.removeMember(group._id, userId, caller.userId);
  if (!updated) {
    await requireMembership(groupId, caller); // the caller may have been removed meanwhile
    throw notFound('MEMBER_NOT_FOUND', 'That person is not in this group');
  }
  return updated;
}
