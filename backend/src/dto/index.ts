// Zod schemas for every request body and query string. Services parse input with these before doing
// anything else, so a service never sees unvalidated data. A failed parse becomes a 400 VALIDATION_ERROR.
import { ObjectId } from 'mongodb';
import { z } from 'zod';
import { MAX_CENTS } from '../domain/money';

const userId = z.string().min(1).max(128);
const centsAmount = z.number().int('Amount must be whole cents').min(0).max(MAX_CENTS);
const positiveCents = centsAmount.min(1, 'Amount must be more than zero');
const currencyCode = z.string().regex(/^[A-Z]{3}$/, 'Use a 3-letter currency code');
const groupName = z.string().trim().min(1, 'Name is required').max(80);

/** Body of POST /groups. The currency defaults to USD. */
export const CreateGroupDto = z.object({
  name: groupName,
  currency: currencyCode.default('USD'),
});

/** Body of PATCH /groups/{groupId}. */
export const RenameGroupDto = z.object({
  name: groupName,
});

/** Body of POST /groups/{groupId}/invites. The email is trimmed and lower-cased. */
export const InviteDto = z.object({
  email: z
    .string()
    .trim()
    .pipe(z.email('Enter a valid email').max(254))
    .transform((email) => email.toLowerCase()),
});

/** How to split an expense: evenly, by exact amounts, or by percentages in basis points. */
export const SplitDto = z.discriminatedUnion('type', [
  z.object({ type: z.literal('EVEN'), userIds: z.array(userId).min(1).max(50) }),
  z.object({
    type: z.literal('EXACT'),
    shares: z.array(z.object({ userId, amountCents: centsAmount })).min(1).max(50),
  }),
  z.object({
    type: z.literal('PERCENT'),
    shares: z
      .array(z.object({ userId, basisPoints: z.number().int('Use basis points: 33.33% is 3333').min(0).max(10_000) }))
      .min(1)
      .max(50),
  }),
]);

/** Body of POST /groups/{groupId}/expenses. */
export const CreateExpenseDto = z.object({
  description: z.string().trim().min(1, 'Description is required').max(200),
  amountCents: positiveCents,
  paidBy: userId,
  split: SplitDto,
});
export type CreateExpenseDto = z.infer<typeof CreateExpenseDto>;

/** Body of PUT on an expense: the whole expense again, plus the version the edit was based on. */
export const UpdateExpenseDto = CreateExpenseDto.extend({
  version: z.number().int().min(1),
});

/** Body of POST /groups/{groupId}/settlements: "from paid to this much". */
export const CreateSettlementDto = z
  .object({
    fromUserId: userId,
    toUserId: userId,
    amountCents: positiveCents,
  })
  .refine((s) => s.fromUserId !== s.toUserId, { message: 'Cannot settle with yourself', path: ['toUserId'] });

/**
 * `?limit=&cursor=` for a newest-first list. The cursor is the last id of the previous page and comes
 * out as an ObjectId.
 */
export function pageQuery(defaultLimit: number) {
  return z.object({
    limit: z.coerce.number().int().min(1).max(100).default(defaultLimit),
    cursor: z
      .string()
      .regex(/^[a-f0-9]{24}$/, 'Invalid cursor')
      .transform((id) => new ObjectId(id))
      .optional(),
  });
}

/** The usual page query: 20 items unless the app asks for another number. */
export const PageQueryDto = pageQuery(20);

/** Body of a request for an image upload URL. JPEG unless the app says otherwise; the body is optional. */
export const ImageUploadDto = z
  .object({
    contentType: z.enum(['image/jpeg', 'image/png', 'image/heic']).default('image/jpeg'),
  })
  .default({ contentType: 'image/jpeg' });

/** Body of an upload confirmation: the key the app just uploaded to. */
export const ConfirmUploadDto = z.object({ key: z.string().min(1).max(512) });

// Bills

/** Ids the server hands out (lines) or a guest's browser makes up (guests): URL-safe random strings. */
const shortId = z.string().regex(/^[A-Za-z0-9_-]{1,64}$/, 'Invalid id');

/** Where guests send the money: the host's bank account. */
export const PaymentDto = z.object({
  bankName: z.string().trim().min(1, 'Bank is required').max(60),
  accountNumber: z
    .string()
    .trim()
    .min(4, 'Account number is too short')
    .max(40)
    .regex(/^[0-9A-Za-z -]+$/, 'Account number: letters, digits, spaces and dashes only'),
  accountName: z.string().trim().min(1, 'Account holder is required').max(80),
});

/** The whole editable content of a bill. Create sends it once and every edit sends it again in full. */
export const BillContentDto = z
  .object({
    title: z.string().trim().min(1, 'Title is required').max(80),
    currency: currencyCode.default('MNT'),
    items: z
      .array(
        z.object({
          // Sent when editing an existing line, so guests keep their ticks on it.
          id: shortId.optional(),
          name: z.string().trim().min(1, 'Item name is required').max(80),
          priceCents: positiveCents,
        }),
      )
      .min(1, 'Add at least one item')
      .max(100),
    payment: PaymentDto.nullable().default(null),
  })
  .refine((bill) => bill.items.reduce((acc, item) => acc + item.priceCents, 0) <= MAX_CENTS, {
    message: 'Bill total is too large',
    path: ['items'],
  });
export type BillContentDto = z.infer<typeof BillContentDto>;

/** Body of POST /bills/{billId}/status. */
export const BillStatusDto = z.object({ status: z.enum(['OPEN', 'CLOSED']) });

/**
 * A guest joining from the web page. The browser makes up its own id and secret, so a retried join
 * on flaky wifi finds the guest it already created.
 */
export const JoinBillDto = z.object({
  name: z.string().trim().min(1, 'Name is required').max(40),
  guestId: z.string().regex(/^[A-Za-z0-9_-]{16,64}$/, 'Invalid guest id'),
  secret: z.string().regex(/^[A-Za-z0-9_-]{32,128}$/, 'Invalid guest secret'),
});

/**
 * A change to one guest: their full list of ticks, the paid mark, or both. Sending the full list
 * makes a resend harmless. `paidCents` is the amount the guest saw and transferred.
 */
export const GuestUpdateDto = z
  .object({
    itemIds: z.array(shortId).max(100).optional(),
    paid: z.boolean().optional(),
    paidCents: centsAmount.optional(),
  })
  .refine((u) => u.itemIds !== undefined || u.paid !== undefined || u.paidCents !== undefined, {
    message: 'Send itemIds or paid',
  });
export type GuestUpdateDto = z.infer<typeof GuestUpdateDto>;
