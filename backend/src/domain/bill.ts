import { cents } from './money';
import { compareIds, splitEven } from './split';

/**
 * A one-off bill (restaurant, party): the host types the receipt's lines, guests tick what they had.
 *
 * Each line is shared evenly by everyone who ticked it, to the cent, with the same largest-remainder
 * rule as group expenses. So for every bill, always:
 *
 *   sum(each guest's total) + unclaimed === sum(line prices)
 *
 * Nothing here touches the database; the service stores lines and ticks, and derives totals on every read,
 * the same way group balances are derived from expenses.
 */
export interface BillLine {
  id: string;
  priceCents: number;
}

export interface BillEater {
  id: string;
  itemIds: readonly string[];
}

export interface BillBreakdown {
  totalCents: number;
  claimedCents: number;
  /** Lines nobody has ticked yet. The host is out of pocket for these until someone does. */
  unclaimedCents: number;
  /** Guest id -> what their ticked lines add up to. Every guest is present, 0 when nothing is ticked. */
  guestTotals: Map<string, number>;
  /** Line id -> ids of the guests sharing it, sorted. */
  claimers: Map<string, string[]>;
  /** Line id -> guest id -> that guest's share of the line. */
  shares: Map<string, Map<string, number>>;
}

export function computeBill(items: readonly BillLine[], guests: readonly BillEater[]): BillBreakdown {
  const guestTotals = new Map(guests.map((g) => [g.id, 0]));
  const claimers = new Map<string, string[]>();
  const shares = new Map<string, Map<string, number>>();
  let totalCents = 0;
  let claimedCents = 0;

  for (const item of items) {
    totalCents += item.priceCents;
    const ids = guests
      .filter((g) => g.itemIds.includes(item.id))
      .map((g) => g.id)
      .sort(compareIds);
    claimers.set(item.id, ids);

    const lineShares = new Map<string, number>();
    if (ids.length > 0) {
      claimedCents += item.priceCents;
      for (const share of splitEven(cents(item.priceCents), ids)) {
        lineShares.set(share.userId, share.amountCents);
        guestTotals.set(share.userId, (guestTotals.get(share.userId) ?? 0) + share.amountCents);
      }
    }
    shares.set(item.id, lineShares);
  }

  return { totalCents, claimedCents, unclaimedCents: totalCents - claimedCents, guestTotals, claimers, shares };
}
