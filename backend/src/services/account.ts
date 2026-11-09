// The caller's own account: their profile, the bank QR image shown on their bills, and deleting it all.
import { conflict } from '../domain/errors';
import { ConfirmUploadDto, ImageUploadDto } from '../dto';
import { deleteCognitoUser } from '../lib/cognito';
import type { AuthedRequest, Response } from '../lib/http';
import { deleteObject, signUpload, signView } from '../lib/s3';
import { deleteBillsForHost } from '../repositories/bills';
import { listAllGroupsForMember } from '../repositories/groups';
import { deleteKeysForUser } from '../repositories/idempotency';
import { deleteUser, findUser, setPayQrKey } from '../repositories/users';
import { leaveUnchecked, netOf } from './groups';
import { discardReplaced, newImageKey, requireUploadedKey } from './uploads';
import { registerCaller } from './users';

// Each user's bank QR lives under their own prefix, so nobody can confirm someone else's upload.
function payQrPrefix(userId: string): string {
  return `users/${userId}/pay-qr/`;
}

/**
 * The caller, from their token. Also records them (see registerCaller) and returns the bank details
 * and QR image saved from their last bill, so the app can pre-fill the next one.
 */
export async function getMe(req: AuthedRequest): Promise<Response> {
  const user = await registerCaller(req.caller);
  const payQrUrl = user.payQrKey ? await signView(user.payQrKey) : null;
  return {
    status: 200,
    body: {
      userId: user._id,
      email: user.email,
      name: user.name,
      emailVerified: req.caller.emailVerified,
      payment: user.payment ?? null,
      payQrUrl,
    },
  };
}

/** Signs an upload for a screenshot of the caller's bank-app "receive money" QR. Nothing is saved yet. */
export async function createPayQrUploadUrl(req: AuthedRequest): Promise<Response> {
  const { contentType } = ImageUploadDto.parse(req.body);
  const key = newImageKey(payQrPrefix(req.caller.userId), contentType);
  return { status: 200, body: await signUpload(key, contentType) };
}

/** Saves an uploaded bank QR. Every bill shows it from now on, and the old image is deleted. */
export async function confirmPayQr(req: AuthedRequest): Promise<Response> {
  const { key } = ConfirmUploadDto.parse(req.body);
  await requireUploadedKey(key, payQrPrefix(req.caller.userId));
  await registerCaller(req.caller);

  const previous = await setPayQrKey(req.caller.userId, key);
  await discardReplaced(previous, key, req.log);
  return { status: 200, body: { payQrUrl: await signView(key) } };
}

/**
 * Deletes the caller's account. Refused with 409 while they have a balance in any group, since that
 * money would be stranded. Each step is safe to re-run if a later one fails, and the Cognito user goes
 * last so the same token still works for a retry. Their expenses and settlements stay with the groups.
 */
export async function deleteAccount(req: AuthedRequest): Promise<Response> {
  const userId = req.caller.userId;
  const groups = await listAllGroupsForMember(userId);

  const unsettled: { groupId: string; name: string }[] = [];
  for (const group of groups) {
    if ((await netOf(group, userId)) !== 0) {
      unsettled.push({ groupId: group._id.toHexString(), name: group.name });
    }
  }
  if (unsettled.length > 0) {
    throw conflict('BALANCES_NOT_ZERO', 'Settle up in these groups before deleting your account', unsettled);
  }

  for (const group of groups) {
    await leaveUnchecked(group, userId);
  }
  await deleteBillsForHost(userId);

  const user = await findUser(userId);
  // This one must succeed: once the users row is gone, nothing points at the image.
  if (user?.payQrKey) await deleteObject(user.payQrKey);
  await deleteUser(userId);
  await deleteKeysForUser(userId);
  await deleteCognitoUser(userId);

  req.log.info('account.deleted', { groupsLeft: groups.length });
  return { status: 200, body: { deleted: true } };
}
