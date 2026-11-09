import { describe, expect, it } from 'vitest';
import { add, cents, compare, formatCents, parseCents, sum } from '../../src/domain/money';

describe('why cents', () => {
  it('floats drift, integers do not', () => {
    expect(0.1 + 0.2).not.toBe(0.3);
    expect(cents(10) + cents(20)).toBe(30);
  });
});

describe('parseCents', () => {
  it.each([
    ['12.34', 1234],
    ['12.3', 1230],
    ['12', 1200],
    ['0.05', 5],
    ['0', 0],
    ['  7.10 ', 710],
    ['-3.50', -350],
    ['1000000000.00', 100_000_000_000],
  ])('%s -> %i', (input, expected) => {
    expect(parseCents(input)).toBe(expected);
  });

  it.each(['', '.', '1.234', '1,00', 'abc', '1e3', '12.', '$5', '--1'])('rejects %j', (input) => {
    expect(() => parseCents(input)).toThrow(TypeError);
  });
});

describe('formatCents', () => {
  it.each([
    [1234, '$12.34'],
    [5, '$0.05'],
    [0, '$0.00'],
    [-350, '-$3.50'],
    [123456789, '$1,234,567.89'],
  ])('%i -> %s', (input, expected) => {
    expect(formatCents(cents(input))).toBe(expected);
  });

  it('round-trips with parseCents', () => {
    for (const n of [0, 1, 99, 100, 101, 999_999]) {
      expect(parseCents(formatCents(cents(n)).replace(/[$,]/g, ''))).toBe(n);
    }
  });
});

describe('cents()', () => {
  it('refuses floats and unsafe integers', () => {
    expect(() => cents(1.5)).toThrow(TypeError);
    expect(() => cents(Number.NaN)).toThrow(TypeError);
    expect(() => cents(2 ** 53)).toThrow(TypeError);
  });
});

describe('arithmetic', () => {
  it('adds, sums, compares', () => {
    expect(add(cents(1), cents(2))).toBe(3);
    expect(sum([cents(10), cents(20), cents(-5)])).toBe(25);
    expect(compare(cents(1), cents(2))).toBe(-1);
    expect(compare(cents(2), cents(2))).toBe(0);
    expect(compare(cents(3), cents(2))).toBe(1);
  });
});
