import { conflict } from '../domain/errors';
import { deleteCognitoUser } from '../lib/cognito';
import type { AuthedRequest, Response } from '../lib/http';
import { deleteObject, signView } from '../lib/s3';
import { deleteBillsForHost } from '../repositories/bills';
import { listAllGroupsForMember } from '../repositories/groups';
import { deleteKeysForUser } from '../repositories/idempotency';
import { deleteUser, findUser } from '../repositories/users';
import { leaveUnchecked, netOf } from './groups';
import { registerCaller } from './users';

/**
 * GET /me — the caller, straight from the verified token's claims. Also records the user (and refreshes
 * their name/email in groups when it changed), and returns the bank details and QR image saved from
 * their last bill, to pre-fill the next one.
 */
export async function getMe(req: AuthedRequest): Promise<Response> {
  const user = await registerCaller(req.caller);
  return {
    status: 200,
    body: {
      userId: user._id,
      email: user.email,
      name: user.name,
      emailVerified: req.caller.emailVerified,
      payment: user.payment ?? null,
      payQrUrl: user.payQrKey ? await signView(user.payQrKey) : null,
    },
  };
}

/**
 * DELETE /me. Refused while the caller has a non-zero balance in any group (that money would be stranded).
 * Otherwise, in an order where every step is safe to re-run after a failure part-way:
 *   leave every group (the last member out soft-deletes it) -> hard-delete their bills -> delete the bank
 *   QR image -> delete the users row -> delete the Cognito user (last: until then the same token can retry).
 * Expenses and settlements stay with their groups; the person shows as a former member.
 */
export async function deleteAccount(req: AuthedRequest): Promise<Response> {
  const userId = req.caller.userId;
  const groups = await listAllGroupsForMember(userId);

  const unsettled: { groupId: string; name: string }[] = [];
  for (const group of groups) {
    if ((await netOf(group, userId)) !== 0) unsettled.push({ groupId: group._id.toHexString(), name: group.name });
  }
  if (unsettled.length > 0) {
    throw conflict('BALANCES_NOT_ZERO', 'Settle up in these groups before deleting your account', unsettled);
  }

  for (const group of groups) await leaveUnchecked(group, userId);
  await deleteBillsForHost(userId);
  const user = await findUser(userId);
  if (user?.payQrKey) await deleteObject(user.payQrKey); // must succeed: after the row is gone nothing points at it
  await deleteUser(userId);
  await deleteKeysForUser(userId);
  await deleteCognitoUser(userId);
  req.log.info('account.deleted', { groupsLeft: groups.length });
  return { status: 200, body: { deleted: true } };
}
