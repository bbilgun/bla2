import { MongoServerError, ObjectId, type Collection } from 'mongodb';
import type { SplitType } from '../domain/split';
import { getDb } from './db';

/** Document shapes as stored in MongoDB. Every amount is an integer number of cents. */

export interface PaymentInfo {
  bankName: string;
  accountNumber: string;
  accountName: string;
}

export interface UserDoc {
  _id: string; // Cognito sub
  email: string;
  name: string;
  /** Last bank details used on a bill: pre-fills the next one. */
  payment?: PaymentInfo;
  /** S3 key of a screenshot of the user's own bank-app "receive money" QR, shown to bill guests. */
  payQrKey?: string;
  createdAt: Date;
  updatedAt: Date;
}

export interface MemberDoc {
  userId: string;
  email: string;
  name: string;
  joinedAt: Date;
}

export interface GroupDoc {
  _id: ObjectId;
  name: string;
  currency: string;
  members: MemberDoc[]; // embedded: always read with the group, small and bounded
  createdBy: string;
  createdAt: Date;
}

export interface ExpenseDoc {
  _id: ObjectId;
  groupId: ObjectId;
  description: string;
  amountCents: number;
  paidBy: string;
  splitType: SplitType;
  splits: { userId: string; amountCents: number }[]; // embedded: computed once by the server
  receiptKey?: string;
  createdBy: string;
  createdAt: Date;
}

export interface SettlementDoc {
  _id: ObjectId;
  groupId: ObjectId;
  fromUserId: string;
  toUserId: string;
  amountCents: number;
  createdBy: string;
  createdAt: Date;
}

export interface BillItemDoc {
  id: string;
  name: string;
  priceCents: number;
}

export interface BillGuestDoc {
  id: string;
  name: string;
  /** The host is a guest too (id "host"), so their own share of the food is counted like anyone's. */
  isHost: boolean;
  /** sha256 of the secret only the guest's browser knows. Null for the host, who uses their login. */
  secretHash: string | null;
  itemIds: string[];
  paid: boolean;
  joinedAt: Date;
  updatedAt: Date;
}

/** A one-off bill. Guests are embedded: bounded (max 50) and always read with the bill. */
export interface BillDoc {
  _id: ObjectId;
  hostUserId: string;
  hostName: string;
  /** Unguessable, in the share link and QR. Anyone holding it can see the bill and join. */
  token: string;
  /** Short human code for the bank transfer note ("NZ-7KQ2HM Бат"). */
  code: string;
  title: string;
  currency: string;
  items: BillItemDoc[];
  guests: BillGuestDoc[];
  payment: PaymentInfo | null;
  status: 'OPEN' | 'CLOSED';
  createdAt: Date;
  updatedAt: Date;
}

export interface IdempotencyDoc {
  _id: ObjectId;
  userId: string;
  key: string;
  requestHash: string;
  /** The _id the write will use. Retries reuse it, so the write itself is insert-or-fetch. */
  resourceId: ObjectId;
  status: 'pending' | 'done';
  response?: { status: number; body: unknown };
  createdAt: Date;
}

export const users = async (): Promise<Collection<UserDoc>> => (await getDb()).collection<UserDoc>('users');
export const groups = async (): Promise<Collection<GroupDoc>> => (await getDb()).collection<GroupDoc>('groups');
export const expenses = async (): Promise<Collection<ExpenseDoc>> => (await getDb()).collection<ExpenseDoc>('expenses');
export const settlements = async (): Promise<Collection<SettlementDoc>> =>
  (await getDb()).collection<SettlementDoc>('settlements');
export const bills = async (): Promise<Collection<BillDoc>> => (await getDb()).collection<BillDoc>('bills');
export const idempotencyKeys = async (): Promise<Collection<IdempotencyDoc>> =>
  (await getDb()).collection<IdempotencyDoc>('idempotency_keys');

export function isDuplicateKeyError(err: unknown): boolean {
  return err instanceof MongoServerError && err.code === 11000;
}

/** Parses a path id; anything malformed is treated as "doesn't exist". */
export function toObjectId(id: string): ObjectId | null {
  return /^[a-f0-9]{24}$/.test(id) ? new ObjectId(id) : null;
}
