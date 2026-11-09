import { describe, expect, it } from 'vitest';
import { computeBill } from '../../src/domain/bill';

describe('computeBill', () => {
  it('splits a shared line evenly to the cent', () => {
    // 30,000.00₮ of khuushuur shared by three, plus a 4,500.00₮ drink only Bat had.
    const items = [
      { id: 'khuushuur', priceCents: 3_000_000 },
      { id: 'cola', priceCents: 450_000 },
    ];
    const guests = [
      { id: 'bat', itemIds: ['khuushuur', 'cola'] },
      { id: 'saraa', itemIds: ['khuushuur'] },
      { id: 'host', itemIds: ['khuushuur'] },
    ];

    const bill = computeBill(items, guests);

    expect(bill.guestTotals.get('bat')).toBe(1_000_000 + 450_000);
    expect(bill.guestTotals.get('saraa')).toBe(1_000_000);
    expect(bill.guestTotals.get('host')).toBe(1_000_000);
    expect(bill.claimers.get('khuushuur')).toEqual(['bat', 'host', 'saraa']);
    expect(bill.unclaimedCents).toBe(0);
  });

  it('gives a spare cent to the smallest guest id', () => {
    const guests = [
      { id: 'c', itemIds: ['x'] },
      { id: 'a', itemIds: ['x'] },
      { id: 'b', itemIds: ['x'] },
    ];

    const bill = computeBill([{ id: 'x', priceCents: 1000 }], guests);

    expect(Object.fromEntries(bill.shares.get('x')!)).toEqual({ a: 334, b: 333, c: 333 });
  });

  it('leaves unticked lines unclaimed and guests without ticks at zero', () => {
    const items = [
      { id: 'a', priceCents: 500 },
      { id: 'b', priceCents: 700 },
    ];
    const guests = [
      { id: 'g1', itemIds: ['a'] },
      { id: 'g2', itemIds: [] },
    ];

    const bill = computeBill(items, guests);

    expect(bill.totalCents).toBe(1200);
    expect(bill.claimedCents).toBe(500);
    expect(bill.unclaimedCents).toBe(700);
    expect(bill.guestTotals.get('g2')).toBe(0);
    expect(bill.claimers.get('b')).toEqual([]);
  });

  it('ignores ticks on lines that are not on the bill', () => {
    const bill = computeBill([{ id: 'a', priceCents: 500 }], [{ id: 'g', itemIds: ['a', 'deleted'] }]);

    expect(bill.guestTotals.get('g')).toBe(500);
  });

  it('always adds up to the bill total over 2,000 random bills', () => {
    let seed = 42;
    const rand = (n: number) => {
      seed = (seed * 1_103_515_245 + 12_345) % 2_147_483_648;
      return seed % n;
    };

    for (let run = 0; run < 2000; run++) {
      const items = Array.from({ length: 1 + rand(12) }, (_, i) => ({ id: `i${i}`, priceCents: 1 + rand(5_000_000) }));
      const guests = Array.from({ length: 1 + rand(9) }, (_, g) => ({
        id: `g${g}`,
        itemIds: items.filter(() => rand(3) === 0).map((item) => item.id),
      }));

      const bill = computeBill(items, guests);

      const guestSum = [...bill.guestTotals.values()].reduce((acc, total) => acc + total, 0);
      expect(guestSum + bill.unclaimedCents).toBe(items.reduce((acc, item) => acc + item.priceCents, 0));
      for (const item of items) {
        const shares = [...bill.shares.get(item.id)!.values()];
        if (shares.length > 0) {
          expect(shares.reduce((acc, share) => acc + share, 0)).toBe(item.priceCents);
          expect(Math.max(...shares) - Math.min(...shares)).toBeLessThanOrEqual(1);
        }
      }
    }
  });
});
