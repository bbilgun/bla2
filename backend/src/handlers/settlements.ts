// Routes for payments recorded between group members. Each one hands the request to services/settlements.ts.
import { requireParam, withHandler } from '../lib/http';
import * as settlements from '../services/settlements';

/** POST /groups/{groupId}/settlements: needs an Idempotency-Key header. */
export const create = withHandler((req) => settlements.createSettlement(req, requireParam(req, 'groupId')));

/** GET /groups/{groupId}/settlements?limit=20&cursor=<id>: newest first. */
export const list = withHandler((req) => settlements.listSettlements(req, requireParam(req, 'groupId')));

/** DELETE /groups/{groupId}/settlements/{settlementId}: soft delete, by one of the two people in it. */
export const remove = withHandler((req) =>
  settlements.deleteSettlement(req, requireParam(req, 'groupId'), requireParam(req, 'settlementId')),
);
