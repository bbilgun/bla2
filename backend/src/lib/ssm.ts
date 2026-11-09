import { GetParameterCommand, SSMClient } from '@aws-sdk/client-ssm';

/**
 * Secrets are read from SSM Parameter Store at cold start, not baked into the function's environment
 * at deploy time: anyone who can read the Lambda configuration (console, GetFunction) would see them.
 *
 * Cached per container: a warm request never calls SSM. A failed read is forgotten so the next
 * request retries. Tests vi.mock this module.
 */
let client: SSMClient | undefined;
const cache = new Map<string, Promise<string>>();

export function getSecureParameter(name: string): Promise<string> {
  let value = cache.get(name);
  if (!value) {
    client ??= new SSMClient({});
    value = client.send(new GetParameterCommand({ Name: name, WithDecryption: true })).then((out) => {
      const v = out.Parameter?.Value;
      if (!v) throw new Error(`SSM parameter ${name} is empty`);
      return v;
    });
    const pending = value;
    pending.catch(() => {
      if (cache.get(name) === pending) cache.delete(name);
    });
    cache.set(name, pending);
  }
  return value;
}

/** Drop a cached value, e.g. after the database rejected the connection string (it may have been rotated). */
export function forgetParameter(name: string): void {
  cache.delete(name);
}
