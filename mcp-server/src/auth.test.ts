import assert from "node:assert/strict";
import test from "node:test";
import { secretsEqual } from "./auth.ts";

test("secretsEqual accepts only an identical secret", async () => {
  assert.equal(await secretsEqual("whsec_abc123", "whsec_abc123"), true);
  assert.equal(await secretsEqual("whsec_abc123", "whsec_abc124"), false);
  assert.equal(await secretsEqual("whsec_abc123", "whsec_abc12"), false);
  assert.equal(await secretsEqual("", "whsec_abc123"), false);
  assert.equal(await secretsEqual("Bearer whsec_abc123", "whsec_abc123"), false);
});

test("secretsEqual treats two empty strings as equal, so callers must reject an unset secret first", async () => {
  assert.equal(await secretsEqual("", ""), true);
});
