// Turns stored documents into the JSON the app sees. ObjectIds become hex strings and dates ISO strings.
// Anything private (expense history, guest secrets, the host's user id on a bill) is left out here.
import { computeBill } from '../domain/bill';
import type { BillDoc, BillGuestDoc, ExpenseDoc, GroupDoc, SettlementDoc } from '../repositories/documents';

/** A group with its members and pending invites. */
export function groupJson(group: GroupDoc) {
  return {
    id: group._id.toHexString(),
    name: group.name,
    currency: group.currency,
    members: group.members.map((member) => ({ userId: member.userId, email: member.email, name: member.name })),
    invites: (group.invites ?? []).map((invite) => ({
      id: invite.id,
      email: invite.email,
      invitedBy: invite.invitedBy,
      createdAt: invite.createdAt.toISOString(),
    })),
    createdBy: group.createdBy,
    createdAt: group.createdAt.toISOString(),
  };
}

/** An expense. `hasReceipt` says whether a receipt can be fetched; the key itself stays private. */
export function expenseJson(expense: ExpenseDoc) {
  return {
    id: expense._id.toHexString(),
    groupId: expense.groupId.toHexString(),
    description: expense.description,
    amountCents: expense.amountCents,
    paidBy: expense.paidBy,
    splitType: expense.splitType,
    splits: expense.splits,
    hasReceipt: Boolean(expense.receiptKey),
    version: expense.version ?? 1,
    createdBy: expense.createdBy,
    createdAt: expense.createdAt.toISOString(),
    updatedAt: expense.updatedAt?.toISOString() ?? null,
    updatedBy: expense.updatedBy ?? null,
  };
}

/** A recorded payment between two members. */
export function settlementJson(settlement: SettlementDoc) {
  return {
    id: settlement._id.toHexString(),
    groupId: settlement.groupId.toHexString(),
    fromUserId: settlement.fromUserId,
    toUserId: settlement.toUserId,
    amountCents: settlement.amountCents,
    createdBy: settlement.createdBy,
    createdAt: settlement.createdAt.toISOString(),
  };
}

// Older guests may have only `paid: true`, which means they paid whatever their total is now.
function paidCentsOf(guest: BillGuestDoc, totalCents: number): number {
  if (guest.paidCents !== undefined) return guest.paidCents;
  return guest.paid ? totalCents : 0;
}

/**
 * A bill as both the host and the guests see it, with every total worked out from its lines and ticks.
 * `hasPayQr` says whether the host has a bank QR image to show.
 */
export function billJson(bill: BillDoc, hasPayQr: boolean) {
  const breakdown = computeBill(bill.items, bill.guests);
  const lineIds = new Set(bill.items.map((item) => item.id));

  const guests = bill.guests.map((guest) => {
    const totalCents = breakdown.guestTotals.get(guest.id) ?? 0;
    const paidCents = paidCentsOf(guest, totalCents);
    // Negative when the guest paid more than their ticks now add up to.
    const dueCents = totalCents - paidCents;
    return {
      id: guest.id,
      name: guest.name,
      isHost: guest.isHost,
      paid: paidCents > 0 && dueCents <= 0,
      paidCents,
      dueCents,
      itemIds: guest.itemIds.filter((id) => lineIds.has(id)),
      totalCents,
    };
  });
  // The host doesn't owe themselves, so the owed and paid totals count everyone else.
  const others = guests.filter((guest) => !guest.isHost);

  return {
    id: bill._id.toHexString(),
    code: bill.code,
    title: bill.title,
    currency: bill.currency,
    status: bill.status,
    hostName: bill.hostName,
    items: bill.items.map((item) => ({
      id: item.id,
      name: item.name,
      priceCents: item.priceCents,
      claimedBy: breakdown.claimers.get(item.id) ?? [],
      shares: Object.fromEntries(breakdown.shares.get(item.id) ?? []),
    })),
    guests,
    totalCents: breakdown.totalCents,
    claimedCents: breakdown.claimedCents,
    unclaimedCents: breakdown.unclaimedCents,
    owedCents: others.reduce((acc, guest) => acc + guest.totalCents, 0),
    paidCents: others.reduce((acc, guest) => acc + guest.paidCents, 0),
    payment: bill.payment,
    hasPayQr,
    createdAt: bill.createdAt.toISOString(),
    updatedAt: bill.updatedAt.toISOString(),
  };
}

/** One row in the host's list of bills. */
export function billSummaryJson(bill: BillDoc) {
  const full = billJson(bill, false);
  const others = full.guests.filter((guest) => !guest.isHost);
  return {
    id: full.id,
    code: full.code,
    title: full.title,
    currency: full.currency,
    status: full.status,
    totalCents: full.totalCents,
    unclaimedCents: full.unclaimedCents,
    owedCents: full.owedCents,
    paidCents: full.paidCents,
    guestCount: others.length,
    paidCount: others.filter((guest) => guest.paid).length,
    createdAt: full.createdAt,
  };
}
