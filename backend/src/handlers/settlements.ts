import { requireParam, withHandler } from '../lib/http';
import * as settlements from '../services/settlements';

/** POST /groups/{groupId}/settlements — requires Idempotency-Key */
export const create = withHandler((req) => settlements.createSettlement(req, requireParam(req, 'groupId')));

/** GET /groups/{groupId}/settlements?limit=20&cursor=<id> */
export const list = withHandler((req) => settlements.listSettlements(req, requireParam(req, 'groupId')));

/** DELETE /groups/{groupId}/settlements/{settlementId} — soft delete, by one of the two parties */
export const remove = withHandler((req) =>
  settlements.deleteSettlement(req, requireParam(req, 'groupId'), requireParam(req, 'settlementId')),
);
