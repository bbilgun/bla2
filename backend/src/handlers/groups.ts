// Routes for groups, members and invites. Each one hands the request to services/groups.ts.
import { requireParam, withHandler } from '../lib/http';
import * as groups from '../services/groups';

/** POST /groups: create a group with the caller as its only member. */
export const create = withHandler((req) => groups.createGroup(req));

/** GET /groups?limit=50&cursor=<id>: the caller's groups, newest first. */
export const list = withHandler((req) => groups.listMyGroups(req));

/** GET /groups/{groupId} */
export const get = withHandler((req) => groups.getGroup(req, requireParam(req, 'groupId')));

/** PATCH /groups/{groupId} with { name }. */
export const rename = withHandler((req) => groups.renameGroup(req, requireParam(req, 'groupId')));

/** DELETE /groups/{groupId}: soft delete, only when every balance is zero. */
export const remove = withHandler((req) => groups.deleteGroup(req, requireParam(req, 'groupId')));

/** POST /groups/{groupId}/invites with { email }. */
export const invite = withHandler((req) => groups.inviteToGroup(req, requireParam(req, 'groupId')));

/** DELETE /groups/{groupId}/invites/{inviteId}: a member withdraws a pending invite. */
export const cancelInvite = withHandler((req) =>
  groups.cancelInvite(req, requireParam(req, 'groupId'), requireParam(req, 'inviteId')),
);

/** GET /invites: pending invites for the caller's verified email. */
export const listInvites = withHandler((req) => groups.listMyInvites(req));

/** POST /groups/{groupId}/invites/{inviteId}/accept */
export const acceptInvite = withHandler((req) =>
  groups.acceptInvite(req, requireParam(req, 'groupId'), requireParam(req, 'inviteId')),
);

/** POST /groups/{groupId}/invites/{inviteId}/decline */
export const declineInvite = withHandler((req) =>
  groups.declineInvite(req, requireParam(req, 'groupId'), requireParam(req, 'inviteId')),
);

/** POST /groups/{groupId}/leave: only with a zero balance. */
export const leave = withHandler((req) => groups.leaveGroup(req, requireParam(req, 'groupId')));

/** DELETE /groups/{groupId}/members/{userId}: remove someone else, only with a zero balance. */
export const removeMember = withHandler((req) =>
  groups.removeMember(req, requireParam(req, 'groupId'), requireParam(req, 'userId')),
);
