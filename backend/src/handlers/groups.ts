import { CreateGroupDto, InviteDto, pageQuery, RenameGroupDto } from '../dto';
import { requireParam, withHandler } from '../lib/http';
import * as groups from '../services/groups';
import { groupJson } from '../services/serializers';

/** POST /groups */
export const create = withHandler(async (req) => {
  const group = await groups.createGroup(req.caller, CreateGroupDto.parse(req.body));
  return { status: 201, body: groupJson(group) };
});

/** GET /groups?limit=50&cursor=<id> — groups the caller belongs to, newest first */
export const list = withHandler(async (req) => {
  const page = await groups.listMyGroups(req.caller, pageQuery(50).parse(req.query));
  return { status: 200, body: { items: page.items.map(groupJson), nextCursor: page.nextCursor } };
});

/** GET /groups/{groupId} */
export const get = withHandler(async (req) => {
  const group = await groups.requireMembership(requireParam(req, 'groupId'), req.caller);
  return { status: 200, body: groupJson(group) };
});

/** PATCH /groups/{groupId}  { name } */
export const rename = withHandler(async (req) => {
  const groupId = requireParam(req, 'groupId');
  await groups.requireMembership(groupId, req.caller); // outsiders get 404 before body validation
  const group = await groups.renameGroup(req.caller, groupId, RenameGroupDto.parse(req.body));
  return { status: 200, body: groupJson(group) };
});

/** DELETE /groups/{groupId} — soft delete, only when every balance is zero */
export const remove = withHandler(async (req) => ({
  status: 200,
  body: await groups.deleteGroup(req.caller, requireParam(req, 'groupId')),
}));

/** POST /groups/{groupId}/invites  { email } */
export const invite = withHandler(async (req) => {
  const groupId = requireParam(req, 'groupId');
  await groups.requireMembership(groupId, req.caller); // outsiders get 404 before body validation
  const group = await groups.inviteToGroup(req.caller, groupId, InviteDto.parse(req.body));
  return { status: 200, body: groupJson(group) };
});

/** DELETE /groups/{groupId}/invites/{inviteId} — a member cancels a pending invite */
export const cancelInvite = withHandler(async (req) => {
  const group = await groups.cancelInvite(req.caller, requireParam(req, 'groupId'), requireParam(req, 'inviteId'));
  return { status: 200, body: groupJson(group) };
});

/** GET /invites — pending invites for the caller's verified email */
export const listInvites = withHandler(async (req) => ({
  status: 200,
  body: { items: await groups.listMyInvites(req.caller) },
}));

/** POST /groups/{groupId}/invites/{inviteId}/accept */
export const acceptInvite = withHandler(async (req) => {
  const group = await groups.acceptInvite(req.caller, requireParam(req, 'groupId'), requireParam(req, 'inviteId'));
  return { status: 200, body: groupJson(group) };
});

/** POST /groups/{groupId}/invites/{inviteId}/decline */
export const declineInvite = withHandler(async (req) => ({
  status: 200,
  body: await groups.declineInvite(req.caller, requireParam(req, 'groupId'), requireParam(req, 'inviteId')),
}));

/** POST /groups/{groupId}/leave — only with a zero balance */
export const leave = withHandler(async (req) => ({
  status: 200,
  body: await groups.leaveGroup(req.caller, requireParam(req, 'groupId')),
}));

/** DELETE /groups/{groupId}/members/{userId} — remove someone else, only with a zero balance */
export const removeMember = withHandler(async (req) => {
  const group = await groups.removeMember(req.caller, requireParam(req, 'groupId'), requireParam(req, 'userId'));
  return { status: 200, body: groupJson(group) };
});
