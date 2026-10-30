import assert from "node:assert/strict";
import test from "node:test";
import { cloudflareToken } from "../scripts/rag-quality/cf-credential.ts";
import { judge, main } from "../scripts/rag-quality/check-cf-token.ts";

const DAY = 86_400_000;
const NOW = Date.parse("2026-10-30T00:00:00Z");
const fakeFile = (text: string) => () => text;

test("a dedicated token is used and OAuth is never read", () => {
  const read = () => { throw new Error("must not read the auth file"); };
  assert.equal(cloudflareToken({ CLOUDFLARE_API_TOKEN: " dedicated-fake " }, read), "dedicated-fake");
});

test("without a dedicated token the Wrangler OAuth login is refused by default", () => {
  assert.throws(() => cloudflareToken({}, fakeFile('oauth_token = "oauth-fake"')), { message: "dedicated_cloudflare_token_required" });
});

test("the OAuth login works only when it is allowed on purpose", () => {
  const env = { STUDIQUO_ALLOW_WRANGLER_OAUTH: "true" };
  assert.equal(cloudflareToken(env, fakeFile('oauth_token = "oauth-fake"')), "oauth-fake");
  assert.throws(() => cloudflareToken(env, fakeFile("")), { message: "cloudflare_auth_unavailable" });
  assert.throws(() => cloudflareToken(env, () => { throw new Error("ENOENT secret/path"); }), { message: "cloudflare_auth_unavailable" });
});

test("judge accepts a short-lived active token", () => {
  const v = judge({ status: "active", expires_on: new Date(NOW + 7 * DAY).toISOString() }, NOW);
  assert.equal(v.ok, true);
});

test("judge rejects no expiry, a long expiry, an expired token and an inactive token", () => {
  assert.equal(judge({ status: "active" }, NOW).ok, false);
  assert.equal(judge({ status: "active", expires_on: new Date(NOW + 60 * DAY).toISOString() }, NOW).ok, false);
  assert.equal(judge({ status: "active", expires_on: new Date(NOW - DAY).toISOString() }, NOW).ok, false);
  assert.equal(judge({ status: "disabled", expires_on: new Date(NOW + DAY).toISOString() }, NOW).ok, false);
  assert.equal(judge(null, NOW).ok, false);
});

test("check-cf-token never prints the token and needs both variables", async () => {
  const written: string[] = [];
  const out = process.stdout.write.bind(process.stdout);
  const err = process.stderr.write.bind(process.stderr);
  process.stdout.write = ((s: string) => (written.push(String(s)), true)) as any;
  process.stderr.write = ((s: string) => (written.push(String(s)), true)) as any;
  try {
    assert.equal(await main({}, (async () => { throw new Error("no network"); }) as any), 2);
    const fetcher = (async () => new Response(JSON.stringify({ success: true, result: { status: "active", expires_on: new Date(Date.now() + 3 * DAY).toISOString() } }), { status: 200 })) as any;
    assert.equal(await main({ CLOUDFLARE_ACCOUNT_ID: "acct", CLOUDFLARE_API_TOKEN: "secret-fake-value" }, fetcher), 0);
  } finally {
    process.stdout.write = out;
    process.stderr.write = err;
  }
  assert.ok(!written.join("").includes("secret-fake-value"));
});
