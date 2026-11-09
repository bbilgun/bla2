import { AppError } from './errors';
import { cents, type Cents } from './money';
import { compareIds } from './split';

export interface Balance {
  userId: string;
  /** Positive: the group owes this person. Negative: this person owes the group. */
  netCents: Cents;
}

export interface Transfer {
  fromUserId: string;
  toUserId: string;
  amountCents: Cents;
}

/**
 * Turns net balances into a short list of "A pays B" transfers.
 * Greedy: the biggest debtor pays the biggest creditor until one of them is at zero.
 * Produces at most n - 1 transfers and is deterministic (ties broken by user id).
 */
export function suggestTransfers(balances: readonly Balance[]): Transfer[] {
  const total = balances.reduce((acc, b) => acc + b.netCents, 0);
  if (total !== 0) {
    throw new AppError(500, 'BALANCES_DO_NOT_SUM_TO_ZERO', `Balances sum to ${total}, expected 0`);
  }

  const byMagnitude = (a: { userId: string; left: number }, b: { userId: string; left: number }) =>
    b.left - a.left || compareIds(a.userId, b.userId);

  const creditors = balances
    .filter((b) => b.netCents > 0)
    .map((b) => ({ userId: b.userId, left: b.netCents as number }))
    .sort(byMagnitude);
  const debtors = balances
    .filter((b) => b.netCents < 0)
    .map((b) => ({ userId: b.userId, left: -b.netCents }))
    .sort(byMagnitude);

  const transfers: Transfer[] = [];
  let i = 0;
  let j = 0;
  while (i < debtors.length && j < creditors.length) {
    const debtor = debtors[i]!;
    const creditor = creditors[j]!;
    const amount = Math.min(debtor.left, creditor.left);
    transfers.push({ fromUserId: debtor.userId, toUserId: creditor.userId, amountCents: cents(amount) });
    debtor.left -= amount;
    creditor.left -= amount;
    if (debtor.left === 0) i++;
    if (creditor.left === 0) j++;
  }
  return transfers;
}
