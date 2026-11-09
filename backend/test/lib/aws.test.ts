import { CognitoIdentityProviderClient, UserNotFoundException } from '@aws-sdk/client-cognito-identity-provider';
import { NotFound, S3Client, S3ServiceException } from '@aws-sdk/client-s3';
import { SSMClient } from '@aws-sdk/client-ssm';
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import { deleteCognitoUser } from '../../src/lib/cognito';
import { bucketOrigin, objectExists } from '../../src/lib/s3';
import { getSecureParameter } from '../../src/lib/ssm';

/** The thin AWS wrappers, with the SDK clients' `send` stubbed: nothing here reaches AWS. */

beforeAll(() => {
  process.env.RECEIPTS_BUCKET = 'netzero-test-receipts';
  process.env.AWS_REGION = 'ap-northeast-1';
  process.env.AWS_ACCESS_KEY_ID = 'AKIATESTTESTTESTTEST';
  process.env.AWS_SECRET_ACCESS_KEY = 'test-secret';
  process.env.USER_POOL_ID = 'ap-northeast-1_test';
});
afterEach(() => vi.restoreAllMocks());

describe('ssm', () => {
  it('fetches with decryption once per name, and forgets a failure', async () => {
    const send = vi
      .spyOn(SSMClient.prototype, 'send')
      .mockRejectedValueOnce(new Error('throttled') as never)
      .mockResolvedValue({ Parameter: { Value: 'mongodb://x' } } as never);
    await expect(getSecureParameter('/p')).rejects.toThrow('throttled');
    expect(await getSecureParameter('/p')).toBe('mongodb://x');
    expect(await getSecureParameter('/p')).toBe('mongodb://x');
    expect(send).toHaveBeenCalledTimes(2);
    expect((send.mock.calls[1]![0] as { input: unknown }).input).toEqual({ Name: '/p', WithDecryption: true });
  });
});

describe('s3', () => {
  it('objectExists: 404 is false, other errors are thrown', async () => {
    const send = vi.spyOn(S3Client.prototype, 'send');
    send.mockResolvedValueOnce({} as never);
    expect(await objectExists('k')).toBe(true);
    send.mockRejectedValueOnce(new NotFound({ $metadata: { httpStatusCode: 404 }, message: 'nope' }) as never);
    expect(await objectExists('k')).toBe(false);
    const denied = new S3ServiceException({ name: 'Forbidden', $fault: 'client', $metadata: { httpStatusCode: 403 } });
    send.mockRejectedValueOnce(denied as never);
    await expect(objectExists('k')).rejects.toBe(denied);
  });

  it('bucketOrigin is the virtual-hosted bucket host for the region', () => {
    expect(bucketOrigin()).toBe('https://netzero-test-receipts.s3.ap-northeast-1.amazonaws.com');
  });
});

describe('cognito', () => {
  it('AdminDeleteUser by sub; a user that is already gone counts as deleted', async () => {
    const send = vi.spyOn(CognitoIdentityProviderClient.prototype, 'send').mockResolvedValueOnce({} as never);
    await deleteCognitoUser('sub-1');
    expect((send.mock.calls[0]![0] as { input: unknown }).input).toEqual({ UserPoolId: 'ap-northeast-1_test', Username: 'sub-1' });
    send.mockRejectedValueOnce(new UserNotFoundException({ $metadata: {}, message: 'gone' }) as never);
    await expect(deleteCognitoUser('sub-1')).resolves.toBeUndefined();
    send.mockRejectedValueOnce(new Error('boom') as never);
    await expect(deleteCognitoUser('sub-1')).rejects.toThrow('boom');
  });
});
