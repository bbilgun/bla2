import { describe, expect, it } from 'vitest';
import { cents } from '../../src/domain/money';
import { suggestTransfers } from '../../src/domain/settle';

const b = (userId: string, net: number) => ({ userId, netCents: cents(net) });

describe('suggestTransfers', () => {
  it('pays creditors from debtors, biggest first', () => {
    expect(suggestTransfers([b('alice', 6000), b('bob', -3000), b('carol', -3000)])).toEqual([
      { fromUserId: 'bob', toUserId: 'alice', amountCents: 3000 },
      { fromUserId: 'carol', toUserId: 'alice', amountCents: 3000 },
    ]);
  });

  it('needs no transfers when everyone is even', () => {
    expect(suggestTransfers([b('a', 0), b('b', 0)])).toEqual([]);
  });

  it('settles everyone to exactly zero with at most n - 1 transfers', () => {
    const balances = [b('a', 1234), b('b', -999), b('c', 500), b('d', -735), b('e', 0)];
    const transfers = suggestTransfers(balances);
    expect(transfers.length).toBeLessThanOrEqual(balances.length - 1);
    const after = new Map(balances.map((x) => [x.userId, x.netCents as number]));
    for (const t of transfers) {
      after.set(t.fromUserId, after.get(t.fromUserId)! + t.amountCents);
      after.set(t.toUserId, after.get(t.toUserId)! - t.amountCents);
    }
    expect([...after.values()].every((v) => v === 0)).toBe(true);
  });

  it('refuses balances that do not sum to zero', () => {
    expect(() => suggestTransfers([b('a', 1)])).toThrow(/sum to 1/);
  });
});
