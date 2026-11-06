// Runs the real Worker under Miniflare with every store persisted to a temporary
// directory, and with every outbound fetch either answered by a local fake or
// refused and recorded. Nothing here talks to Cloudflare: wrangler is not used,
// no remote bindings are configured, and the production ids in wrangler.jsonc are
// never read (only `vars`, the rate limit names and the Durable Object classes).
import { createRequire } from 'node:module';
import { createPublicKey, generateKeyPairSync, randomBytes, sign, type KeyObject } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve, join } from 'node:path';
import type { Readable } from 'node:stream';
import { redact, routeOf, splitSql, stripJsonc } from './lib.ts';

export const repositoryRoot = fileURLToPath(new URL('../../', import.meta.url));
const require = createRequire(resolve(repositoryRoot, 'mcp-server/package.json'));
const { Miniflare, Log, LogLevel, Response: MiniflareResponse } = require('miniflare');
const { build } = require('esbuild');

/** Stable Miniflare 4 supports this date; production uses the one in wrangler.jsonc. */
export const DRILL_COMPATIBILITY_DATE = '2026-07-30';
const BASE_URL = 'http://127.0.0.1:8090';
const REQUEST_DEADLINE_MS = 90_000;

/** A setup or harness problem, as opposed to something the Worker did. Exit code 2. */
export class HarnessFailure extends Error {}

export async function deadline<T>(work: Promise<T>, label: string, ms = REQUEST_DEADLINE_MS): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([work, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new HarnessFailure(`${label} timed out`)), ms);
    })]);
  } finally {
    clearTimeout(timer);
  }
}

interface WranglerConfig {
  compatibility_date: string;
  compatibility_flags: string[];
  vars: Record<string, string>;
  ratelimits: { name: string }[];
  durable_objects: { bindings: { name: string; class_name: string }[] };
  migrations: { new_sqlite_classes?: string[] }[];
}

export async function readWranglerConfig(): Promise<WranglerConfig> {
  return JSON.parse(stripJsonc(await readFile(resolve(repositoryRoot, 'mcp-server/wrangler.jsonc'), 'utf8')));
}

export async function bundleWorker(): Promise<string> {
  const bundled = await build({
    entryPoints: [resolve(repositoryRoot, 'mcp-server/src/worker.ts')],
    bundle: true, write: false, format: 'esm', platform: 'neutral', mainFields: ['browser', 'module', 'main'],
    conditions: ['workerd', 'worker', 'browser'], external: ['cloudflare:workers', 'node:*'], logLevel: 'silent',
  });
  return bundled.outputFiles[0].text;
}

/** Every secret the Worker expects, made up for this run and kept in memory. */
export interface SyntheticSecrets {
  bindings: Record<string, string>;
  webhookSecret: string;
  accessHost: string;
  accessAudience: string;
  signAccessJwt(claims: Record<string, unknown>): string;
  jwks: { keys: Record<string, unknown>[] };
}

const base64Url = (value: Buffer | string) => Buffer.from(value).toString('base64url');

export function createSecrets(): SyntheticSecrets {
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const kid = randomBytes(8).toString('hex');
  const jwk = createPublicKey(privateKey as KeyObject).export({ format: 'jwk' }) as Record<string, unknown>;
  const accessHost = `access-${randomBytes(4).toString('hex')}.drill.invalid`;
  const accessAudience = randomBytes(16).toString('hex');
  const webhookSecret = randomBytes(32).toString('base64url');
  return {
    webhookSecret, accessHost, accessAudience,
    jwks: { keys: [{ ...jwk, kid, alg: 'ES256', use: 'sig' }] },
    signAccessJwt(claims) {
      const head = base64Url(JSON.stringify({ alg: 'ES256', kid, typ: 'JWT' }));
      const body = base64Url(JSON.stringify(claims));
      const signature = sign('sha256', Buffer.from(`${head}.${body}`), { key: privateKey as KeyObject, dsaEncoding: 'ieee-p1363' });
      return `${head}.${body}.${base64Url(signature)}`;
    },
    bindings: {
      TOKEN_SIGNING_KEY: randomBytes(32).toString('base64'),
      SNAPSHOT_ENCRYPTION_KEY: randomBytes(32).toString('base64'),
      RESEND_API_KEY: `drill-${randomBytes(16).toString('hex')}`,
      REVENUECAT_SECRET_API_KEY: `drill-${randomBytes(16).toString('hex')}`,
      REVENUECAT_WEBHOOK_SECRET: webhookSecret,
      ACCESS_TEAM_DOMAIN: accessHost,
      ACCESS_AUD: accessAudience,
    },
  };
}

export interface OutboundCall { host: string; method: string; }

