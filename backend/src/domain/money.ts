/**
 * Money is always an integer number of cents.
 *
 * 0.1 + 0.2 === 0.30000000000000004 because binary floats cannot represent 0.1 exactly.
 * Integers are exact in a JS number up to 2^53 (Number.MAX_SAFE_INTEGER), so as long as
 * every amount is a whole number of cents and stays below that, all math here is exact.
 *
 * `Cents` is a branded type: a plain `number` cannot be passed where `Cents` is expected
 * without going through `cents()`, which rejects floats.
 */
declare const centsBrand: unique symbol;
export type Cents = number & { readonly [centsBrand]: true };

/** Upper bound for a single amount: $1,000,000,000.00. Keeps amount * 10_000 (basis points) < 2^53. */
export const MAX_CENTS = 100_000_000_000;

export function cents(n: number): Cents {
  if (!Number.isSafeInteger(n)) {
    throw new TypeError(`Expected an integer number of cents, got ${n}`);
  }
  return n as Cents;
}

export const ZERO = cents(0);

const AMOUNT_RE = /^(-)?(\d{1,15})(?:\.(\d{1,2}))?$/;

/** "12.34" -> 1234, "12.3" -> 1230, "12" -> 1200. Uses only string and integer ops. */
export function parseCents(input: string): Cents {
  const match = AMOUNT_RE.exec(input.trim());
  if (!match) throw new TypeError(`Not a money amount: "${input}"`);
  const [, sign, whole = '0', frac = ''] = match;
  const value = Number(whole) * 100 + Number(frac.padEnd(2, '0'));
  return cents(sign ? -value : value);
}

/** 1234 -> "$12.34", -5 -> "-$0.05". */
export function formatCents(amount: Cents, symbol = '$'): string {
  const sign = amount < 0 ? '-' : '';
  const abs = Math.abs(amount);
  const whole = Math.trunc(abs / 100);
  const frac = String(abs % 100).padStart(2, '0');
  return `${sign}${symbol}${whole.toLocaleString('en-US')}.${frac}`;
}

export function add(a: Cents, b: Cents): Cents {
  return cents(a + b);
}

export function subtract(a: Cents, b: Cents): Cents {
  return cents(a - b);
}

export function negate(a: Cents): Cents {
  return cents(-a);
}

export function sum(amounts: readonly Cents[]): Cents {
  return amounts.reduce(add, ZERO);
}

export function compare(a: Cents, b: Cents): -1 | 0 | 1 {
  return a < b ? -1 : a > b ? 1 : 0;
}
