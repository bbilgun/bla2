// Money as a whole number of minor units ("cents"). Amounts are never floats anywhere in the backend.
// docs/backend.md explains why, and what a minor unit means for MNT, KRW and JPY.

declare const centsBrand: unique symbol;

/** A whole number of minor units. Only `cents()` makes one, so a stray float can't get in. */
export type Cents = number & { readonly [centsBrand]: true };

/** The largest single amount: 1,000,000,000.00. It keeps amount x 10,000 (basis points) below 2^53. */
export const MAX_CENTS = 100_000_000_000;

/** Marks a number as cents. Throws a TypeError unless it's a safe integer. */
export function cents(n: number): Cents {
  if (!Number.isSafeInteger(n)) {
    throw new TypeError(`Expected an integer number of cents, got ${n}`);
  }
  return n as Cents;
}

/** Zero, as cents. */
export const ZERO = cents(0);

const AMOUNT_RE = /^(-)?(\d{1,15})(?:\.(\d{1,2}))?$/;

/** Parses "12.34" as 1234, "12.3" as 1230 and "12" as 1200, using only string and integer operations. */
export function parseCents(input: string): Cents {
  const match = AMOUNT_RE.exec(input.trim());
  if (!match) throw new TypeError(`Not a money amount: "${input}"`);

  const [, sign, whole = '0', fraction = ''] = match;
  const value = Number(whole) * 100 + Number(fraction.padEnd(2, '0'));
  return cents(sign ? -value : value);
}

/** Formats 1234 as "$12.34" and -5 as "-$0.05". */
export function formatCents(amount: Cents, symbol = '$'): string {
  const sign = amount < 0 ? '-' : '';
  const abs = Math.abs(amount);
  const whole = Math.trunc(abs / 100);
  const fraction = String(abs % 100).padStart(2, '0');
  return `${sign}${symbol}${whole.toLocaleString('en-US')}.${fraction}`;
}

/** Adds two amounts. Throws if the result is too big to stay exact. */
export function add(a: Cents, b: Cents): Cents {
  return cents(a + b);
}

/** Adds up a list of amounts. An empty list is zero. */
export function sum(amounts: readonly Cents[]): Cents {
  return amounts.reduce(add, ZERO);
}

/** Orders two amounts for sorting: -1, 0 or 1. */
export function compare(a: Cents, b: Cents): -1 | 0 | 1 {
  if (a < b) return -1;
  if (a > b) return 1;
  return 0;
}
