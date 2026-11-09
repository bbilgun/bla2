/**
 * Confirms the balances aggregation uses the {groupId, _id} index instead of scanning every expense.
 *
 *   MONGODB_URI='mongodb+srv://...' MONGODB_DB=netzero_dev npm run explain:balances -- <groupId>
 *
 * Look for IXSCAN on groupId_id. COLLSCAN means the index is missing.
 */
import { ObjectId } from 'mongodb';
import { balancesPipeline } from '../src/aggregations/balances';
import { closeDb, getDb } from '../src/repositories/db';

const groupId = process.argv[2];
if (!groupId || !ObjectId.isValid(groupId)) {
  console.error('usage: npm run explain:balances -- <groupId>');
  process.exit(1);
}

function findStages(node: unknown, out: string[] = []): string[] {
  if (Array.isArray(node)) node.forEach((n) => findStages(n, out));
  else if (node && typeof node === 'object') {
    const obj = node as Record<string, unknown>;
    if (typeof obj.stage === 'string') out.push(obj.indexName ? `${obj.stage}(${obj.indexName})` : obj.stage);
    Object.values(obj).forEach((v) => findStages(v, out));
  }
  return out;
}

async function main() {
  const db = await getDb();
  const id = new ObjectId(groupId);
  const plan = await db.collection('expenses').aggregate(balancesPipeline(id)).explain('executionStats');
  const stages = [...new Set(findStages(plan))];
  console.log('plan stages:', stages.join(' -> '));
  console.log(stages.some((s) => s.startsWith('IXSCAN')) ? 'OK: uses an index' : 'WARNING: no index scan');

  const started = Date.now();
  const rows = await db.collection('expenses').aggregate(balancesPipeline(id)).toArray();
  console.log(`balances for ${rows.length} people in ${Date.now() - started} ms:`, rows);
}

main()
  .catch((err) => {
    console.error(err);
    process.exitCode = 1;
  })
  .finally(closeDb);
