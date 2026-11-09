// Usage: node security/revocation-reapply/run.ts <revocation_log.json> <backup time in epoch ms> > plan.json
// <revocation_log.json> is the output of
//   wrangler d1 execute <db> --remote --json --command "SELECT id, at, kind, subject, value FROM revocation_log ORDER BY id"
// (an array of {results: [...]}, or the rows themselves). Prints the plan only;
// applying it (wrangler kv bulk put / delete) is a separate, reviewed step.
import { readFileSync } from 'node:fs';
import { planReapply, type LogRow } from './lib.ts';

const path = process.argv[2];
if (!path) { console.error('usage: run.ts <revocation_log.json>'); process.exit(2); }
const data = JSON.parse(readFileSync(path, 'utf8'));
const rows: LogRow[] = Array.isArray(data) && data[0]?.results ? data.flatMap((part: { results: LogRow[] }) => part.results) : data;
const backupAt = Number(process.argv[3]);
if (!Number.isFinite(backupAt) || backupAt <= 0) { console.error('usage: run.ts <revocation_log.json> <backup time, epoch ms>'); process.exit(2); }
console.log(JSON.stringify(planReapply(rows, Date.now(), backupAt), null, 2));
