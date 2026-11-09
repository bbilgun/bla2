// Settlements: payments members record between themselves ("Bob paid Alice 5,000"). Only the two people
// in a payment may record or delete it.
import { badRequest, forbidden, notFound } from '../domain/errors';
import { CreateSettlementDto, PageQueryDto } from '../dto';
import type { AuthedRequest, Response } from '../lib/http';
import { toObjectId } from '../repositories/collections';
import * as settlementsRepo from '../repositories/settlements';
import { isMember, requireMembership } from './groups';
import { idempotent } from './idempotency';
import { settlementJson } from './serializers';

const notAParty = () => forbidden('NOT_A_PARTY', 'You can only record or delete a payment you made or received');

/** Records a payment. Either side may record it. Needs an Idempotency-Key. */
export async function createSettlement(req: AuthedRequest, groupId: string): Promise<Response> {
  const group = await requireMembership(groupId, req.caller);
  const input = CreateSettlementDto.parse(req.body);

  if (!isMember(group, input.fromUserId) || !isMember(group, input.toUserId)) {
    throw badRequest('SETTLEMENT_USER_NOT_MEMBER', 'Both people must be in the group');
  }
  const isParty = req.caller.userId === input.fromUserId || req.caller.userId === input.toUserId;
  if (!isParty) throw notAParty();

  return idempotent(req, async (resourceId) => {
    const settlement = await settlementsRepo.insertSettlementOnce({
      _id: resourceId,
      groupId: group._id,
      fromUserId: input.fromUserId,
      toUserId: input.toUserId,
      amountCents: input.amountCents,
      createdBy: req.caller.userId,
      createdAt: new Date(),
    });
    return { status: 201, body: settlementJson(settlement) };
  });
}

/** One page of the group's settlements, newest first. */
export async function listSettlements(req: AuthedRequest, groupId: string): Promise<Response> {
  const group = await requireMembership(groupId, req.caller);
  const query = PageQueryDto.parse(req.query);
  const page = await settlementsRepo.listSettlements(group._id, query);
  return { status: 200, body: { items: page.items.map(settlementJson), nextCursor: page.nextCursor } };
}

/** Soft-deletes a settlement. Only one of the two people in it may. Deleting twice is fine. */
export async function deleteSettlement(req: AuthedRequest, groupId: string, settlementId: string): Promise<Response> {
  const group = await requireMembership(groupId, req.caller);
  const id = toObjectId(settlementId);
  const settlement = id ? await settlementsRepo.findSettlementAnyState(group._id, id) : null;
  if (!settlement) throw notFound('SETTLEMENT_NOT_FOUND', 'Payment not found');

  const isParty = req.caller.userId === settlement.fromUserId || req.caller.userId === settlement.toUserId;
  if (!isParty) throw notAParty();

  if (!settlement.deletedAt) {
    await settlementsRepo.softDeleteSettlement(group._id, settlement._id, req.caller.userId);
  }
  return { status: 200, body: { id: settlement._id.toHexString(), deleted: true } };
}
