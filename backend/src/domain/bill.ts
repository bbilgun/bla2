// The math behind a one-off QR bill: each line is shared evenly, to the cent, by everyone who ticked it.
// For every bill, the guests' totals plus the unclaimed amount equal the sum of the line prices.
import { cents } from './money';
import { compareIds, splitEven } from './split';

/** A line on the receipt. */
export interface BillLine {
  id: string;
  priceCents: number;
}

/** Someone on the bill and the lines they ticked. Ticks on lines that aren't on the bill are ignored. */
export interface BillGuest {
  id: string;
  itemIds: readonly string[];
}

/** Every total on a bill, derived from its lines and ticks. */
export interface BillBreakdown {
  totalCents: number;
  claimedCents: number;
  /** Lines nobody has ticked yet. The host is out of pocket for these until someone does. */
  unclaimedCents: number;
  /** Guest id to what their ticked lines add up to. Every guest is present, at 0 when nothing is ticked. */
  guestTotals: Map<string, number>;
  /** Line id to the sorted ids of the guests sharing it. */
  claimers: Map<string, string[]>;
  /** Line id to each sharing guest's part of that line. */
  shares: Map<string, Map<string, number>>;
}

/**
 * Works out every total on a bill. Each line is split with the same largest-remainder rule as group
 * expenses, so a spare cent goes to the smallest guest id.
 */
export function computeBill(items: readonly BillLine[], guests: readonly BillGuest[]): BillBreakdown {
  const guestTotals = new Map(guests.map((guest) => [guest.id, 0]));
  const claimers = new Map<string, string[]>();
  const shares = new Map<string, Map<string, number>>();
  let totalCents = 0;
  let claimedCents = 0;

  for (const item of items) {
    totalCents += item.priceCents;
    const sharedBy = guests
      .filter((guest) => guest.itemIds.includes(item.id))
      .map((guest) => guest.id)
      .sort(compareIds);
    claimers.set(item.id, sharedBy);

    const lineShares = new Map<string, number>();
    if (sharedBy.length > 0) {
      claimedCents += item.priceCents;
      for (const share of splitEven(cents(item.priceCents), sharedBy)) {
        lineShares.set(share.userId, share.amountCents);
        guestTotals.set(share.userId, (guestTotals.get(share.userId) ?? 0) + share.amountCents);
      }
    }
    shares.set(item.id, lineShares);
  }

  return { totalCents, claimedCents, unclaimedCents: totalCents - claimedCents, guestTotals, claimers, shares };
}
