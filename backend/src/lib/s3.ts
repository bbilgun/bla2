import { DeleteObjectCommand, GetObjectCommand, HeadObjectCommand, S3Client, S3ServiceException } from '@aws-sdk/client-s3';
import { createPresignedPost } from '@aws-sdk/s3-presigned-post';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

/**
 * Images never pass through Lambda. Lambda checks who may touch a key, then signs a short-lived URL,
 * and the phone (or a guest's browser) talks to the private bucket directly. That avoids Lambda's
 * 6 MB payload limit, and you don't pay for Lambda time while a photo uploads over a slow connection.
 *
 * Uploads are a presigned POST, not a PUT: a POST policy can cap the size and pin the Content-Type,
 * a presigned PUT can't. The key is only saved once the app confirms and we've seen the object (HEAD).
 *
 * Tests vi.mock this module for the calls that would reach AWS (head / delete).
 */
const s3 = new S3Client({});
export const UPLOAD_TTL_SECONDS = 5 * 60;
export const VIEW_TTL_SECONDS = 15 * 60;
export const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;
export const IMAGE_EXTENSIONS = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/heic': 'heic' } as const;
export type ImageContentType = keyof typeof IMAGE_EXTENSIONS;

function bucket(): string {
  const name = process.env.RECEIPTS_BUCKET;
  if (!name) throw new Error('Missing environment variable RECEIPTS_BUCKET');
  return name;
}

export interface SignedUpload {
  uploadUrl: string;
  method: 'POST';
  /** Every entry goes into the multipart form, before the file (which must be the last field, `file`). */
  fields: Record<string, string>;
  key: string;
  maxBytes: number;
  expiresIn: number;
}

export async function signUpload(key: string, contentType: ImageContentType): Promise<SignedUpload> {
  const { url, fields } = await createPresignedPost(s3, {
    Bucket: bucket(),
    Key: key,
    Fields: { 'Content-Type': contentType },
    Conditions: [
      ['content-length-range', 1, MAX_UPLOAD_BYTES],
      ['eq', '$Content-Type', contentType],
    ],
    Expires: UPLOAD_TTL_SECONDS,
  });
  return { uploadUrl: url, method: 'POST', fields, key, maxBytes: MAX_UPLOAD_BYTES, expiresIn: UPLOAD_TTL_SECONDS };
}

export function signView(key: string): Promise<string> {
  return getSignedUrl(s3, new GetObjectCommand({ Bucket: bucket(), Key: key }), { expiresIn: VIEW_TTL_SECONDS });
}

/**
 * Is the object there? A missing key is a 404 only because the role may s3:ListBucket (serverless.yml);
 * without it S3 answers 403 and we'd rather fail loudly than call a permissions bug "not uploaded".
 */
export async function objectExists(key: string): Promise<boolean> {
  try {
    await s3.send(new HeadObjectCommand({ Bucket: bucket(), Key: key }));
    return true;
  } catch (err) {
    if (err instanceof S3ServiceException && (err.name === 'NotFound' || err.$metadata.httpStatusCode === 404)) {
      return false;
    }
    throw err;
  }
}

/** Deleting a key that isn't there succeeds, so this is safe to repeat. */
export async function deleteObject(key: string): Promise<void> {
  await s3.send(new DeleteObjectCommand({ Bucket: bucket(), Key: key }));
}

/**
 * The origin presigned GET URLs point at (virtual-hosted style). The guest page's CSP allows images
 * from exactly this host, not every bucket on *.amazonaws.com. Null when no bucket is configured.
 */
export function bucketOrigin(): string | null {
  const name = process.env.RECEIPTS_BUCKET;
  if (!name) return null;
  const region = process.env.AWS_REGION ?? process.env.AWS_DEFAULT_REGION ?? 'us-east-1';
  return region === 'us-east-1' ? `https://${name}.s3.amazonaws.com` : `https://${name}.s3.${region}.amazonaws.com`;
}
