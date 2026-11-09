import { describe, expect, it } from 'vitest';
import { cents } from '../../src/domain/money';
import { suggestTransfers } from '../../src/domain/settle';

const balance = (userId: string, net: number) => ({ userId, netCents: cents(net) });

describe('suggestTransfers', () => {
  it('pays creditors from debtors, biggest first', () => {
    const transfers = suggestTransfers([balance('alice', 6000), balance('bob', -3000), balance('carol', -3000)]);

    expect(transfers).toEqual([
      { fromUserId: 'bob', toUserId: 'alice', amountCents: 3000 },
      { fromUserId: 'carol', toUserId: 'alice', amountCents: 3000 },
    ]);
  });

  it('needs no transfers when everyone is even', () => {
    expect(suggestTransfers([balance('a', 0), balance('b', 0)])).toEqual([]);
  });

  it('settles everyone to exactly zero with at most n - 1 transfers', () => {
    const balances = [balance('a', 1234), balance('b', -999), balance('c', 500), balance('d', -735), balance('e', 0)];

    const transfers = suggestTransfers(balances);

    expect(transfers.length).toBeLessThanOrEqual(balances.length - 1);
    const after = new Map(balances.map((b) => [b.userId, b.netCents as number]));
    for (const transfer of transfers) {
      after.set(transfer.fromUserId, after.get(transfer.fromUserId)! + transfer.amountCents);
      after.set(transfer.toUserId, after.get(transfer.toUserId)! - transfer.amountCents);
    }
    expect([...after.values()].every((net) => net === 0)).toBe(true);
  });

  it('refuses balances that do not sum to zero', () => {
    expect(() => suggestTransfers([balance('a', 1)])).toThrow(/sum to 1/);
  });
});
