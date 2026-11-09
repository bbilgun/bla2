import { describe, expect, it } from 'vitest';
import { computeBill } from '../../src/domain/bill';

describe('computeBill', () => {
  it('a line ticked by several people is split between them to the cent', () => {
    // 30,000.00₮ of khuushuur shared by 3, plus a 4,500.00₮ drink only Bat had.
    const b = computeBill(
      [
        { id: 'khuushuur', priceCents: 3_000_000 },
        { id: 'cola', priceCents: 450_000 },
      ],
      [
        { id: 'bat', itemIds: ['khuushuur', 'cola'] },
        { id: 'saraa', itemIds: ['khuushuur'] },
        { id: 'host', itemIds: ['khuushuur'] },
      ],
    );
    expect(b.guestTotals.get('bat')).toBe(1_000_000 + 450_000);
    expect(b.guestTotals.get('saraa')).toBe(1_000_000);
    expect(b.guestTotals.get('host')).toBe(1_000_000);
    expect(b.claimers.get('khuushuur')).toEqual(['bat', 'host', 'saraa']);
    expect(b.unclaimedCents).toBe(0);
  });

  it('a spare cent goes to the smallest guest id, every time', () => {
    const b = computeBill([{ id: 'x', priceCents: 1000 }], [
      { id: 'c', itemIds: ['x'] },
      { id: 'a', itemIds: ['x'] },
      { id: 'b', itemIds: ['x'] },
    ]);
    expect(Object.fromEntries(b.shares.get('x')!)).toEqual({ a: 334, b: 333, c: 333 });
  });

  it('lines nobody ticked are unclaimed; guests with no ticks owe 0', () => {
    const b = computeBill(
      [
        { id: 'a', priceCents: 500 },
        { id: 'b', priceCents: 700 },
      ],
      [
        { id: 'g1', itemIds: ['a'] },
        { id: 'g2', itemIds: [] },
      ],
    );
    expect(b.totalCents).toBe(1200);
    expect(b.claimedCents).toBe(500);
    expect(b.unclaimedCents).toBe(700);
    expect(b.guestTotals.get('g2')).toBe(0);
    expect(b.claimers.get('b')).toEqual([]);
  });

  it('ticks on lines that no longer exist are ignored', () => {
    const b = computeBill([{ id: 'a', priceCents: 500 }], [{ id: 'g', itemIds: ['a', 'deleted'] }]);
    expect(b.guestTotals.get('g')).toBe(500);
  });

  it('property: guest totals + unclaimed always equal the bill total, over 2,000 random bills', () => {
    let seed = 42;
    const rand = (n: number) => {
      seed = (seed * 1_103_515_245 + 12_345) % 2_147_483_648;
      return seed % n;
    };
    for (let run = 0; run < 2000; run++) {
      const items = Array.from({ length: 1 + rand(12) }, (_, i) => ({ id: `i${i}`, priceCents: 1 + rand(5_000_000) }));
      const guests = Array.from({ length: 1 + rand(9) }, (_, g) => ({
        id: `g${g}`,
        itemIds: items.filter(() => rand(3) === 0).map((i) => i.id),
      }));
      const b = computeBill(items, guests);
      const guestSum = [...b.guestTotals.values()].reduce((a, c) => a + c, 0);
      expect(guestSum + b.unclaimedCents).toBe(items.reduce((a, i) => a + i.priceCents, 0));
      for (const item of items) {
        const shares = [...b.shares.get(item.id)!.values()];
        if (shares.length > 0) {
          expect(shares.reduce((a, c) => a + c, 0)).toBe(item.priceCents);
          expect(Math.max(...shares) - Math.min(...shares)).toBeLessThanOrEqual(1);
        }
      }
    }
  });
});
