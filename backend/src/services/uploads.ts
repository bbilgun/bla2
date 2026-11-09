import { randomUUID } from 'node:crypto';
import { badRequest, conflict } from '../domain/errors';
import type { Logger } from '../lib/logger';
import { deleteObject, IMAGE_EXTENSIONS, objectExists, type ImageContentType } from '../lib/s3';

/**
 * Two-step uploads (receipts, the bank QR):
 *   1. sign: the server picks the key under a prefix only this resource/user owns and signs a POST for it.
 *   2. confirm: the app says "done"; the server checks the key is under that same prefix and the object is
 *      really in S3, saves it, and deletes the object it replaced.
 * Nothing points at a key until step 2, so an abandoned upload never shows up as a broken image.
 */

const KEY_TAIL = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|heic)$/;

export function newImageKey(prefix: string, contentType: ImageContentType): string {
  return `${prefix}${randomUUID()}.${IMAGE_EXTENSIONS[contentType]}`;
}

/** 400 INVALID_UPLOAD_KEY unless the key is one we could have signed under `prefix`; 409 UPLOAD_NOT_FOUND unless it's in S3. */
export async function requireUploadedKey(key: string, prefix: string): Promise<void> {
  if (!key.startsWith(prefix) || !KEY_TAIL.test(key.slice(prefix.length))) {
    throw badRequest('INVALID_UPLOAD_KEY', 'That upload key does not belong here');
  }
  if (!(await objectExists(key))) {
    throw conflict('UPLOAD_NOT_FOUND', 'The file has not been uploaded (or the upload failed); try again');
  }
}

/** The new key is saved already; failing to delete the old object only leaves an orphan, never a broken link. */
export async function discardReplaced(previous: string | null | undefined, current: string, log: Logger): Promise<void> {
  if (!previous || previous === current) return;
  try {
    await deleteObject(previous);
  } catch (err) {
    log.warn('upload.cleanup_failed', { err });
  }
}
