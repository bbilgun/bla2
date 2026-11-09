import { AppError } from './errors';
import { cents, MAX_CENTS, type Cents } from './money';

/**
 * How an expense is divided. The server is the only place this math runs;
 * the app sends intent ("split evenly between A, B, C") and gets back exact cents.
 */
export type SplitInput =
  | { type: 'EVEN'; userIds: string[] }
  | { type: 'EXACT'; shares: { userId: string; amountCents: number }[] }
  | { type: 'PERCENT'; shares: { userId: string; basisPoints: number }[] };

export type SplitType = SplitInput['type'];

export interface Share {
  userId: string;
  amountCents: Cents;
}

/** 100% expressed in basis points. 33.33% is 3333. */
export const FULL_BASIS_POINTS = 10_000;

/** Plain code-unit ordering. Never localeCompare: the result must not depend on the server's locale. */
export function compareIds(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

const splitError = (code: string, message: string) => new AppError(400, code, message);

function assertTotal(total: number): asserts total is Cents {
  if (!Number.isSafeInteger(total) || total < 0 || total > MAX_CENTS) {
    throw splitError('INVALID_AMOUNT', `Amount must be an integer number of cents between 0 and ${MAX_CENTS}`);
  }
}

function assertUniqueUsers(userIds: readonly string[]): void {
  if (userIds.length === 0) throw splitError('SPLIT_EMPTY', 'A split needs at least one person');
  if (new Set(userIds).size !== userIds.length) {
    throw splitError('SPLIT_DUPLICATE_USER', 'Each person can appear in a split only once');
  }
}

/**
 * Largest remainder (Hamilton) allocation.
 *
 * Each person's exact share is total * weight / totalWeight. We give everyone the floor of that,
 * then hand the leftover cents, one each, to the people with the biggest fractional remainder.
 * Ties go to the smaller user id. Same input, same output, every time, and the shares always
 * add up to exactly `total`.
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
  if (totalWeight === 0) throw splitError('INVALID_WEIGHT', 'At least one person must have a share');

  const rows = weights.map(({ userId, weight }) => {
    const scaled = total * weight;
    if (!Number.isSafeInteger(scaled)) throw splitError('INVALID_AMOUNT', 'Amount is too large to split');
    const remainder = scaled % totalWeight; // exact: both operands are safe integers
    return { userId, floor: (scaled - remainder) / totalWeight, remainder };
  });

  let leftover = total - rows.reduce((acc, r) => acc + r.floor, 0);
  const byRemainder = [...rows].sort((a, b) => b.remainder - a.remainder || compareIds(a.userId, b.userId));
  for (const row of byRemainder) {
    if (leftover === 0) break;
    row.floor += 1;
    leftover -= 1;
  }

  return rows
    .map((r) => ({ userId: r.userId, amountCents: cents(r.floor) }))
    .sort((a, b) => compareIds(a.userId, b.userId));
}

export function splitEven(total: Cents, userIds: readonly string[]): Share[] {
  return largestRemainder(
    total,
    userIds.map((userId) => ({ userId, weight: 1 })),
  );
}

export function splitPercent(total: Cents, shares: readonly { userId: string; basisPoints: number }[]): Share[] {
  for (const s of shares) {
    if (!Number.isSafeInteger(s.basisPoints) || s.basisPoints < 0 || s.basisPoints > FULL_BASIS_POINTS) {
      throw splitError('INVALID_PERCENT', 'Each percentage must be between 0.00% and 100.00%');
    }
  }
  const totalBp = shares.reduce((acc, s) => acc + s.basisPoints, 0);
  if (totalBp !== FULL_BASIS_POINTS) {
    throw splitError('SPLIT_PERCENT_MISMATCH', `Percentages must add up to 100.00% (got ${(totalBp / 100).toFixed(2)}%)`);
  }
  return largestRemainder(
    total,
    shares.map((s) => ({ userId: s.userId, weight: s.basisPoints })),
  );
}

export function splitExact(total: Cents, shares: readonly { userId: string; amountCents: number }[]): Share[] {
  assertTotal(total);
  assertUniqueUsers(shares.map((s) => s.userId));
  let sum = 0;
  for (const s of shares) {
    if (!Number.isSafeInteger(s.amountCents) || s.amountCents < 0) {
      throw splitError('INVALID_AMOUNT', 'Each share must be a non-negative integer number of cents');
    }
    sum += s.amountCents;
  }
  if (sum !== total) {
    throw splitError('SPLIT_SUM_MISMATCH', `Shares add up to ${sum} cents but the expense is ${total} cents`);
  }
  return shares
    .map((s) => ({ userId: s.userId, amountCents: cents(s.amountCents) }))
    .sort((a, b) => compareIds(a.userId, b.userId));
}

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

/** Every user id referenced by a split request. */
export function splitUserIds(input: SplitInput): string[] {
  return input.type === 'EVEN' ? input.userIds : input.shares.map((s) => s.userId);
}