/**
 * Stands in for the whole internet. A known provider gets a local fake (mail is
 * read for its code, RevenueCat DELETEs are counted by customer); anything else is
 * refused and recorded, and the run fails on it.
 */
export function createOutboundGuard(secrets: SyntheticSecrets) {
  const state = {
    mocked: [] as OutboundCall[],
    unexpected: [] as OutboundCall[],
    /** Latest code mailed to each address. */
    codes: new Map<string, string>(),
    /** Customer ids RevenueCat was asked to delete, in order. */
    revenueCatDeletes: [] as string[],
    /** Attempts the guard control made on purpose (counted apart from `unexpected`). */
    controlBlocked: [] as OutboundCall[],
    expectBlocked: false,
  };
  const reply = (body: string, status = 200, headers: Record<string, string> = {}) => new MiniflareResponse(body, { status, headers });
  const handler = async (request: Request) => {
    const url = new URL(request.url);
    const call = { host: url.hostname, method: request.method };
    if (url.hostname === 'api.resend.com' && request.method === 'POST' && url.pathname === '/emails') {
      state.mocked.push(call);
      const mail = await request.json() as { to?: string; text?: string };
      const code = /確認コード: (\d{6})/.exec(mail.text ?? '')?.[1];
      if (code && typeof mail.to === 'string') state.codes.set(mail.to, code);
      return reply(JSON.stringify({ id: 'drill' }), 200, { 'content-type': 'application/json' });
    }
    if (url.hostname === 'api.pwnedpasswords.com' && request.method === 'GET' && url.pathname.startsWith('/range/')) {
      state.mocked.push(call);
      return reply('');
    }
    if (url.hostname === 'api.revenuecat.com' && request.method === 'DELETE' && url.pathname.startsWith('/v1/subscribers/')) {
      state.mocked.push(call);
      state.revenueCatDeletes.push(decodeURIComponent(url.pathname.slice('/v1/subscribers/'.length)));
      return reply('{}', 200, { 'content-type': 'application/json' });
    }
    if (url.hostname === secrets.accessHost && request.method === 'GET' && url.pathname === '/cdn-cgi/access/certs') {
      state.mocked.push(call);
      return reply(JSON.stringify(secrets.jwks), 200, { 'content-type': 'application/json' });
    }
    (state.expectBlocked ? state.controlBlocked : state.unexpected).push(call);
    return reply('External requests disabled', 502);
  };
  return { state, handler };
}

export type OutboundGuard = ReturnType<typeof createOutboundGuard>;

export interface StoreDirectories { kv: string; d1: string; do: string; }

export interface HttpResult {
  status: number;
  text: string;
  // Parsed response; the probes check the fields they read.
  json: any; // eslint-disable-line @typescript-eslint/no-explicit-any
}

export interface CallOptions {
  method?: string;
  token?: string | null;
  json?: unknown;
  form?: Record<string, string>;
  headers?: Record<string, string>;
  ip?: string;
}

export interface ServerError { method: string; route: string; status: number; }

export interface KvEntryName { name: string; expiration?: number; metadata?: unknown; }
export interface KvBinding {
  get(key: string, type?: 'text'): Promise<string | null>;
  put(key: string, value: string, options?: { expiration?: number; metadata?: unknown }): Promise<void>;
  list(options: { prefix?: string; cursor?: string; limit?: number }): Promise<{ keys: KvEntryName[]; list_complete: boolean; cursor?: string }>;
}
export interface D1Binding {
  prepare(sql: string): { bind(...values: unknown[]): { all(): Promise<{ results: Record<string, unknown>[] }>; first(): Promise<Record<string, unknown> | null>; run(): Promise<unknown> }; run(): Promise<unknown>; all(): Promise<{ results: Record<string, unknown>[] }> };
}
// Durable Object stubs reached through Miniflare's proxy.
export type DoNamespace = { idFromName(name: string): unknown; get(id: unknown): any }; // eslint-disable-line @typescript-eslint/no-explicit-any

export interface WorkerInstance {
  kv: KvBinding;
  d1: D1Binding;
  doNamespace(binding: string): Promise<DoNamespace>;
  call(path: string, options?: CallOptions): Promise<HttpResult>;
  /** Runs the Worker's scheduled handler once and returns its outcome. */
  cron(): Promise<string>;
  serverErrors: ServerError[];
  runtimeErrors: string[];
  stop(): Promise<void>;
}

export interface StartOptions {
  script: string;
  config: WranglerConfig;
  secrets: SyntheticSecrets;
  guard: OutboundGuard;
  dirs: StoreDirectories;
}

