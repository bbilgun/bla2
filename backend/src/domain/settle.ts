// Suggests who should pay whom to bring a group's balances back to zero.
import { AppError } from './errors';
import { cents, type Cents } from './money';
import { compareIds } from './split';

/** One person's net position in a group. */
export interface Balance {
  userId: string;
  /** Positive: the group owes this person. Negative: this person owes the group. */
  netCents: Cents;
}

/** A suggested payment: `fromUserId` pays `toUserId`. */
export interface Transfer {
  fromUserId: string;
  toUserId: string;
  amountCents: Cents;
}

interface Party {
  userId: string;
  remaining: number;
}

function biggestFirst(a: Party, b: Party): number {
  return b.remaining - a.remaining || compareIds(a.userId, b.userId);
}

/**
 * Turns net balances into a short list of payments. The biggest debtor pays the biggest creditor
 * until one of them reaches zero, and so on. That gives at most n - 1 payments, and ties are broken
 * by user id so the answer is always the same. Throws a 500 if the balances don't add up to zero.
 */
export function suggestTransfers(balances: readonly Balance[]): Transfer[] {
  const total = balances.reduce((acc, balance) => acc + balance.netCents, 0);
  if (total !== 0) {
    throw new AppError(500, 'BALANCES_DO_NOT_SUM_TO_ZERO', `Balances sum to ${total}, expected 0`);
  }

  const creditors: Party[] = balances
    .filter((balance) => balance.netCents > 0)
    .map((balance) => ({ userId: balance.userId, remaining: balance.netCents }))
    .sort(biggestFirst);
  const debtors: Party[] = balances
    .filter((balance) => balance.netCents < 0)
    .map((balance) => ({ userId: balance.userId, remaining: -balance.netCents }))
    .sort(biggestFirst);

  const transfers: Transfer[] = [];
  while (debtors.length > 0 && creditors.length > 0) {
    const debtor = debtors[0]!;
    const creditor = creditors[0]!;
    const amount = Math.min(debtor.remaining, creditor.remaining);
    transfers.push({ fromUserId: debtor.userId, toUserId: creditor.userId, amountCents: cents(amount) });

    debtor.remaining -= amount;
    creditor.remaining -= amount;
    if (debtor.remaining === 0) debtors.shift();
    if (creditor.remaining === 0) creditors.shift();
  }
  return transfers;
}
