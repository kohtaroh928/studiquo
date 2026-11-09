import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { configSection, requiresSignedTokens, signingKeyProblem } from "./deploy-guard.mjs";

const config = readFileSync(new URL("../wrangler.jsonc", import.meta.url), "utf8");

test("production requires signed tokens, staging does not (as configured)", () => {
  assert.equal(requiresSignedTokens(config, ""), true);
  assert.equal(requiresSignedTokens(config, "staging"), false);
});
test("production deploy stops without TOKEN_SIGNING_KEY and passes with it", () => {
  assert.match(signingKeyProblem(config, "", ["RESEND_API_KEY"]), /TOKEN_SIGNING_KEY/);
  assert.equal(signingKeyProblem(config, "", ["TOKEN_SIGNING_KEY"]), null);
});
test("staging deploy is not blocked", () => {
  assert.equal(signingKeyProblem(config, "staging", []), null);
});
test("a staging block that turns the requirement on is caught", () => {
  const text = config.replace('"REQUIRE_SIGNED_TOKENS": "false"', '"REQUIRE_SIGNED_TOKENS": "true"');
  assert.equal(requiresSignedTokens(text, "staging"), true);
  assert.equal(requiresSignedTokens(text, ""), true);
});
test("unknown environment names, malformed environment names, and configs without an env block are handled safely", () => {
  // Unknown identifier environment not present in wrangler.jsonc
  assert.equal(requiresSignedTokens(config, "preview"), false);
  assert.equal(signingKeyProblem(config, "preview", []), null);

  // Non-identifier environment name fails closed (requires TOKEN_SIGNING_KEY)
  assert.equal(requiresSignedTokens(config, "staging.*"), true);
  assert.match(signingKeyProblem(config, "staging.*", []), /TOKEN_SIGNING_KEY/);
  assert.equal(signingKeyProblem(config, "staging.*", ["TOKEN_SIGNING_KEY"]), null);

  // Config without a top-level "env" block
  const flatConfig = '{\n  "vars": {\n    "REQUIRE_SIGNED_TOKENS": "true"\n  }\n}';
  assert.equal(configSection(flatConfig, ""), flatConfig);
  assert.equal(configSection(flatConfig, "staging"), "");
  assert.equal(requiresSignedTokens(flatConfig, ""), true);
  assert.equal(requiresSignedTokens(flatConfig, "staging"), false);
});
