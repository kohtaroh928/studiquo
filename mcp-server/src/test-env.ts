import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Env } from "./env.ts";

/**
 * A hand-made stand-in for the Worker's bindings. A test gives only the bindings
 * the code under test touches, so the object is not a complete `Env`; this says so
 * once, here, instead of with a cast at every call. The result keeps the stand-in's
 * own members (a test's `_kv`, `stats`, ...) next to the `Env` ones.
 */
export function partialEnv<T extends object>(parts: T): LooseEnv & T {
  return parts as unknown as LooseEnv & T;
}

/**
 * The type of such a stand-in. Every binding is `any` because a test swaps bindings for its own fakes
 * (`env.USER_REGISTRY = {...}`) and reads the fakes' bookkeeping back (`env.RATE_COUNTER.purged`), neither of
 * which the real binding types allow. Where the Worker code takes an `Env`, it is still accepted.
 */
export type LooseEnv = { [K in keyof Env]: any } & { [extra: string]: any };

/** A Durable Object instance's protected `ctx`, with `sql.exec` returning plain rows as the in-memory fake does. */
export function contextOf(instance: object): { storage: { sql: { exec(query: string, ...params: unknown[]): any[] } } } & DurableObjectState {
  return (instance as { ctx: never }).ctx;
}

/** The same for the execution context (`ctx`) a handler is called with: tests usually need only `waitUntil`. */
export function partialCtx<T extends object>(parts: T): ExecutionContext & T {
  return parts as unknown as ExecutionContext & T;
}

/** The same for the Durable Object state (`ctx`) a Durable Object method or helper is given. */
export function partialState<T extends object>(parts: T): DurableObjectState & T {
  return parts as unknown as DurableObjectState & T;
}

/** The same for the SQL storage (`ctx.storage.sql`) of a Durable Object, backed in tests by an in-memory SQLite. */
export function partialSql<T extends object>(parts: T): SqlStorage & T {
  return parts as unknown as SqlStorage & T;
}

/** The same for the Durable Object storage (`ctx.storage`). */
export function partialStorage<T extends object>(parts: T): DurableObjectStorage & T {
  return parts as unknown as DurableObjectStorage & T;
}

/** The same for a Durable Object namespace binding (`env.RATE_COUNTER`, ...) a test replaces by a fake. */
export function partialNamespace<Class extends Rpc.DurableObjectBranded | undefined, T extends object>(parts: T): DurableObjectNamespace<Class> & T {
  return parts as unknown as DurableObjectNamespace<Class> & T;
}

const migrations = join(dirname(fileURLToPath(import.meta.url)), "..", "migrations");

/** The names of the D1 migration files, in order. */
export function migrationFiles(): string[] {
  return readdirSync(migrations).sort();
}

/** The SQL of one D1 migration file. */
export function readMigration(file: string): string {
  return readFileSync(join(migrations, file), "utf8");
}
