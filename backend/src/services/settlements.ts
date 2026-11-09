import { AppError, badRequest } from '../domain/errors';
import { CreateSettlementDto } from '../dto';
import type { AuthedRequest, Response } from '../lib/http';
import * as settlementsRepo from '../repositories/settlements';
import { isMember, requireMembership } from './groups';
import { idempotent } from './idempotency';
import { settlementJson } from './serializers';

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
  if (req.caller.userId !== input.fromUserId && req.caller.userId !== input.toUserId) {
    throw new AppError(403, 'NOT_A_PARTY', 'You can only record a payment you made or received');
  }

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
  const items = await settlementsRepo.listSettlements(group._id);
  return { status: 200, body: { items: items.map(settlementJson) } };
}
