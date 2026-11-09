import { requireParam, withHandler } from '../lib/http';
import * as expenses from '../services/expenses';

/** POST /groups/{groupId}/expenses — requires Idempotency-Key */
export const create = withHandler((req) => expenses.createExpense(req, requireParam(req, 'groupId')));

/** GET /groups/{groupId}/expenses?limit=20&cursor=<id> */
export const list = withHandler((req) => expenses.listExpenses(req, requireParam(req, 'groupId')));
