import { withHandler } from '../lib/http';
import { signView } from '../lib/s3';
import { upsertUser } from '../repositories/users';

/**
 * GET /me — returns the caller, straight from the verified token's claims.
 * Also records the user so others can add them to groups by email, and returns the bank details
 * and QR image saved from their last bill, to pre-fill the next one.
 */
export const handler = withHandler(async ({ caller }) => {
  const user = await upsertUser(caller);
  return {
    status: 200,
    body: {
      userId: user._id,
      email: user.email,
      name: user.name,
      payment: user.payment ?? null,
      payQrUrl: user.payQrKey ? await signView(user.payQrKey) : null,
    },
  };
});
