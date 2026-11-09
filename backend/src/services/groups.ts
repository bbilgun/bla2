// Groups, membership and invites. Every group route starts with requireMembership, so anyone outside
// the group gets the same 404 as for a group that doesn't exist.
import { randomBytes } from 'node:crypto';
import { computeBalances } from '../aggregations/balances';
import { badRequest, conflict, notFound } from '../domain/errors';
import { CreateGroupDto, InviteDto, pageQuery, RenameGroupDto } from '../dto';
import type { AuthedRequest, Caller, Response } from '../lib/http';
import { toObjectId } from '../repositories/collections';
import type { GroupDoc } from '../repositories/documents';
import * as groupsRepo from '../repositories/groups';
import { groupJson } from './serializers';
import { registerCaller } from './users';

/** Most members plus pending invites in one group. Keeps the embedded arrays, and every split, small. */
const MAX_GROUP_SIZE = 50;

const GroupPageQuery = pageQuery(50);

const groupNotFound = () => notFound('GROUP_NOT_FOUND', 'Group not found');
const inviteNotFound = () => notFound('INVITE_NOT_FOUND', 'Invite not found');
const memberNotFound = () => notFound('MEMBER_NOT_FOUND', 'That person is not in this group');
const groupFull = () => conflict('GROUP_FULL', `A group can have at most ${MAX_GROUP_SIZE} members and invites`);
const balanceNotZero = () =>
  conflict('BALANCE_NOT_ZERO', 'Settle up first: this person still owes or is owed money in the group');
const newInviteId = () => randomBytes(12).toString('base64url');

/**
 * Loads a group the caller belongs to. A group they're not in, a deleted group and a malformed id all
 * throw the same 404 GROUP_NOT_FOUND, so a stranger can't tell whether a group id is real.
 */
export async function requireMembership(groupId: string, caller: Caller): Promise<GroupDoc> {
  const id = toObjectId(groupId);
  const group = id ? await groupsRepo.findGroupForMember(id, caller.userId) : null;
  if (!group) throw groupNotFound();
  return group;
}

/** Whether `userId` is a current member of the group. */
export function isMember(group: GroupDoc, userId: string): boolean {
  return group.members.some((member) => member.userId === userId);
}

// Net cents per user, derived from the ledger right now. Someone with no entries is missing, meaning zero.
async function netByUser(group: GroupDoc): Promise<Map<string, number>> {
  const rows = await computeBalances(group._id);
  return new Map(rows.map((row) => [row.userId, row.netCents]));
}

/** The user's net balance in the group, in cents. Zero means they're settled up. */
export async function netOf(group: GroupDoc, userId: string): Promise<number> {
  const net = await netByUser(group);
  return net.get(userId) ?? 0;
}

/** Creates a group with the caller as its only member. */
export async function createGroup(req: AuthedRequest): Promise<Response> {
  const input = CreateGroupDto.parse(req.body);
  await registerCaller(req.caller);

  const now = new Date();
  const group = await groupsRepo.insertGroup({
    name: input.name,
    currency: input.currency,
    members: [{ userId: req.caller.userId, email: req.caller.email, name: req.caller.name, joinedAt: now }],
    invites: [],
    createdBy: req.caller.userId,
    createdAt: now,
  });
  return { status: 201, body: groupJson(group) };
}

/** One page of the caller's groups, newest first. */
export async function listMyGroups(req: AuthedRequest): Promise<Response> {
  const query = GroupPageQuery.parse(req.query);
  const page = await groupsRepo.listGroupsForMember(req.caller.userId, query);
  return { status: 200, body: { items: page.items.map(groupJson), nextCursor: page.nextCursor } };
}

/** One group the caller belongs to. */
export async function getGroup(req: AuthedRequest, groupId: string): Promise<Response> {
  const group = await requireMembership(groupId, req.caller);
  return { status: 200, body: groupJson(group) };
}

/** Renames the group. Any member may. */
export async function renameGroup(req: AuthedRequest, groupId: string): Promise<Response> {
  const group = await requireMembership(groupId, req.caller);
  const input = RenameGroupDto.parse(req.body);

  const updated = await groupsRepo.renameGroup(group._id, req.caller.userId, input.name);
  if (!updated) throw groupNotFound();
  return { status: 200, body: groupJson(updated) };
}

/** Soft-deletes the group. Any member may, but only once every balance in it is zero. */
export async function deleteGroup(req: AuthedRequest, groupId: string): Promise<Response> {
  const group = await requireMembership(groupId, req.caller);
  const net = await netByUser(group);
  const someoneOwes = [...net.values()].some((cents) => cents !== 0);
  if (someoneOwes) {
    throw conflict('BALANCES_NOT_ZERO', 'Settle up first: someone in this group still owes or is owed money');
  }

  const deleted = await groupsRepo.softDeleteGroup(group._id, req.caller.userId);
  if (!deleted) throw groupNotFound();
  return { status: 200, body: { id: group._id.toHexString(), deleted: true } };
}

// Invites

/**
 * Invites an email address. Any member may, and the address doesn't need an account yet: the invite
 * waits until someone signs in with that email verified. Inviting the same email twice changes nothing.
 */
