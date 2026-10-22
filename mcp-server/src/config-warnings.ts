// A few settings quietly weaken a protection when something they depend on is
// missing: the signed-token requirement does nothing without a signing key, and
// App Attest falls back to "off" without its app id or key. Nothing refuses to
// start, because a Worker that rejected every request over a missing secret
// would be a worse outage than the gap, so the mismatch is written to the log
// (once per isolate) where an alert or a person reading the logs can see it.
import type { Env } from "./env.ts";
import { appAttestMode } from "./app-attest.ts";

/** The settings that ask for a protection the rest of the configuration cannot give. */
export function unsafeConfiguration(env: Env): string[] {
  const problems: string[] = [];
  if (env.REQUIRE_SIGNED_TOKENS === "true" && !env.TOKEN_SIGNING_KEY) {
    problems.push("REQUIRE_SIGNED_TOKENS is on but TOKEN_SIGNING_KEY is not set: unsigned tokens are not being rejected");
  }
  if ((env.APP_ATTEST_MODE === "log" || env.APP_ATTEST_MODE === "enforce") && appAttestMode(env) === "off") {
    problems.push("APP_ATTEST_MODE is set but App Attest is off: APP_ATTEST_APP_ID, TOKEN_SIGNING_KEY or RATE_COUNTER is missing or invalid");
  }
  return problems;
}

const reported = new WeakSet<object>();

export function warnOnUnsafeConfiguration(env: Env) {
  if (reported.has(env)) return;
  reported.add(env);
  for (const problem of unsafeConfiguration(env)) {
    console.error(JSON.stringify({ message: "unsafe configuration", problem }));
  }
}
