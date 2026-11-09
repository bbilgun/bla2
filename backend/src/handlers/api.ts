// The single Lambda behind the whole API. API Gateway matches the route and checks the Cognito JWT,
// then this file picks the handler by the event's routeKey, such as "GET /groups/{groupId}".
import type { APIGatewayProxyEventV2, APIGatewayProxyStructuredResultV2, Context } from 'aws-lambda';
import { json } from '../lib/http';
import * as balances from './balances';
import * as billPage from './billPage';
import * as bills from './bills';
import * as expenses from './expenses';
import * as groups from './groups';
import * as health from './health';
import * as me from './me';
import * as receipts from './receipts';
import * as settlements from './settlements';

type RouteHandler = (event: never, context: Context) => Promise<APIGatewayProxyStructuredResultV2>;

/**
 * Every route the function serves, by route key. It must list exactly the httpApi events in
 * serverless.yml; test/integration/router.test.ts checks that.
 */
export const routes: Record<string, RouteHandler> = {
  'GET /health': health.handler,
  'GET /me': me.handler,
  'DELETE /me': me.remove,
  'POST /me/pay-qr-url': me.payQrUploadUrl,
  'PUT /me/pay-qr': me.confirmPayQr,
  'POST /groups': groups.create,
  'GET /groups': groups.list,
  'GET /groups/{groupId}': groups.get,
  'PATCH /groups/{groupId}': groups.rename,
  'DELETE /groups/{groupId}': groups.remove,
  'POST /groups/{groupId}/invites': groups.invite,
  'DELETE /groups/{groupId}/invites/{inviteId}': groups.cancelInvite,
  'POST /groups/{groupId}/invites/{inviteId}/accept': groups.acceptInvite,
  'POST /groups/{groupId}/invites/{inviteId}/decline': groups.declineInvite,
  'GET /invites': groups.listInvites,
  'POST /groups/{groupId}/leave': groups.leave,
  'DELETE /groups/{groupId}/members/{userId}': groups.removeMember,
  'POST /groups/{groupId}/expenses': expenses.create,
  'GET /groups/{groupId}/expenses': expenses.list,
  'PUT /groups/{groupId}/expenses/{expenseId}': expenses.update,
  'DELETE /groups/{groupId}/expenses/{expenseId}': expenses.remove,
  'POST /groups/{groupId}/expenses/{expenseId}/receipt-url': receipts.uploadUrl,
  'GET /groups/{groupId}/expenses/{expenseId}/receipt-url': receipts.viewUrl,
  'PUT /groups/{groupId}/expenses/{expenseId}/receipt': receipts.confirm,
  'POST /groups/{groupId}/settlements': settlements.create,
  'GET /groups/{groupId}/settlements': settlements.list,
  'DELETE /groups/{groupId}/settlements/{settlementId}': settlements.remove,
  'GET /groups/{groupId}/balances': balances.handler,
  'POST /bills': bills.create,
  'GET /bills': bills.list,
  'GET /bills/{billId}': bills.get,
  'PUT /bills/{billId}': bills.update,
  'DELETE /bills/{billId}': bills.remove,
  'POST /bills/{billId}/token': bills.rotateToken,
  'POST /bills/{billId}/status': bills.setStatus,
  'PUT /bills/{billId}/guests/{guestId}': bills.updateGuest,
  'DELETE /bills/{billId}/guests/{guestId}': bills.removeGuest,
  'GET /b/{token}': billPage.page,
  'GET /b/{token}/data': billPage.data,
  'POST /b/{token}/guests': billPage.join,
  'PUT /b/{token}/guests/{guestId}': billPage.updateGuest,
};

/** The Lambda entry point (`functions.api.handler` in serverless.yml). An unknown route key is a 404. */
export async function handler(event: APIGatewayProxyEventV2, context: Context): Promise<APIGatewayProxyStructuredResultV2> {
  const route = routes[event.routeKey];
  if (!route) {
    return json(404, { error: { code: 'ROUTE_NOT_FOUND', message: `No route for ${event.routeKey}` } });
  }
  return route(event as never, context);
}