export async function inviteToGroup(req: AuthedRequest, groupId: string): Promise<Response> {
  const group = await requireMembership(groupId, req.caller);
  const input = InviteDto.parse(req.body);

  const invite = {
    id: newInviteId(),
    email: input.email,
    invitedBy: req.caller.userId,
    invitedByName: req.caller.name,
    createdAt: new Date(),
  };
  const updated = await groupsRepo.addInvite(group._id, req.caller.userId, invite, MAX_GROUP_SIZE);
  if (updated) return { status: 200, body: groupJson(updated) };

  // The atomic write said no. Read the group again to say why.
  const latest = await requireMembership(groupId, req.caller);
  if (latest.members.some((member) => member.email === input.email)) {
    throw conflict('ALREADY_MEMBER', 'Someone in this group already has that email');
  }
  if ((latest.invites ?? []).some((pending) => pending.email === input.email)) {
    return { status: 200, body: groupJson(latest) };
  }
  throw groupFull();
}

/** Withdraws a pending invite. Any member may. */
export async function cancelInvite(req: AuthedRequest, groupId: string, inviteId: string): Promise<Response> {
  const group = await requireMembership(groupId, req.caller);
  const updated = await groupsRepo.cancelInvite(group._id, req.caller.userId, inviteId);
  if (!updated) throw inviteNotFound();
  return { status: 200, body: groupJson(updated) };
}

/**
 * Invites addressed to the caller's email. Someone whose email isn't verified sees none, because
 * anyone can type any email at sign-up.
 */
export async function listMyInvites(req: AuthedRequest): Promise<Response> {
  const { caller } = req;
  if (!caller.emailVerified) return { status: 200, body: { items: [] } };

  const groups = await groupsRepo.findGroupsInviting(caller.email);
  const items = groups
    .filter((group) => !isMember(group, caller.userId))
    .flatMap((group) =>
      (group.invites ?? [])
        .filter((invite) => invite.email === caller.email)
        .map((invite) => ({
          id: invite.id,
          groupId: group._id.toHexString(),
          groupName: group.name,
          currency: group.currency,
          memberCount: group.members.length,
          // Prefer the inviter's current name, if they're still in the group.
          invitedByName: group.members.find((member) => member.userId === invite.invitedBy)?.name ?? invite.invitedByName,
          createdAt: invite.createdAt.toISOString(),
        })),
    );
  return { status: 200, body: { items } };
}

/**
 * Joins the group through an invite addressed to the caller's verified email. Anyone else gets 404
 * INVITE_NOT_FOUND, because the invite id alone proves nothing. Accepting again is a 200.
 */
export async function acceptInvite(req: AuthedRequest, groupId: string, inviteId: string): Promise<Response> {
  const { caller } = req;
  const id = toObjectId(groupId);
  if (!id || !caller.emailVerified) throw inviteNotFound();
  await registerCaller(caller);

  const member = { userId: caller.userId, email: caller.email, name: caller.name, joinedAt: new Date() };
  const joined = await groupsRepo.acceptInvite(id, inviteId, member, MAX_GROUP_SIZE);
  if (joined) return { status: 200, body: groupJson(joined) };

  // The atomic write said no. Work out why.
  const group = await groupsRepo.findLiveGroup(id);
  if (!group) throw inviteNotFound();
  if (isMember(group, caller.userId)) {
    // A retried accept whose first attempt went through. Tidy up any invite still addressed to them.
    const tidied = await groupsRepo.pullInvitesFor(id, caller.userId, caller.email);
    return { status: 200, body: groupJson(tidied ?? group) };
  }
  const inviteIsTheirs = (group.invites ?? []).some((invite) => invite.id === inviteId && invite.email === caller.email);
  if (inviteIsTheirs) throw groupFull();
  throw inviteNotFound();
}

/** Turns down an invite addressed to the caller's verified email. */
export async function declineInvite(req: AuthedRequest, groupId: string, inviteId: string): Promise<Response> {
  const { caller } = req;
  const id = toObjectId(groupId);
  if (!id || !caller.emailVerified) throw inviteNotFound();

  const declined = await groupsRepo.declineInvite(id, inviteId, caller.email);
  if (!declined) throw inviteNotFound();
  return { status: 200, body: { declined: true } };
}

// Leaving

/**
 * Leaves the group, once the caller's balance is zero. The last member out deletes the group. The balance
 * check and the removal are two steps, but expenses check membership when they're written, so the gap
 * is at most one request in flight.
 */
export async function leaveGroup(req: AuthedRequest, groupId: string): Promise<Response> {
  const group = await requireMembership(groupId, req.caller);
  if ((await netOf(group, req.caller.userId)) !== 0) throw balanceNotZero();

  await leaveUnchecked(group, req.caller.userId);
  return { status: 200, body: { left: true } };
}

/** Removes the user without checking their balance, and deletes the group if they were the last one. */
export async function leaveUnchecked(group: GroupDoc, userId: string): Promise<void> {
  const after = await groupsRepo.removeMember(group._id, userId, userId);
  if (after && after.members.length === 0) {
    await groupsRepo.softDeleteIfEmpty(group._id, userId);
  }
}

/** Removes someone else from the group, once their balance is zero. To remove yourself, leave. */
export async function removeMember(req: AuthedRequest, groupId: string, userId: string): Promise<Response> {
  const group = await requireMembership(groupId, req.caller);
  if (userId === req.caller.userId) {
    throw badRequest('CANNOT_REMOVE_SELF', 'To remove yourself, leave the group');
  }
  if (!isMember(group, userId)) throw memberNotFound();
  if ((await netOf(group, userId)) !== 0) throw balanceNotZero();

  const updated = await groupsRepo.removeMember(group._id, userId, req.caller.userId);
  if (!updated) {
    // Someone may have removed the caller in the meantime, which is a 404 for the group.
    await requireMembership(groupId, req.caller);
    throw memberNotFound();
  }
  return { status: 200, body: groupJson(updated) };
}
