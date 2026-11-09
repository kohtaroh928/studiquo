// `npm run deploy` runs this first. If the target environment requires signed tokens
// (REQUIRE_SIGNED_TOKENS="true" in wrangler.jsonc) but the Worker has no TOKEN_SIGNING_KEY
// secret, the signature check would silently pass everything (src/token-signature.ts), so
// the deploy is stopped. Secret names only are read; values are never printed.
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

/** The part of wrangler.jsonc that applies to `environment` ("" = top level / production). */
export function configSection(text, environment) {
  const marker = text.search(/\n {2}"env"\s*:\s*\{/);
  if (marker < 0) return environment ? "" : text;
  return environment ? text.slice(marker) : text.slice(0, marker);
}

export function requiresSignedTokens(text, environment) {
  const section = configSection(text, environment);
  if (!environment) return /^\s*"REQUIRE_SIGNED_TOKENS"\s*:\s*"true"/m.test(section);
  const block = new RegExp(`"${environment}"\\s*:\\s*\\{[\\s\\S]*?"REQUIRE_SIGNED_TOKENS"\\s*:\\s*"(true|false)"`).exec(section);
  return block?.[1] === "true";
}

/** A message when the deploy must stop, otherwise null. */
export function signingKeyProblem(text, environment, secretNames) {
  if (!requiresSignedTokens(text, environment)) return null;
  if (secretNames.includes("TOKEN_SIGNING_KEY")) return null;
  return `REQUIRE_SIGNED_TOKENS is "true" for ${environment || "production"} but the Worker has no TOKEN_SIGNING_KEY secret. Set it first (docs/RUNBOOK.md RB-14), or the signature check would let every token through.`;
}

function environmentOf(args) {
  const index = args.findIndex(arg => arg === "--env" || arg === "-e");
  if (index >= 0) return args[index + 1] ?? "";
  const joined = args.find(arg => arg.startsWith("--env="));
  return joined ? joined.slice("--env=".length) : "";
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const environment = environmentOf(args);
  const text = readFileSync(new URL("../wrangler.jsonc", import.meta.url), "utf8");
  if (requiresSignedTokens(text, environment)) {
    const listed = spawnSync("npx", ["wrangler", "secret", "list", "--format", "json", ...(environment ? ["--env", environment] : [])], { encoding: "utf8" });
    let names;
    try { names = JSON.parse(listed.stdout).map(item => item.name); } catch { names = null; }
    if (!names) { console.error("deploy stopped: could not list the Worker's secrets to check TOKEN_SIGNING_KEY."); process.exit(1); }
    const problem = signingKeyProblem(text, environment, names);
    if (problem) { console.error(`deploy stopped: ${problem}`); process.exit(1); }
  }
  const deployed = spawnSync("npx", ["wrangler", "deploy", ...args], { stdio: "inherit" });
  process.exit(deployed.status ?? 1);
}
