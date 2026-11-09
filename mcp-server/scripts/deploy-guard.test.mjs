import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { requiresSignedTokens, signingKeyProblem } from "./deploy-guard.mjs";

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
