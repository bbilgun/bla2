import { z } from 'zod';
import { MAX_CENTS } from '../domain/money';

/** Zod DTOs: every request body is parsed here, at the boundary, before any service sees it. */

const userId = z.string().min(1).max(128);
const centsAmount = z.number().int('Amount must be whole cents').min(0).max(MAX_CENTS);
const positiveCents = centsAmount.min(1, 'Amount must be more than zero');

export const CreateGroupDto = z.object({
  name: z.string().trim().min(1, 'Name is required').max(80),
  currency: z
    .string()
    .regex(/^[A-Z]{3}$/, 'Use a 3-letter currency code')
    .default('USD'),
});
export type CreateGroupDto = z.infer<typeof CreateGroupDto>;

export const RenameGroupDto = z.object({
  name: z.string().trim().min(1, 'Name is required').max(80),
});
export type RenameGroupDto = z.infer<typeof RenameGroupDto>;

/** Invites go to an email; the invitee accepts once Cognito has verified they own it. */
export const InviteDto = z.object({
  email: z
    .string()
    .trim()
    .pipe(z.email('Enter a valid email').max(254))
    .transform((e) => e.toLowerCase()),
});
export type InviteDto = z.infer<typeof InviteDto>;

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

export const CreateExpenseDto = z.object({
  description: z.string().trim().min(1, 'Description is required').max(200),
  amountCents: positiveCents,
  paidBy: userId,
  split: SplitDto,
});
export type CreateExpenseDto = z.infer<typeof CreateExpenseDto>;

/** An edit sends the whole expense again plus the version it was based on (compare-and-set). */
export const UpdateExpenseDto = CreateExpenseDto.extend({
  version: z.number().int().min(1),
});
export type UpdateExpenseDto = z.infer<typeof UpdateExpenseDto>;

export const CreateSettlementDto = z
  .object({
    fromUserId: userId,
    toUserId: userId,
    amountCents: positiveCents,
  })
  .refine((s) => s.fromUserId !== s.toUserId, { message: 'Cannot settle with yourself', path: ['toUserId'] });
export type CreateSettlementDto = z.infer<typeof CreateSettlementDto>;

/** `?limit=&cursor=` for every newest-first list. The cursor is the last _id of the previous page. */
export const pageQuery = (defaultLimit: number) =>
  z.object({
    limit: z.coerce.number().int().min(1).max(100).default(defaultLimit),
    cursor: z
      .string()
      .regex(/^[a-f0-9]{24}$/, 'Invalid cursor')
      .optional(),
  });
export const PageQueryDto = pageQuery(20);
export type PageQueryDto = z.infer<typeof PageQueryDto>;

export const ReceiptUploadDto = z
  .object({
    contentType: z.enum(['image/jpeg', 'image/png', 'image/heic']).default('image/jpeg'),
  })
  .default({ contentType: 'image/jpeg' });

/** "I finished uploading this key." The server checks the prefix and that the object exists. */
export const ConfirmUploadDto = z.object({ key: z.string().min(1).max(512) });

// ---------------------------------------------------------------- bills (QR bill splitting)

const currencyCode = z.string().regex(/^[A-Z]{3}$/, 'Use a 3-letter currency code');
/** Ids the server hands out (items) or the guest's browser generates (guests): URL-safe random strings. */
const shortId = z.string().regex(/^[A-Za-z0-9_-]{1,64}$/, 'Invalid id');

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
export type PaymentDto = z.infer<typeof PaymentDto>;

/** The whole editable content of a bill. Create sends it once; edit sends it again in full. */
export const BillContentDto = z
  .object({
    title: z.string().trim().min(1, 'Title is required').max(80),
    currency: currencyCode.default('MNT'),
    items: z
      .array(
        z.object({
          /** Present when editing an existing line, so guests keep their ticks on it. */
          id: shortId.optional(),
          name: z.string().trim().min(1, 'Item name is required').max(80),
          priceCents: positiveCents,
        }),
      )
      .min(1, 'Add at least one item')
      .max(100),
    payment: PaymentDto.nullable().default(null),
  })
  .refine((b) => b.items.reduce((acc, i) => acc + i.priceCents, 0) <= MAX_CENTS, {
    message: 'Bill total is too large',
    path: ['items'],
  });
export type BillContentDto = z.infer<typeof BillContentDto>;

export const BillStatusDto = z.object({ status: z.enum(['OPEN', 'CLOSED']) });

/**
 * A guest joining from the web page. The browser makes up its own id and secret, so a retried join
 * (flaky restaurant wifi) finds the guest it already created instead of adding a second one.
 */
export const JoinBillDto = z.object({
  name: z.string().trim().min(1, 'Name is required').max(40),
  guestId: z.string().regex(/^[A-Za-z0-9_-]{16,64}$/, 'Invalid guest id'),
  secret: z.string().regex(/^[A-Za-z0-9_-]{32,128}$/, 'Invalid guest secret'),
});
export type JoinBillDto = z.infer<typeof JoinBillDto>;

/**
 * Ticks and/or the paid mark. Ticks are the full list (not a toggle), so resending is harmless.
 * `paid: true` stores `paidCents` (the amount the guest saw and transferred), or their current total
 * when it's absent; `paid: false` stores 0.
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
