// Divides an expense into exact shares. The app only says how to split ("evenly between A, B and C");
// the server is the only place this math runs, and the shares always add up to the total.
import { AppError } from './errors';
import { cents, MAX_CENTS, type Cents } from './money';

/** How the app asks for an expense to be split. Percentages are basis points: 33.33% is 3333. */
export type SplitInput =
  | { type: 'EVEN'; userIds: string[] }
  | { type: 'EXACT'; shares: { userId: string; amountCents: number }[] }
  | { type: 'PERCENT'; shares: { userId: string; basisPoints: number }[] };

/** The kind of split, stored on each expense so the app can show how it was entered. */
export type SplitType = SplitInput['type'];

/** One person's part of an expense. */
export interface Share {
  userId: string;
  amountCents: Cents;
}

/** 100% in basis points. */
export const FULL_BASIS_POINTS = 10_000;

/**
 * Orders ids by plain code units. localeCompare would make the result depend on the server's
 * locale, and every tie-break here has to come out the same everywhere.
 */
export function compareIds(a: string, b: string): number {
  if (a < b) return -1;
  if (a > b) return 1;
  return 0;
}

function splitError(code: string, message: string): AppError {
  return new AppError(400, code, message);
}

function assertTotal(total: number): asserts total is Cents {
  if (!Number.isSafeInteger(total) || total < 0 || total > MAX_CENTS) {
    throw splitError('INVALID_AMOUNT', `Amount must be an integer number of cents between 0 and ${MAX_CENTS}`);
  }
}

function assertUniqueUsers(userIds: readonly string[]): void {
  if (userIds.length === 0) {
    throw splitError('SPLIT_EMPTY', 'A split needs at least one person');
  }
  if (new Set(userIds).size !== userIds.length) {
    throw splitError('SPLIT_DUPLICATE_USER', 'Each person can appear in a split only once');
  }
}

/**
 * Splits `total` in proportion to each weight with the largest remainder method. Everyone gets the
 * rounded-down share, then the leftover cents go one each to the biggest remainders, ties to the
 * smaller user id. The result is sorted by user id and always adds up to exactly `total`.
 */
export function largestRemainder(total: Cents, weights: readonly { userId: string; weight: number }[]): Share[] {
  assertTotal(total);
  assertUniqueUsers(weights.map((w) => w.userId));

  let totalWeight = 0;
  for (const { weight } of weights) {
    if (!Number.isSafeInteger(weight) || weight < 0) {
      throw splitError('INVALID_WEIGHT', 'Split weights must be non-negative integers');
    }
    totalWeight += weight;
  }
  if (totalWeight === 0) {
    throw splitError('INVALID_WEIGHT', 'At least one person must have a share');
  }

  const rows = weights.map(({ userId, weight }) => {
    const scaled = total * weight;
    if (!Number.isSafeInteger(scaled)) {
      throw splitError('INVALID_AMOUNT', 'Amount is too large to split');
    }
    // Both operands are safe integers, so the remainder is exact.
    const remainder = scaled % totalWeight;
    return { userId, amount: (scaled - remainder) / totalWeight, remainder };
  });

  let leftover = total - rows.reduce((acc, row) => acc + row.amount, 0);
  const byRemainder = [...rows].sort((a, b) => b.remainder - a.remainder || compareIds(a.userId, b.userId));
  for (const row of byRemainder) {
    if (leftover === 0) break;
    row.amount += 1;
    leftover -= 1;
  }

  return rows
    .map((row) => ({ userId: row.userId, amountCents: cents(row.amount) }))
    .sort((a, b) => compareIds(a.userId, b.userId));
}

/** Splits `total` evenly. Shares differ by at most one cent. */
export function splitEven(total: Cents, userIds: readonly string[]): Share[] {
  const weights = userIds.map((userId) => ({ userId, weight: 1 }));
  return largestRemainder(total, weights);
}

/** Splits `total` by percentages given in basis points, which must add up to exactly 100%. */
export function splitPercent(total: Cents, shares: readonly { userId: string; basisPoints: number }[]): Share[] {
  for (const share of shares) {
    if (!Number.isSafeInteger(share.basisPoints) || share.basisPoints < 0 || share.basisPoints > FULL_BASIS_POINTS) {
      throw splitError('INVALID_PERCENT', 'Each percentage must be between 0.00% and 100.00%');
    }
  }

  const totalBasisPoints = shares.reduce((acc, share) => acc + share.basisPoints, 0);
  if (totalBasisPoints !== FULL_BASIS_POINTS) {
    const percent = (totalBasisPoints / 100).toFixed(2);
    throw splitError('SPLIT_PERCENT_MISMATCH', `Percentages must add up to 100.00% (got ${percent}%)`);
  }

  const weights = shares.map((share) => ({ userId: share.userId, weight: share.basisPoints }));
  return largestRemainder(total, weights);
}

/** Checks amounts the app chose itself. They must be whole cents and add up to exactly `total`. */
export function splitExact(total: Cents, shares: readonly { userId: string; amountCents: number }[]): Share[] {
  assertTotal(total);
  assertUniqueUsers(shares.map((share) => share.userId));

  let sharesTotal = 0;
  for (const share of shares) {
    if (!Number.isSafeInteger(share.amountCents) || share.amountCents < 0) {
      throw splitError('INVALID_AMOUNT', 'Each share must be a non-negative integer number of cents');
    }
    sharesTotal += share.amountCents;
  }
  if (sharesTotal !== total) {
    throw splitError('SPLIT_SUM_MISMATCH', `Shares add up to ${sharesTotal} cents but the expense is ${total} cents`);
  }

  return shares
    .map((share) => ({ userId: share.userId, amountCents: cents(share.amountCents) }))
    .sort((a, b) => compareIds(a.userId, b.userId));
}

/** Turns a split request into exact shares, sorted by user id. Throws a 400 AppError for a bad split. */
export function computeSplit(total: Cents, input: SplitInput): Share[] {
  switch (input.type) {
    case 'EVEN':
      return splitEven(total, input.userIds);
    case 'EXACT':
      return splitExact(total, input.shares);
    case 'PERCENT':
      return splitPercent(total, input.shares);
  }
}

/** Every user id a split request names. */
export function splitUserIds(input: SplitInput): string[] {
  if (input.type === 'EVEN') return input.userIds;
  return input.shares.map((share) => share.userId);
}
