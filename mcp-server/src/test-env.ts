import type { Env } from "./env.ts";

/**
 * A hand-made stand-in for the Worker's bindings. A test gives only the bindings
 * the code under test touches, so the object is not a complete `Env`; this says so
 * once, here, instead of with a cast at every call. The result keeps the stand-in's
 * own members (a test's `_kv`, `stats`, ...) next to the `Env` ones.
 */
export function partialEnv<T extends object>(parts: T): Env & T {
  return parts as unknown as Env & T;
}

/** The same for the execution context (`ctx`) a handler is called with: tests usually need only `waitUntil`. */
export function partialCtx<T extends object>(parts: T): ExecutionContext & T {
  return parts as unknown as ExecutionContext & T;
}

/** The same for the Durable Object state (`ctx`) a Durable Object method or helper is given. */
export function partialState<T extends object>(parts: T): DurableObjectState & T {
  return parts as unknown as DurableObjectState & T;
}
