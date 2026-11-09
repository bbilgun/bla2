import { AddMemberDto, CreateGroupDto } from '../dto';
import { requireParam, withHandler } from '../lib/http';
import * as groups from '../services/groups';
import { groupJson } from '../services/serializers';

/** POST /groups */
export const create = withHandler(async (req) => {
  const group = await groups.createGroup(req.caller, CreateGroupDto.parse(req.body));
  return { status: 201, body: groupJson(group) };
});

/** GET /groups — groups the caller belongs to */
export const list = withHandler(async (req) => {
  const items = await groups.listMyGroups(req.caller);
  return { status: 200, body: { items: items.map(groupJson) } };
});

/** GET /groups/{groupId} */
export const get = withHandler(async (req) => {
  const group = await groups.requireMembership(requireParam(req, 'groupId'), req.caller);
  return { status: 200, body: groupJson(group) };
});

/** POST /groups/{groupId}/members  { email } */
export const addMember = withHandler(async (req) => {
  const groupId = requireParam(req, 'groupId');
  await groups.requireMembership(groupId, req.caller); // outsiders get 404 before body validation
  const group = await groups.addMember(req.caller, groupId, AddMemberDto.parse(req.body));
  return { status: 200, body: groupJson(group) };
});
