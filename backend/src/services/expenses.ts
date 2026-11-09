import { badRequest } from '../domain/errors';
import { cents } from '../domain/money';
import { computeSplit, splitUserIds } from '../domain/split';
import { CreateExpenseDto, PageQueryDto } from '../dto';
import type { AuthedRequest, Response } from '../lib/http';
import { toObjectId } from '../repositories/collections';
import * as expensesRepo from '../repositories/expenses';
import { isMember, requireMembership } from './groups';
import { idempotent } from './idempotency';
import { expenseJson } from './serializers';

export async function createExpense(req: AuthedRequest, groupId: string): Promise<Response> {
  const group = await requireMembership(groupId, req.caller);
  const input = CreateExpenseDto.parse(req.body);

  if (!isMember(group, input.paidBy)) {
    throw badRequest('PAYER_NOT_MEMBER', 'The person who paid must be in the group');
  }
  const outsiders = splitUserIds(input.split).filter((id) => !isMember(group, id));
  if (outsiders.length > 0) {
    throw badRequest('SPLIT_USER_NOT_MEMBER', 'Everyone in the split must be in the group', { userIds: outsiders });
  }

  // The server computes every share. The client only says how to split.
  const splits = computeSplit(cents(input.amountCents), input.split);

  return idempotent(req, async (resourceId) => {
    const doc = await expensesRepo.insertExpenseOnce({
      _id: resourceId,
      groupId: group._id,
      description: input.description,
      amountCents: input.amountCents,
      paidBy: input.paidBy,
      splitType: input.split.type,
      splits,
      createdBy: req.caller.userId,
      createdAt: new Date(),
    });
    return { status: 201, body: expenseJson(doc) };
  });
}

export async function listExpenses(req: AuthedRequest, groupId: string): Promise<Response> {
  const group = await requireMembership(groupId, req.caller);
  const query = PageQueryDto.parse(req.query);
  const cursor = query.cursor ? toObjectId(query.cursor) ?? undefined : undefined;
  const page = await expensesRepo.listExpenses(group._id, { limit: query.limit, ...(cursor && { cursor }) });
  return { status: 200, body: { items: page.items.map(expenseJson), nextCursor: page.nextCursor } };
}
