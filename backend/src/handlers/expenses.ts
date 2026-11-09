// Routes for a group's expenses. Each one hands the request to services/expenses.ts.
import { requireParam, withHandler } from '../lib/http';
import * as expenses from '../services/expenses';

/** POST /groups/{groupId}/expenses: needs an Idempotency-Key header. */
export const create = withHandler((req) => expenses.createExpense(req, requireParam(req, 'groupId')));

/** GET /groups/{groupId}/expenses?limit=20&cursor=<id>: newest first. */
export const list = withHandler((req) => expenses.listExpenses(req, requireParam(req, 'groupId')));

/** PUT /groups/{groupId}/expenses/{expenseId}: the create body plus the `version` it was based on. */
export const update = withHandler((req) =>
  expenses.updateExpense(req, requireParam(req, 'groupId'), requireParam(req, 'expenseId')),
);

/** DELETE /groups/{groupId}/expenses/{expenseId}: soft delete. */
export const remove = withHandler((req) =>
  expenses.deleteExpense(req, requireParam(req, 'groupId'), requireParam(req, 'expenseId')),
);