export async function startWorker({ script, config, secrets, guard, dirs }: StartOptions): Promise<WorkerInstance> {
  const serverErrors: ServerError[] = [];
  const runtimeErrors: string[] = [];
  const watch = (stream: Readable) => {
    let pending = '';
    stream.on('data', chunk => {
      pending += String(chunk);
      const lines = pending.split('\n');
      pending = lines.pop() ?? '';
      for (const line of lines) {
        if (/"message":"request failed"|uncaught|Error:|exception/i.test(line) && runtimeErrors.length < 200) runtimeErrors.push(redact(line));
      }
    });
  };
  const sqliteClasses = new Set(config.migrations.flatMap(item => item.new_sqlite_classes ?? []));
  const mf = new Miniflare({
    name: 'studiquo-mcp',
    host: '127.0.0.1', port: 0, cf: false, modules: true, script,
    compatibilityDate: DRILL_COMPATIBILITY_DATE, compatibilityFlags: config.compatibility_flags,
    kvNamespaces: ['STUDIQUO_DATA'], d1Databases: ['ADMIN_DB'],
    kvPersist: dirs.kv, d1Persist: dirs.d1, durableObjectsPersist: dirs.do, cachePersist: false,
    durableObjects: Object.fromEntries(config.durable_objects.bindings.map(binding => [binding.name, { className: binding.class_name, useSQLite: sqliteClasses.has(binding.class_name) }])),
    // Limits are not what is being tested: a drill makes many sign-ins in a minute.
    ratelimits: Object.fromEntries(config.ratelimits.map((limit, index) => [limit.name, { namespace_id: `drill-${index}`, simple: { limit: 1_000_000, period: 60 } }])),
    bindings: { ...config.vars, ...secrets.bindings },
    outboundService: guard.handler,
    log: new Log(LogLevel.NONE),
    handleRuntimeStdio: (stdout: Readable, stderr: Readable) => { watch(stdout); watch(stderr); },
  });
  try {
    await deadline(mf.ready, 'Workers startup');
    const kv = await deadline<KvBinding>(mf.getKVNamespace('STUDIQUO_DATA'), 'KV binding');
    const d1 = await deadline<D1Binding>(mf.getD1Database('ADMIN_DB'), 'D1 binding');
    const worker = await deadline<{ scheduled(options: { cron: string }): Promise<{ outcome: string }> }>(mf.getWorker(), 'Worker handle');
    const call = async (path: string, options: CallOptions = {}): Promise<HttpResult> => {
      const headers: Record<string, string> = { ...options.headers };
      if (options.token) headers.authorization = `Bearer ${options.token}`;
      if (options.ip) headers['cf-connecting-ip'] = options.ip;
      let body: string | undefined;
      if (options.json !== undefined) {
        headers['content-type'] ??= 'application/json';
        body = JSON.stringify(options.json);
      } else if (options.form) {
        headers['content-type'] = 'application/x-www-form-urlencoded';
        body = new URLSearchParams(options.form).toString();
      }
      const method = options.method ?? (body === undefined ? 'GET' : 'POST');
      const response = await deadline<Response>(mf.dispatchFetch(`${BASE_URL}${path}`, { method, headers, body, redirect: 'manual' }), `${method} ${routeOf(path)}`);
      const text = await deadline(response.text(), `${method} ${routeOf(path)} body`);
      if (response.status >= 500) serverErrors.push({ method, route: routeOf(path), status: response.status });
      let parsed: unknown = null;
      try { parsed = JSON.parse(text); } catch { /* not JSON: the page or an empty body */ }
      return { status: response.status, text, json: parsed };
    };
    return {
      kv, d1, call, serverErrors, runtimeErrors,
      doNamespace: binding => deadline<DoNamespace>(mf.getDurableObjectNamespace(binding), `${binding} binding`),
      cron: async () => (await deadline(worker.scheduled({ cron: '0 * * * *' }), 'scheduled handler', 180_000)).outcome,
      stop: () => deadline<void>(mf.dispose(), 'Workers shutdown'),
    };
  } catch (error) {
    await mf.dispose().catch(() => {});
    throw error;
  }
}

/** Runs every migration in name order, one statement at a time. */
export async function applyMigrations(d1: D1Binding) {
  const directory = resolve(repositoryRoot, 'mcp-server/migrations');
  const names = (await readdir(directory)).filter(name => name.endsWith('.sql')).sort();
  const expectedTables = new Set<string>();
  let statements = 0;
  for (const name of names) {
    const sql = await readFile(join(directory, name), 'utf8');
    for (const statement of splitSql(sql)) {
      const table = /^CREATE\s+(?:VIRTUAL\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([A-Za-z0-9_]+)/i.exec(statement)?.[1];
      if (table) expectedTables.add(table);
      try {
        await d1.prepare(statement).run();
      } catch (error) {
        throw new HarnessFailure(`Migration ${name} failed: ${redact(error instanceof Error ? error.message : String(error))}`);
      }
      statements++;
    }
  }
  return { files: names.length, statements, expectedTables: [...expectedTables] };
}
