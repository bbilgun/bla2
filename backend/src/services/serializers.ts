import type { ExpenseDoc, GroupDoc, SettlementDoc } from '../repositories/collections';

/** Mongo documents -> JSON the app sees. ObjectIds become hex strings, dates become ISO strings. */

export const groupJson = (g: GroupDoc) => ({
  id: g._id.toHexString(),
  name: g.name,
  currency: g.currency,
  members: g.members.map((m) => ({ userId: m.userId, email: m.email, name: m.name })),
  invites: (g.invites ?? []).map((i) => ({
    id: i.id,
    email: i.email,
    invitedBy: i.invitedBy,
    createdAt: i.createdAt.toISOString(),
  })),
  createdBy: g.createdBy,
  createdAt: g.createdAt.toISOString(),
});

export const expenseJson = (e: ExpenseDoc) => ({
  id: e._id.toHexString(),
  groupId: e.groupId.toHexString(),
  description: e.description,
  amountCents: e.amountCents,
  paidBy: e.paidBy,
  splitType: e.splitType,
  splits: e.splits,
  hasReceipt: Boolean(e.receiptKey),
  version: e.version ?? 1,
  createdBy: e.createdBy,
  createdAt: e.createdAt.toISOString(),
  updatedAt: e.updatedAt?.toISOString() ?? null,
  updatedBy: e.updatedBy ?? null,
});

export const settlementJson = (s: SettlementDoc) => ({
  id: s._id.toHexString(),
  groupId: s.groupId.toHexString(),
  fromUserId: s.fromUserId,
  toUserId: s.toUserId,
  amountCents: s.amountCents,
  createdBy: s.createdBy,
  createdAt: s.createdAt.toISOString(),
});
