import { requireParam, withHandler } from '../lib/http';
import * as settlements from '../services/settlements';

/** POST /groups/{groupId}/settlements — requires Idempotency-Key */
export const create = withHandler((req) => settlements.createSettlement(req, requireParam(req, 'groupId')));

/** GET /groups/{groupId}/settlements */
export const list = withHandler((req) => settlements.listSettlements(req, requireParam(req, 'groupId')));
