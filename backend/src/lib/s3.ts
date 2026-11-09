// The receipts bucket. Images never pass through Lambda: we sign short-lived URLs and the phone or browser
// talks to the private bucket directly. Tests vi.mock objectExists and deleteObject; signing runs for real.
import { DeleteObjectCommand, GetObjectCommand, HeadObjectCommand, S3Client, S3ServiceException } from '@aws-sdk/client-s3';
import { createPresignedPost } from '@aws-sdk/s3-presigned-post';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

const s3 = new S3Client({});

/** How long an upload URL works, in seconds. */
export const UPLOAD_TTL_SECONDS = 5 * 60;
/** How long a view URL works, in seconds. */
export const VIEW_TTL_SECONDS = 15 * 60;
/** The largest image S3 will accept through an upload URL. */
export const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;
/** The image types we accept, and the file extension each one gets in its key. */
export const IMAGE_EXTENSIONS = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/heic': 'heic' } as const;
/** One of the accepted image content types. */
export type ImageContentType = keyof typeof IMAGE_EXTENSIONS;

function bucket(): string {
  const name = process.env.RECEIPTS_BUCKET;
  if (!name) throw new Error('Missing environment variable RECEIPTS_BUCKET');
  return name;
}

/** Everything the app needs to upload one image straight to S3 with a multipart form POST. */
export interface SignedUpload {
  uploadUrl: string;
  method: 'POST';
  /** Every entry goes into the form before the file, which must be the last field and be called `file`. */
  fields: Record<string, string>;
  key: string;
  maxBytes: number;
  expiresIn: number;
}

/**
 * Signs a POST that can upload one image to `key`. We use a presigned POST because its policy can cap
 * the size and pin the content type, which a presigned PUT can't.
 */
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

/** Signs a GET for `key` that works for VIEW_TTL_SECONDS. */
export function signView(key: string): Promise<string> {
  return getSignedUrl(s3, new GetObjectCommand({ Bucket: bucket(), Key: key }), { expiresIn: VIEW_TTL_SECONDS });
}

/**
 * Whether an object is in the bucket. S3 only answers 404 for a missing key because our role has
 * s3:ListBucket; without it the answer is 403, and that is thrown rather than read as "not uploaded".
 */
export async function objectExists(key: string): Promise<boolean> {
  try {
    await s3.send(new HeadObjectCommand({ Bucket: bucket(), Key: key }));
    return true;
  } catch (err) {
    const isNotFound = err instanceof S3ServiceException && (err.name === 'NotFound' || err.$metadata.httpStatusCode === 404);
    if (isNotFound) return false;
    throw err;
  }
}

/** Deletes an object. Deleting a key that isn't there succeeds, so this is safe to repeat. */
export async function deleteObject(key: string): Promise<void> {
  await s3.send(new DeleteObjectCommand({ Bucket: bucket(), Key: key }));
}

/**
 * The origin that signed view URLs point at (virtual-hosted style). The guest page's CSP allows images
 * from exactly this origin. Null when no bucket is configured.
 */
export function bucketOrigin(): string | null {
  const name = process.env.RECEIPTS_BUCKET;
  if (!name) return null;

  const region = process.env.AWS_REGION ?? process.env.AWS_DEFAULT_REGION ?? 'us-east-1';
  if (region === 'us-east-1') return `https://${name}.s3.amazonaws.com`;
  return `https://${name}.s3.${region}.amazonaws.com`;
}
