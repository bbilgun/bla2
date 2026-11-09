// The shared steps of a two-step image upload (receipts and the bank QR): pick a key, then check the
// key the app confirms before saving it. Nothing points at a key until it's confirmed.
import { randomUUID } from 'node:crypto';
import { badRequest, conflict } from '../domain/errors';
import type { Logger } from '../lib/logger';
import { deleteObject, IMAGE_EXTENSIONS, objectExists, type ImageContentType } from '../lib/s3';

// What we put after the prefix: a UUID and an image extension. Nothing else can be confirmed.
const KEY_TAIL = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|heic)$/;

/** A fresh, unguessable key under `prefix`. */
export function newImageKey(prefix: string, contentType: ImageContentType): string {
  return `${prefix}${randomUUID()}.${IMAGE_EXTENSIONS[contentType]}`;
}

/**
 * Checks a key the app says it uploaded. Throws 400 INVALID_UPLOAD_KEY unless it's a key we could have
 * signed under `prefix`, and 409 UPLOAD_NOT_FOUND unless the object is really in S3.
 */
export async function requireUploadedKey(key: string, prefix: string): Promise<void> {
  const ours = key.startsWith(prefix) && KEY_TAIL.test(key.slice(prefix.length));
  if (!ours) {
    throw badRequest('INVALID_UPLOAD_KEY', 'That upload key does not belong here');
  }
  if (!(await objectExists(key))) {
    throw conflict('UPLOAD_NOT_FOUND', 'The file has not been uploaded (or the upload failed); try again');
  }
}

/**
 * Deletes the object a new upload replaced. The new key is already saved by now, so a failure here
 * only leaves an orphan in the bucket. It's logged, not thrown.
 */
export async function discardReplaced(previous: string | null | undefined, current: string, log: Logger): Promise<void> {
  if (!previous || previous === current) return;
  try {
    await deleteObject(previous);
  } catch (err) {
    log.warn('upload.cleanup_failed', { err });
  }
}
