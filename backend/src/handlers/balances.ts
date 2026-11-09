// The balances route. The numbers come from one aggregation over the ledger on every read.
import { requireParam, withHandler } from '../lib/http';
import { getBalances } from '../services/balances';

/** GET /groups/{groupId}/balances: everyone's net position and suggested payments. */
export const handler = withHandler((req) => getBalances(req, requireParam(req, 'groupId')));
