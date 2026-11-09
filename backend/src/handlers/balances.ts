import { requireParam, withHandler } from '../lib/http';
import { getBalances } from '../services/balances';

/** GET /groups/{groupId}/balances — derived from one aggregation, never stored */
export const handler = withHandler(async (req) => ({
  status: 200,
  body: await getBalances(req.caller, requireParam(req, 'groupId')),
}));
