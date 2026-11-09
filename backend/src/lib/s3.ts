import { GetObjectCommand, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

/**
 * Images never pass through Lambda. Lambda checks who may touch a key, then signs a short-lived URL,
 * and the phone (or a guest's browser) talks to the private bucket directly. That avoids Lambda's
 * 6 MB payload limit, and you don't pay for Lambda time while a photo uploads over a slow connection.
 */
const s3 = new S3Client({});
export const UPLOAD_TTL_SECONDS = 5 * 60;
export const VIEW_TTL_SECONDS = 15 * 60;
export const IMAGE_EXTENSIONS = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/heic': 'heic' } as const;
export type ImageContentType = keyof typeof IMAGE_EXTENSIONS;

function bucket(): string {
  const name = process.env.RECEIPTS_BUCKET;
  if (!name) throw new Error('Missing environment variable RECEIPTS_BUCKET');
  return name;
}

export function signUpload(key: string, contentType: ImageContentType): Promise<string> {
  return getSignedUrl(s3, new PutObjectCommand({ Bucket: bucket(), Key: key, ContentType: contentType }), {
    expiresIn: UPLOAD_TTL_SECONDS,
  });
}

export function signView(key: string): Promise<string> {
  return getSignedUrl(s3, new GetObjectCommand({ Bucket: bucket(), Key: key }), { expiresIn: VIEW_TTL_SECONDS });
}
