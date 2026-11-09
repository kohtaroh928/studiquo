// Pure helpers for the restore drill: reading the Worker's config, splitting the
// D1 migrations into statements, sorting KV keys into restore categories, and the
// verdict logic that compares one probe across the three states it was seen in.
import { createHash } from 'node:crypto';

export const sha256 = (value: string) => createHash('sha256').update(value).digest('hex');

/** Removes comments and trailing commas from JSONC, leaving string contents alone. */
export function stripJsonc(text: string): string {
  let out = '';
  let index = 0;
  while (index < text.length) {
    const char = text[index];
    const next = text[index + 1];
    if (char === '"') {
      let end = index + 1;
      while (end < text.length && text[end] !== '"') end += text[end] === '\\' ? 2 : 1;
      out += text.slice(index, end + 1);
      index = end + 1;
    } else if (char === '/' && next === '/') {
      while (index < text.length && text[index] !== '\n') index++;
    } else if (char === '/' && next === '*') {
      const end = text.indexOf('*/', index + 2);
      index = end < 0 ? text.length : end + 2;
    } else {
      if (char === '}' || char === ']') out = out.replace(/,\s*$/, '');
      out += char;
      index++;
    }
  }
  return out;
}

/**
 * Splits a migration file into single statements. D1's own exec() splits on
 * newlines, which breaks multi-line statements, so the drill runs them one by
 * one. A trigger body holds semicolons, so `;` only ends a trigger once its
 * BEGIN/CASE ... END nesting has closed.
 */
export function splitSql(sql: string): string[] {
  const statements: string[] = [];
  let current = '';
  let depth = 0;
  let index = 0;
  const isTrigger = () => /^\s*CREATE\s+(TEMP\s+|TEMPORARY\s+)?TRIGGER\b/i.test(current);
  const finish = () => {
    if (current.trim()) statements.push(`${current.trim()};`);
    current = '';
    depth = 0;
  };
  while (index < sql.length) {
    const char = sql[index];
    const next = sql[index + 1];
    if (char === '-' && next === '-') {
      while (index < sql.length && sql[index] !== '\n') index++;
    } else if (char === '/' && next === '*') {
      const end = sql.indexOf('*/', index + 2);
      index = end < 0 ? sql.length : end + 2;
    } else if (char === "'" || char === '"' || char === '`') {
      let end = index + 1;
      while (end < sql.length) {
        if (sql[end] === char) {
          if (sql[end + 1] !== char) break;
          end++;
        }
        end++;
      }
      current += sql.slice(index, end + 1);
      index = end + 1;
    } else if (/[A-Za-z_]/.test(char)) {
      let end = index + 1;
      while (end < sql.length && /[A-Za-z0-9_]/.test(sql[end])) end++;
      const word = sql.slice(index, end);
      current += word;
      index = end;
      if (isTrigger()) {
        const upper = word.toUpperCase();
        if (upper === 'BEGIN' || upper === 'CASE') depth++;
        else if (upper === 'END') depth--;
      }
    } else if (char === ';') {
      if (isTrigger() && depth > 0) current += char;
      else finish();
      index++;
    } else {
      current += char;
      index++;
    }
  }
  finish();
  return statements;
}

export type KvCategory = 'must-keep' | 'mixed' | 'may-lose' | 'must-not-restore';

// Where each key family stands in a key-by-key restore. `mixed` means it cannot
// simply be lost, but its old value cannot simply be put back either.
const KV_CATEGORIES: Record<KvCategory, readonly string[]> = {
  'must-keep': ['passkey-account:', 'chat:linktoken:', 'chat:group-avatar:', 'doc-room:'],
  mixed: [
    'account:', 'session-valid-from:', 'revoked:', 'account-deletion:', 'privacy-account-delete:', 'privacy-rc-delete:',
    'account-suspended:', 'chat-suspended:', 'identity-canonical:', 'email-accounts:', 'email-account-owner:',
    'passkeys:credential:', 'passkeys:user:', 'passkey-valid-from:', 'passkey-reset-hold:', 'passkey-index-backfilled',
    'mcp:grant:', 'mcp:refresh-used:', 'mcp:token-index-since', 'chat:user:', 'chat:code:', 'chat:avatar:', 'chat:devices:',
    'chat:device-owner:', 'doc-invite:',
  ],
  'may-lose': [
    'session-refreshed:', 'session-predecessor:', 'passkey-recovery:', 'mcp:client:', 'mcp:token-index:', 'actions:',
    'chat-identity-of:', 'chat:group-meta:', 'chat:group-code:', 'issue-report:', 'issue-report-screenshot:', 'report:chat:',
    'ops:cron-last-run',
  ],
  'must-not-restore': [
    'session:', 'privacy-cursor:', 'email-verify:', 'passkeys:challenge:', 'passkey-reauth:', 'passkey-email-proof:',
    'passkey-index-backfill-cursor', 'mcp:access:', 'mcp:refresh:', 'mcp:code:', 'mcp:auth:', 'mcp:owner-code:',
    'mcp:owner-code-active:', 'snapshot:', 'apple:jwks', 'google:jwks',
  ],
};

const KV_PREFIXES = (Object.entries(KV_CATEGORIES) as [KvCategory, readonly string[]][])
  .flatMap(([category, prefixes]) => prefixes.map(prefix => [prefix, category] as const))
  .sort((first, second) => second[0].length - first[0].length);

/** The category of a KV key (longest matching prefix), or null for a family the table does not know. */
export function kvCategory(name: string): KvCategory | null {
  return KV_PREFIXES.find(([prefix]) => name.startsWith(prefix))?.[1] ?? null;
}

