/**
 * Seeds a demo group straight into MongoDB.
 *
 *   MONGODB_URI='mongodb+srv://...' MONGODB_DB=netzero_dev npm run seed -- you@example.com 1000
 *
 * The email must belong to someone who has signed in to the app at least once (GET /me creates the user row).
 * Adds two demo members and N random expenses, all split by the same domain code the API uses.
 */
import { ObjectId } from 'mongodb';
import { cents } from '../src/domain/money';
import { computeSplit, type SplitInput } from '../src/domain/split';
import { closeDb, getDb } from '../src/repositories/db';
import type { ExpenseDoc, GroupDoc } from '../src/repositories/collections';
import { findUserByEmail, upsertUser } from '../src/repositories/users';

const [email, countArg = '50'] = process.argv.slice(2);
if (!email) {
  console.error('usage: npm run seed -- <your-email> [expenseCount]');
  process.exit(1);
}

const DESCRIPTIONS = ['Groceries', 'Dinner', 'Taxi', 'Coffee', 'Rent', 'Electricity', 'Movie', 'Train', 'Snacks', 'Gas'];

async function main() {
  const me = await findUserByEmail(email!);
  if (!me) throw new Error(`No user ${email}. Sign in to the app once (it calls GET /me), then re-run.`);

  const demo = await Promise.all([
    upsertUser({ userId: 'demo-bat', email: 'bat@demo.netzero', name: 'Bat' }),
    upsertUser({ userId: 'demo-saraa', email: 'saraa@demo.netzero', name: 'Saraa' }),
  ]);
  const members = [me, ...demo].map((u) => ({ userId: u._id, email: u.email, name: u.name, joinedAt: new Date() }));
  const ids = members.map((m) => m.userId);

  const db = await getDb();
  const group: GroupDoc = {
    _id: new ObjectId(),
    name: `Seeded group (${new Date().toISOString().slice(0, 10)})`,
    currency: 'USD',
    members,
    createdBy: me._id,
    createdAt: new Date(),
  };
  await db.collection<GroupDoc>('groups').insertOne(group);

  const count = Number.parseInt(countArg, 10);
  const docs: ExpenseDoc[] = [];
  for (let i = 0; i < count; i++) {
    const amount = cents(100 + Math.floor(Math.random() * 20_000));
    const paidBy = ids[i % ids.length]!;
    const split: SplitInput =
      i % 3 === 0
        ? { type: 'PERCENT', shares: ids.map((userId, j) => ({ userId, basisPoints: [5000, 2500, 2500][j]! })) }
        : { type: 'EVEN', userIds: ids };
    docs.push({
      _id: new ObjectId(),
      groupId: group._id,
      description: DESCRIPTIONS[i % DESCRIPTIONS.length]!,
      amountCents: amount,
      paidBy,
      splitType: split.type,
      splits: computeSplit(amount, split),
      createdBy: paidBy,
      createdAt: new Date(),
    });
  }
  if (docs.length) await db.collection<ExpenseDoc>('expenses').insertMany(docs);

  console.log(`Seeded group ${group._id.toHexString()} with ${docs.length} expenses for ${email}`);
}

main()
  .catch((err) => {
    console.error(err);
    process.exitCode = 1;
  })
  .finally(closeDb);
