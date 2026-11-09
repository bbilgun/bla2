import { describe, expect, it } from 'vitest';
import { AppError } from '../../src/domain/errors';
import { cents, MAX_CENTS } from '../../src/domain/money';
import { computeSplit, splitEven, splitExact, splitPercent } from '../../src/domain/split';

const total = (shares: { amountCents: number }[]) => shares.reduce((acc, share) => acc + share.amountCents, 0);

function codeOf(fn: () => unknown): string {
  try {
    fn();
  } catch (err) {
    return err instanceof AppError ? err.code : String(err);
  }
  return 'no error';
}

describe('splitting $100.00', () => {
  it('gives the spare cent of an even three-way split to the smallest user id', () => {
    // 10000 / 3 = 3333 remainder 1. All three remainders tie, so the user id decides.
    expect(splitEven(cents(10_000), ['carol', 'alice', 'bob'])).toEqual([
      { userId: 'alice', amountCents: 3334 },
      { userId: 'bob', amountCents: 3333 },
      { userId: 'carol', amountCents: 3333 },
    ]);
  });

  it('has no spare cent at 33.33, 33.33 and 33.34 percent', () => {
    // 10000 * 3333 / 10000 = 3333 exactly, and 10000 * 3334 / 10000 = 3334 exactly.
    const shares = splitPercent(cents(10_000), [
      { userId: 'alice', basisPoints: 3333 },
      { userId: 'bob', basisPoints: 3333 },
      { userId: 'carol', basisPoints: 3334 },
    ]);

    expect(shares).toEqual([
      { userId: 'alice', amountCents: 3333 },
      { userId: 'bob', amountCents: 3333 },
      { userId: 'carol', amountCents: 3334 },
    ]);
  });

  it('gives the same result whatever the input order', () => {
    const first = splitEven(cents(10_000), ['carol', 'alice', 'bob']);
    const second = splitEven(cents(10_000), ['bob', 'carol', 'alice']);

    expect(first).toEqual(second);
  });
});

describe('largest remainder', () => {
  it('gives leftover cents to the largest fractional remainders first', () => {
    // $10.00 at 33.33, 33.33 and 33.34 percent: exact shares 333.3, 333.3 and 333.4, floors 333 each,
    // one cent left. Carol has the biggest remainder, so she gets it even though her id sorts last.
    const shares = splitPercent(cents(1000), [
      { userId: 'alice', basisPoints: 3333 },
      { userId: 'bob', basisPoints: 3333 },
      { userId: 'carol', basisPoints: 3334 },
    ]);

    expect(shares).toEqual([
      { userId: 'alice', amountCents: 333 },
      { userId: 'bob', amountCents: 333 },
      { userId: 'carol', amountCents: 334 },
    ]);
  });

  it('splits 1 cent', () => {
    expect(splitEven(cents(1), ['b', 'a'])).toEqual([
      { userId: 'a', amountCents: 1 },
      { userId: 'b', amountCents: 0 },
    ]);
  });

  it('splits zero', () => {
    expect(total(splitEven(cents(0), ['a', 'b', 'c']))).toBe(0);
  });

  it('handles the maximum amount without losing precision', () => {
    const shares = splitPercent(cents(MAX_CENTS), [
      { userId: 'a', basisPoints: 1 },
      { userId: 'b', basisPoints: 9999 },
    ]);

    expect(total(shares)).toBe(MAX_CENTS);
    expect(shares[0]!.amountCents).toBe(10_000_000);
  });
});

describe('validation', () => {
  it('rejects bad input with stable codes', () => {
    expect(codeOf(() => splitEven(cents(100), []))).toBe('SPLIT_EMPTY');
    expect(codeOf(() => splitEven(cents(100), ['a', 'a']))).toBe('SPLIT_DUPLICATE_USER');
    expect(codeOf(() => splitExact(cents(100), [{ userId: 'a', amountCents: 99 }]))).toBe('SPLIT_SUM_MISMATCH');
    expect(codeOf(() => splitExact(cents(100), [{ userId: 'a', amountCents: 100.5 }]))).toBe('INVALID_AMOUNT');
    expect(codeOf(() => splitPercent(cents(100), [{ userId: 'a', basisPoints: 9999 }]))).toBe('SPLIT_PERCENT_MISMATCH');
    expect(codeOf(() => splitPercent(cents(100), [{ userId: 'a', basisPoints: 10_001 }]))).toBe('INVALID_PERCENT');
    expect(codeOf(() => splitEven(-1 as never, ['a']))).toBe('INVALID_AMOUNT');
    expect(codeOf(() => splitEven(1.5 as never, ['a']))).toBe('INVALID_AMOUNT');
  });

  it('accepts an exact split that adds up', () => {
    const shares = splitExact(cents(1000), [
      { userId: 'b', amountCents: 250 },
      { userId: 'a', amountCents: 750 },
    ]);

    expect(shares).toEqual([
      { userId: 'a', amountCents: 750 },
      { userId: 'b', amountCents: 250 },
    ]);
  });
});

// Property-style tests: thousands of random totals and member counts. A small seeded generator keeps
// any failure reproducible.
function prng(seed: number) {
  return () => {
    seed = (seed * 1_103_515_245 + 12_345) % 2_147_483_648;
    return seed / 2_147_483_648;
  };
}

describe('properties', () => {
  const rand = prng(42);
  const int = (max: number) => Math.floor(rand() * (max + 1));
  const ids = (n: number) => Array.from({ length: n }, (_, i) => `user-${String(i).padStart(3, '0')}-${int(9)}`);

  it('even shares add up, differ by at most a cent and ignore input order', () => {
    for (let run = 0; run < 2000; run++) {
      const amount = cents(int(run % 10 === 0 ? MAX_CENTS : 1_000_000));
      const users = [...new Set(ids(1 + int(25)))];

      const shares = splitEven(amount, users);

      expect(total(shares)).toBe(amount);
      const values = shares.map((share) => share.amountCents);
      expect(Math.max(...values) - Math.min(...values)).toBeLessThanOrEqual(1);
      expect(splitEven(amount, [...users].reverse())).toEqual(shares);
    }
  });

  it('percent shares add up and stay within a cent of exact', () => {
    for (let run = 0; run < 2000; run++) {
      const amount = cents(int(1_000_000));
      const users = [...new Set(ids(1 + int(10)))];
      // Random basis points that add up to exactly 10000.
      const cuts = Array.from({ length: users.length - 1 }, () => int(10_000)).sort((a, b) => a - b);
      const basisPoints = [...cuts, 10_000].map((cut, i) => cut - (i === 0 ? 0 : cuts[i - 1]!));
      const input = users.map((userId, i) => ({ userId, basisPoints: basisPoints[i]! }));

      const shares = computeSplit(amount, { type: 'PERCENT', shares: input });

      expect(total(shares)).toBe(amount);
      for (const share of shares) {
        const exact = (amount * input.find((x) => x.userId === share.userId)!.basisPoints) / 10_000;
        expect(Math.abs(share.amountCents - exact)).toBeLessThan(1);
      }
    }
  });
});
