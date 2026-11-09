// The shape of every document as stored in MongoDB. Amounts are integer cents, user ids are Cognito subs.
// docs/backend.md walks through the data model and why some things are embedded.
import type { ObjectId } from 'mongodb';
import type { SplitType } from '../domain/split';

/** The bank account a bill's guests pay into. */
export interface PaymentInfo {
  bankName: string;
  accountNumber: string;
  accountName: string;
}

/** A signed-in user, recorded from their token. Keyed by Cognito sub. */
export interface UserDoc {
  _id: string;
  email: string;
  name: string;
  /** The bank details from their last bill, to pre-fill the next one. */
  payment?: PaymentInfo;
  /** S3 key of a screenshot of the user's own bank-app QR, shown to their bills' guests. */
  payQrKey?: string;
  createdAt: Date;
  updatedAt: Date;
}

/** A group member. Embedded in the group. */
export interface MemberDoc {
  userId: string;
  /** Copied from the member's token and refreshed when it changes (services/users.ts). */
  email: string;
  name: string;
  joinedAt: Date;
}

/** A pending invite. Matched against the invitee's verified email, so it works before they sign up. */
export interface InviteDoc {
  id: string;
  email: string;
  invitedBy: string;
  invitedByName: string;
  createdAt: Date;
}

/** A group of people sharing expenses. Members and invites are embedded: small, bounded, always read together. */
export interface GroupDoc {
  _id: ObjectId;
  name: string;
  currency: string;
  members: MemberDoc[];
  /** Absent on some older groups, which means none. Members plus invites stay within MAX_GROUP_SIZE. */
  invites?: InviteDoc[];
  createdBy: string;
  createdAt: Date;
  updatedAt?: Date;
  /** Set when the group is deleted. A deleted group behaves exactly like a missing one. */
  deletedAt?: Date;
  deletedBy?: string;
}

/** The editable part of an expense. */
export interface ExpenseContent {
  description: string;
  amountCents: number;
  paidBy: string;
  splitType: SplitType;
  /** Computed by the server once per write and embedded, sorted by user id. */
  splits: { userId: string; amountCents: number }[];
}

/** A replaced version of an expense, with who replaced it and when. */
export interface ExpenseVersionDoc extends ExpenseContent {
  version: number;
  changedBy: string;
  changedAt: Date;
}

/** An expense in a group's ledger. */
export interface ExpenseDoc extends ExpenseContent {
  _id: ObjectId;
  groupId: ObjectId;
  /** 1 on create and one more on every edit. Absent on older expenses, which count as version 1. */
  version?: number;
  receiptKey?: string;
  createdBy: string;
  createdAt: Date;
  updatedAt?: Date;
  updatedBy?: string;
  /** The last MAX_EXPENSE_HISTORY replaced versions, oldest first. Never sent to the app. */
  history?: ExpenseVersionDoc[];
  deletedAt?: Date;
  deletedBy?: string;
}

/** A recorded payment between two members: `fromUserId` paid `toUserId`. */
export interface SettlementDoc {
  _id: ObjectId;
  groupId: ObjectId;
  fromUserId: string;
  toUserId: string;
  amountCents: number;
  createdBy: string;
  createdAt: Date;
  deletedAt?: Date;
  deletedBy?: string;
}

/** A line on a bill. */
export interface BillItemDoc {
  id: string;
  name: string;
  priceCents: number;
}

/** Someone on a bill. The host is one too (id "host"), so their own share counts like anyone's. */
export interface BillGuestDoc {
  id: string;
  name: string;
  /** The name trimmed and lower-cased. No two people on a bill share one, so transfer notes stay distinguishable. */
  nameKey?: string;
  isHost: boolean;
  /** sha256 of the secret only the guest's browser knows. Null for the host, who uses their login. */
  secretHash: string | null;
  itemIds: string[];
  /** What the guest marked as paid: the amount they saw and transferred. 0 means not marked. */
  paidCents?: number;
  /** Older guests may have only this flag. `paid: true` without paidCents means they paid their current total. */
  paid?: boolean;
  joinedAt: Date;
  updatedAt: Date;
}

/** A one-off bill. Guests are embedded: at most 50 and always read with the bill. */
export interface BillDoc {
  _id: ObjectId;
  hostUserId: string;
  hostName: string;
  /** Unguessable, and in the share link and QR. Anyone holding it can see the bill and join. */
  token: string;
  /** A short code for the bank transfer note, such as "7KQ2HM". */
  code: string;
  title: string;
  currency: string;
  items: BillItemDoc[];
  guests: BillGuestDoc[];
  /** Guest ids the host removed, so those browsers can't quietly rejoin. Capped. */
  removedGuestIds?: string[];
  payment: PaymentInfo | null;
  status: 'OPEN' | 'CLOSED';
  createdAt: Date;
  updatedAt: Date;
}

/** One Idempotency-Key a user sent, and the response to replay for it. Expires after 7 days. */
export interface IdempotencyDoc {
  _id: ObjectId;
  userId: string;
  key: string;
  /** sha256 of method, path and body, to spot a key reused for a different request. */
  requestHash: string;
  /** The _id the write uses. Retries reuse it, so the write itself can be insert-or-fetch. */
  resourceId: ObjectId;
  status: 'pending' | 'done';
  response?: { status: number; body: unknown };
  createdAt: Date;
}