/** The family a key belongs to, for reports: never the variable part, which can name a person. */
export function kvFamily(name: string): string {
  return KV_PREFIXES.find(([prefix]) => name.startsWith(prefix))?.[0] ?? '(unclassified)';
}

/** Blanks anything that could carry a value out of a log line: addresses, hashes, tokens. */
export function redact(text: string): string {
  return text
    .replace(/[^\s"'<>@:/]+@[^\s"'<>@:/]+/g, '[address]')
    .replace(/\b\d{9,12}\.[A-Za-z0-9_-]{16,}(\.[A-Za-z0-9_-]{43})?/g, '[token]')
    .replace(/\bmcp_[A-Za-z0-9_.-]+/g, '[token]')
    .replace(/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/g, '[jwt]')
    .replace(/\b[0-9a-f]{32,}\b/gi, '[hash]')
    .slice(0, 400);
}

/** A request path with its variable parts removed, so reports can name the route. */
export function routeOf(path: string): string {
  return path.split('?')[0]
    .replace(/\/[0-9a-f]{32,}/gi, '/:hash')
    .replace(/\/[0-9a-f-]{36}(?=\/|$)/gi, '/:uuid')
    .replace(/\/[A-Z0-9]{6,32}(?=\/|$)/g, '/:code')
    .replace(/\/\d+(?=\/|$)/g, '/:n');
}

export type ProbeKind = 'access' | 'data' | 'control' | 'post-backup' | 'replay';

export interface ProbeShape {
  id: string;
  kind: ProbeKind;
  /** 'backup': the probe works at the backup point. 'post': it needs what only exists afterwards. */
  stage: 'backup' | 'post';
}

export type Verdict =
  | 'not-revived' //   same as after the revocation
  | 'reverted' //      same as at the backup point (for access/data probes: revived)
  | 'partial' //       neither state: a new one the restore created
  | 'unchanged' //     a control, as it should be
  | 'control-lost' //  a control that stopped working
  | 'kept' //          post-backup state still there
  | 'lost' //          post-backup state gone
  | 'replayed' //      a stale job or call fired again
  | 'server-error'; // 5xx

export const isServerError = (observed: string) => /(^|:)5\d\d(:|$)/.test(observed);

/**
 * Compares one probe in a restored state with the same probe at the backup point
 * (`atBackup`, absent for post-backup probes) and after the revocations (`baseline`).
 * Nothing here expects a particular outcome: a probe only says what it saw, and
 * the verdict comes from which earlier state that matches.
 */
export function verdictFor(probe: ProbeShape, atBackup: string | undefined, baseline: string, observed: string): Verdict {
  if (isServerError(observed)) return 'server-error';
  if (probe.kind === 'control') return observed === baseline ? 'unchanged' : 'control-lost';
  if (probe.kind === 'replay') return observed === baseline ? 'not-revived' : 'replayed';
  if (probe.stage === 'post' || probe.kind === 'post-backup') return observed === baseline ? 'kept' : 'lost';
  if (observed === baseline) return 'not-revived';
  if (observed === atBackup) return 'reverted';
  return 'partial';
}

/** The probes that show the same thing before and after the revocation, so cannot tell the two apart. */
export function nonDiscriminating(probes: readonly ProbeShape[], atBackup: Record<string, string>, baseline: Record<string, string>): string[] {
  return probes
    .filter(probe => (probe.kind === 'access' || probe.kind === 'data') && probe.stage === 'backup')
    .filter(probe => atBackup[probe.id] === baseline[probe.id])
    .map(probe => probe.id);
}

/** One line of the matrix: what happened to one actor in one scenario. */
export function actorCell(verdicts: readonly Verdict[], kinds: readonly ProbeKind[]): string {
  const marks = new Set<string>();
  verdicts.forEach((verdict, index) => {
    if (verdict === 'server-error') marks.add('E');
    else if (verdict === 'partial') marks.add('P');
    else if (verdict === 'replayed') marks.add('J');
    else if (verdict === 'control-lost') marks.add('C');
    else if (verdict === 'lost') marks.add('L');
    else if (verdict === 'reverted') marks.add(kinds[index] === 'data' ? 'D' : 'R');
  });
  return ['R', 'D', 'J', 'P', 'E', 'C', 'L'].filter(mark => marks.has(mark)).join('') || '.';
}

// ---- After a KV restore: put back what happened since the backup -------------------------------

export interface KvItem { name: string; value: string; expiration?: number }
export interface ReconcilePlan { put: KvItem[]; remove: string[]; keptFromBackup: number }

/**
 * Brings a restored KV back in line with the state it had just before the restore (`before`,
 * exported while it could still be read). For every key that existed then, the earlier value wins:
 * a password changed, an account deleted, a connection granted or a session issued after the
 * backup is put back as it was. A key the restore added that did not exist then was removed on
 * purpose (a deleted account's data, a revoked grant, a revoked session) unless it belongs to a
 * family that is safe to lose and to get back: those stay, so the backup can still recover them.
 *
 * Needs the pre-restore export. If the namespace cannot be read at all, no plan can be made and
 * the restore must be treated as one that revives everything revoked since the backup.
 */
export function planReconcile(before: readonly KvItem[], restored: readonly KvItem[]): ReconcilePlan {
  const earlier = new Map(before.map(item => [item.name, item]));
  const current = new Map(restored.map(item => [item.name, item]));
  const put = before.filter(item => current.get(item.name)?.value !== item.value);
  let keptFromBackup = 0;
  const remove: string[] = [];
  for (const item of restored) {
    if (earlier.has(item.name)) continue;
    if (kvCategory(item.name) === 'may-lose') keptFromBackup++;
    else remove.push(item.name);
  }
  return { put, remove, keptFromBackup };
}
