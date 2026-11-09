import { describe, expect, it } from 'vitest';
import { AppError } from '../../src/domain/errors';
import { cents, MAX_CENTS } from '../../src/domain/money';
import { computeSplit, splitEven, splitExact, splitPercent } from '../../src/domain/split';

const total = (shares: { amountCents: number }[]) => shares.reduce((a, s) => a + s.amountCents, 0);
const codeOf = (fn: () => unknown) => {
  try {
    fn();
  } catch (e) {
    return e instanceof AppError ? e.code : String(e);
  }
  return 'no error';
};

describe('exit check: $100.00', () => {
  it('Even across 3: the spare cent goes to the smallest user id', () => {
    // 10000 / 3 = 3333 r 1. All three remainders tie, so the tie-break (user id) decides.
    expect(splitEven(cents(10_000), ['carol', 'alice', 'bob'])).toEqual([
      { userId: 'alice', amountCents: 3334 },
      { userId: 'bob', amountCents: 3333 },
      { userId: 'carol', amountCents: 3333 },
    ]);
  });

  it('33.33% / 33.33% / 33.34%: no spare cent at all', () => {
    // 10000 * 3333 / 10000 = 3333 exactly, 10000 * 3334 / 10000 = 3334 exactly.
    expect(
      splitPercent(cents(10_000), [
        { userId: 'alice', basisPoints: 3333 },
        { userId: 'bob', basisPoints: 3333 },
        { userId: 'carol', basisPoints: 3334 },
      ]),
    ).toEqual([
      { userId: 'alice', amountCents: 3333 },
      { userId: 'bob', amountCents: 3333 },
      { userId: 'carol', amountCents: 3334 },
    ]);
  });

  it('input order never changes the result', () => {
    const a = splitEven(cents(10_000), ['carol', 'alice', 'bob']);
    const b = splitEven(cents(10_000), ['bob', 'carol', 'alice']);
    expect(a).toEqual(b);
  });
});

describe('largest remainder', () => {
  it('gives leftover cents to the largest fractional remainders first', () => {
    // $10.00 at 33.33 / 33.33 / 33.34%: exact shares 333.3, 333.3, 333.4 -> floors 333, 333, 333, one cent left.
    // carol has the biggest remainder (.4), so carol gets it even though her id sorts last.
    expect(
      splitPercent(cents(1000), [
        { userId: 'alice', basisPoints: 3333 },
        { userId: 'bob', basisPoints: 3333 },
        { userId: 'carol', basisPoints: 3334 },
      ]),
    ).toEqual([
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
    expect(
      splitExact(cents(1000), [
        { userId: 'b', amountCents: 250 },
        { userId: 'a', amountCents: 750 },
      ]),
    ).toEqual([
      { userId: 'a', amountCents: 750 },
      { userId: 'b', amountCents: 250 },
    ]);
  });
});

/**
 * Property-style tests: throw thousands of random totals and member counts at the splitter.
 * A tiny seeded PRNG keeps failures reproducible.
 */
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

  it('EVEN: shares always sum to the total, differ by at most 1 cent, and are deterministic', () => {
    for (let run = 0; run < 2000; run++) {
      const amount = cents(int(run % 10 === 0 ? MAX_CENTS : 1_000_000));
      const users = [...new Set(ids(1 + int(25)))];
      const shares = splitEven(amount, users);
      expect(total(shares)).toBe(amount);
      const values = shares.map((s) => s.amountCents);
      expect(Math.max(...values) - Math.min(...values)).toBeLessThanOrEqual(1);
      expect(splitEven(amount, [...users].reverse())).toEqual(shares);
    }
  });

  it('PERCENT: shares sum to the total and each is within 1 cent of its exact value', () => {
    for (let run = 0; run < 2000; run++) {
      const amount = cents(int(1_000_000));
      const users = [...new Set(ids(1 + int(10)))];
      // random basis points that add up to exactly 10000
      const cuts = Array.from({ length: users.length - 1 }, () => int(10_000)).sort((a, b) => a - b);
      const bps = [...cuts, 10_000].map((c, i) => c - (i === 0 ? 0 : cuts[i - 1]!));
      const input = users.map((userId, i) => ({ userId, basisPoints: bps[i]! }));
      const shares = computeSplit(amount, { type: 'PERCENT', shares: input });
      expect(total(shares)).toBe(amount);
      for (const s of shares) {
        const exact = (amount * input.find((x) => x.userId === s.userId)!.basisPoints) / 10_000;
        expect(Math.abs(s.amountCents - exact)).toBeLessThan(1);
      }
    }
  });
});
