import { badRequest, forbidden, notFound } from '../domain/errors';
import { CreateSettlementDto, PageQueryDto } from '../dto';
import type { AuthedRequest, Response } from '../lib/http';
import { toObjectId } from '../repositories/collections';
import * as settlementsRepo from '../repositories/settlements';
import { isMember, requireMembership } from './groups';
import { idempotent } from './idempotency';
import { settlementJson } from './serializers';

const notAParty = () => forbidden('NOT_A_PARTY', 'You can only record or delete a payment you made or received');

/**
 * Records "from paid to amountCents". Either side of the payment can record it,
 * but nobody can record a payment between two other people.
 */
export async function createSettlement(req: AuthedRequest, groupId: string): Promise<Response> {
  const group = await requireMembership(groupId, req.caller);
  const input = CreateSettlementDto.parse(req.body);

  if (!isMember(group, input.fromUserId) || !isMember(group, input.toUserId)) {
    throw badRequest('SETTLEMENT_USER_NOT_MEMBER', 'Both people must be in the group');
  }
  if (req.caller.userId !== input.fromUserId && req.caller.userId !== input.toUserId) throw notAParty();

  return idempotent(req, async (resourceId) => {
    const doc = await settlementsRepo.insertSettlementOnce({
      _id: resourceId,
      groupId: group._id,
      fromUserId: input.fromUserId,
      toUserId: input.toUserId,
      amountCents: input.amountCents,
      createdBy: req.caller.userId,
      createdAt: new Date(),
    });
    return { status: 201, body: settlementJson(doc) };
  });
}

export async function listSettlements(req: AuthedRequest, groupId: string): Promise<Response> {
  const group = await requireMembership(groupId, req.caller);
  const query = PageQueryDto.parse(req.query);
  const cursor = query.cursor ? (toObjectId(query.cursor) ?? undefined) : undefined;
  const page = await settlementsRepo.listSettlements(group._id, { limit: query.limit, cursor });
  return { status: 200, body: { items: page.items.map(settlementJson), nextCursor: page.nextCursor } };
}

/** Soft delete, only by one of the two people in the payment. Deleting twice is fine. */
export async function deleteSettlement(req: AuthedRequest, groupId: string, settlementId: string): Promise<Response> {
  const group = await requireMembership(groupId, req.caller);
  const id = toObjectId(settlementId);
  const settlement = id ? await settlementsRepo.findSettlementAnyState(group._id, id) : null;
  if (!settlement) throw notFound('SETTLEMENT_NOT_FOUND', 'Payment not found');
  if (req.caller.userId !== settlement.fromUserId && req.caller.userId !== settlement.toUserId) throw notAParty();
  if (!settlement.deletedAt) await settlementsRepo.softDeleteSettlement(group._id, settlement._id, req.caller.userId);
  return { status: 200, body: { id: settlement._id.toHexString(), deleted: true } };
}
