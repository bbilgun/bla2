// Reads secrets from SSM Parameter Store at cold start, so they never sit in the function's configuration
// where anyone with GetFunction could read them. Tests vi.mock this module.
import { GetParameterCommand, SSMClient } from '@aws-sdk/client-ssm';

let client: SSMClient | undefined;
const cache = new Map<string, Promise<string>>();

/**
 * The decrypted value of a SecureString parameter. Cached per container, so a warm request never
 * calls SSM. A failed read isn't cached, and the next call tries again.
 */
export function getSecureParameter(name: string): Promise<string> {
  const cached = cache.get(name);
  if (cached) return cached;

  client ??= new SSMClient({});
  const pending = client.send(new GetParameterCommand({ Name: name, WithDecryption: true })).then((out) => {
    const value = out.Parameter?.Value;
    if (!value) throw new Error(`SSM parameter ${name} is empty`);
    return value;
  });
  pending.catch(() => {
    if (cache.get(name) === pending) cache.delete(name);
  });
  cache.set(name, pending);
  return pending;
}

/** Drops a cached value, for example after the database rejected a connection string that may have been rotated. */
export function forgetParameter(name: string): void {
  cache.delete(name);
}
