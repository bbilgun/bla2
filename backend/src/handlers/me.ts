import { withHandler } from '../lib/http';
import * as account from '../services/account';

/** GET /me — the caller from the token; also registers them and refreshes their name in groups */
export const handler = withHandler((req) => account.getMe(req));

/** DELETE /me — leave every group, delete bills, the users row and the Cognito user. 409 while money is owed. */
export const remove = withHandler((req) => account.deleteAccount(req));
