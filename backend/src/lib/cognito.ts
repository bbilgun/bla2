// The only Cognito call the API makes: deleting the caller's own user on DELETE /me.
// Tests vi.mock this module.
import { AdminDeleteUserCommand, CognitoIdentityProviderClient, UserNotFoundException } from '@aws-sdk/client-cognito-identity-provider';

let client: CognitoIdentityProviderClient | undefined;

/**
 * Deletes a user from the pool in USER_POOL_ID. A user that's already gone counts as deleted, so this
 * is safe to repeat. The `sub` works as the username in every pool.
 */
export async function deleteCognitoUser(sub: string): Promise<void> {
  const userPoolId = process.env.USER_POOL_ID;
  if (!userPoolId) throw new Error('Missing environment variable USER_POOL_ID');

  client ??= new CognitoIdentityProviderClient({});
  try {
    await client.send(new AdminDeleteUserCommand({ UserPoolId: userPoolId, Username: sub }));
  } catch (err) {
    if (err instanceof UserNotFoundException) return;
    throw err;
  }
}
