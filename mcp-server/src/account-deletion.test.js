import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { deleteAccount } from "./account-deletion.js";
import { linkVerifiedEmail } from "./oauth-links.js";
import worker from "./app.js";
import { mintSession } from "./session.js";
import { accountGenerationMethods } from "./test-account-generations.js";

function environment() {
  const values = new Map();
  const inboxes = new Map();
  const usageEvents = new Set();
  const usersFirstSeen = new Set();
  const appErrorUsers = new Set();
  return {
    STUDIQUO_DATA: {
      async get(key, type) {
        const value = values.get(key) ?? null;
        return type === "json" && value ? JSON.parse(value) : value;
      },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list({ prefix }) {
        return { keys: [...values.keys()].filter(key => key.startsWith(prefix)).map(name => ({ name })), list_complete: true };
      },
    },
    MCP_INBOX: {
      getByName(account) {
        return {
          async purge() { inboxes.delete(account); return { status: "purged" }; },
        };
      },
    },
    ADMIN_DB: {
      prepare(sql) {
        return {
          bind(userKey) {
            return {
              async all() { return { results: [] }; },
              async run() {
                if (sql.includes("usage_events")) usageEvents.delete(userKey);
                if (sql.includes("users_first_seen")) usersFirstSeen.delete(userKey);
                if (sql.includes("app_error_users")) appErrorUsers.delete(userKey);
                return { success: true };
              },
            };
          },
        };
      },
    },
    _values: values,
    _inboxes: inboxes,
    _usageEvents: usageEvents,
    _usersFirstSeen: usersFirstSeen,
    _appErrorUsers: appErrorUsers,
  };
}

const hash = value => createHash("sha256").update(value).digest("hex");

async function seedLinked(env, canonical, email, identities) {
  await env.STUDIQUO_DATA.put(`email-account-owner:${email}`, canonical);
  await env.STUDIQUO_DATA.put(`email-accounts:${email}`, JSON.stringify(identities));
  for (const identity of identities) {
    const key = identity.provider === "google" ? `google:${identity.sub}`
      : identity.provider === "email" ? `email:${identity.sub}` : identity.sub;
    await env.STUDIQUO_DATA.put(`identity-canonical:${key}`, canonical);
  }
}

test("1. Apple単独アカウントを完全削除できる", async () => {
  const env = environment();
  await seedLinked(env, "apple-1", "apple@example.com", [{ provider: "apple", sub: "apple-1" }]);
  await env.STUDIQUO_DATA.put("account:apple-1", "{}");
  await deleteAccount(env, "apple-1");
  assert.equal(await env.STUDIQUO_DATA.get("account:apple-1"), null);
  assert.equal(await env.STUDIQUO_DATA.get("email-accounts:apple@example.com"), null);
});

test("2. Google単独アカウントを完全削除できる", async () => {
  const env = environment();
  await seedLinked(env, "google:g-1", "google@example.com", [{ provider: "google", sub: "g-1" }]);
  await env.STUDIQUO_DATA.put("account:google:g-1", "{}");
  await deleteAccount(env, "google:g-1");
  assert.equal(await env.STUDIQUO_DATA.get("account:google:g-1"), null);
});

test("3. ローカル単独アカウントを完全削除できる", async () => {
  const env = environment();
  await seedLinked(env, "email:local@example.com", "local@example.com", [{ provider: "email", sub: "local@example.com" }]);
  await env.STUDIQUO_DATA.put("account:local:local@example.com", "{}");
  await deleteAccount(env, "email:local@example.com");
  assert.equal(await env.STUDIQUO_DATA.get("account:local:local@example.com"), null);
});

test("4. Apple・Google・ローカル・パスキーを統合したアカウントを一括削除できる", async () => {
  const env = environment();
  const identities = [
    { provider: "apple", sub: "apple-all" },
    { provider: "google", sub: "google-all" },
    { provider: "email", sub: "all@example.com" },
  ];
  await seedLinked(env, "apple-all", "all@example.com", identities);
  await env.STUDIQUO_DATA.put("account:apple-all", "{}");
  await env.STUDIQUO_DATA.put("account:google:google-all", "{}");
  await env.STUDIQUO_DATA.put("account:local:all@example.com", "{}");
  const credential = { id: "credential-1", email: "all@example.com" };
  await env.STUDIQUO_DATA.put("passkeys:credential:credential-1", JSON.stringify(credential));
  await env.STUDIQUO_DATA.put("passkeys:user:user-1", JSON.stringify([credential]));
  await deleteAccount(env, "apple-all");
  for (const key of ["account:apple-all", "account:google:google-all", "account:local:all@example.com", "passkeys:credential:credential-1", "passkeys:user:user-1"]) {
    assert.equal(await env.STUDIQUO_DATA.get(key), null, key);
  }
});

test("5. 削除したアカウントの全セッションが無効化される", async () => {
  const env = environment();
  await seedLinked(env, "apple-sessions", "sessions@example.com", [
    { provider: "apple", sub: "apple-sessions" }, { provider: "google", sub: "google-sessions" },
  ]);
  await env.STUDIQUO_DATA.put("session:one", JSON.stringify({ sub: "apple-sessions" }));
  await env.STUDIQUO_DATA.put("session:two", JSON.stringify({ sub: "google:google-sessions" }));
  await deleteAccount(env, "apple-sessions");
  assert.equal(await env.STUDIQUO_DATA.get("session:one"), null);
  assert.equal(await env.STUDIQUO_DATA.get("session:two"), null);
});

test("6. 別ユーザーのセッションとデータは削除されない", async () => {
  const env = environment();
  await seedLinked(env, "apple-delete", "delete@example.com", [{ provider: "apple", sub: "apple-delete" }]);
  await seedLinked(env, "apple-keep", "keep@example.com", [{ provider: "apple", sub: "apple-keep" }]);
  await env.STUDIQUO_DATA.put("account:apple-keep", JSON.stringify({ name: "同じ名前" }));
  await env.STUDIQUO_DATA.put("session:keep", JSON.stringify({ sub: "apple-keep" }));
  await deleteAccount(env, "apple-delete");
  assert.notEqual(await env.STUDIQUO_DATA.get("account:apple-keep"), null);
  assert.notEqual(await env.STUDIQUO_DATA.get("session:keep"), null);
  assert.notEqual(await env.STUDIQUO_DATA.get("email-accounts:keep@example.com"), null);
});

test("9. 削除後に同じメールで再登録すると新しい所有者になり旧フレンドコードを継承しない", async () => {
  const env = environment();
  await seedLinked(env, "apple-old", "again@example.com", [{ provider: "apple", sub: "apple-old" }]);
  await env.STUDIQUO_DATA.put("chat:code:OLDCODE", "old-chat-key");
  const oldHash = createHash("sha256").update("chat-account:apple-old").digest("hex");
  await env.STUDIQUO_DATA.put(`chat:user:${oldHash}`, JSON.stringify({ code: "OLDCODE", name: "以前" }));
  await deleteAccount(env, "apple-old");
  const relinked = await linkVerifiedEmail(env, { provider: "google", sub: "google-new", email: "again@example.com", emailVerified: true });
  assert.equal(relinked.canonicalIdentityKey, "google:google-new");
  assert.equal(await env.STUDIQUO_DATA.get(`chat:user:${oldHash}`), null);
  assert.equal(await env.STUDIQUO_DATA.get("chat:code:OLDCODE"), null);
});

test("10. 削除後に過去のidentity aliasから旧アカウントが復元されない", async () => {
  const env = environment();
  await seedLinked(env, "apple-old", "alias@example.com", [
    { provider: "apple", sub: "apple-old" }, { provider: "google", sub: "google-old" },
  ]);
  await deleteAccount(env, "apple-old");
  assert.equal(await env.STUDIQUO_DATA.get("identity-canonical:google:google-old"), null);
  const relinked = await linkVerifiedEmail(env, { provider: "google", sub: "google-old", email: "alias@example.com", emailVerified: true });
  assert.equal(relinked.canonicalIdentityKey, "google:google-old");
});

test("11. 異なるメールの同姓同名ユーザーは影響を受けない", async () => {
  const env = environment();
  await seedLinked(env, "apple-a", "a@example.com", [{ provider: "apple", sub: "apple-a" }]);
  await seedLinked(env, "apple-b", "b@example.com", [{ provider: "apple", sub: "apple-b" }]);
  await env.STUDIQUO_DATA.put("account:apple-a", JSON.stringify({ name: "山田太郎" }));
  await env.STUDIQUO_DATA.put("account:apple-b", JSON.stringify({ name: "山田太郎" }));
  await deleteAccount(env, "apple-a");
  assert.deepEqual(await env.STUDIQUO_DATA.get("account:apple-b", "json"), { name: "山田太郎" });
});

test("12. Apple非公開リレーアドレスの削除は実メール側を削除しない", async () => {
  const env = environment();
  await env.STUDIQUO_DATA.put("account:apple-relay", JSON.stringify({
    email: "hidden@privaterelay.appleid.com", emailIsPrivateRelay: true,
  }));
  await seedLinked(env, "google-real", "person@example.com", [{ provider: "google", sub: "real-google" }]);
  await env.STUDIQUO_DATA.put("account:google:real-google", "{}");
  await deleteAccount(env, "apple-relay");
  assert.equal(await env.STUDIQUO_DATA.get("account:apple-relay"), null);
  assert.notEqual(await env.STUDIQUO_DATA.get("account:google:real-google"), null);
  assert.notEqual(await env.STUDIQUO_DATA.get("email-accounts:person@example.com"), null);
});

test("13. 紐づくすべてのaccountレコードが削除される", async () => {
  const env = environment();
  await seedLinked(env, "apple-13", "all-accounts@example.com", [
    { provider: "apple", sub: "apple-13" },
    { provider: "google", sub: "google-13" },
    { provider: "email", sub: "all-accounts@example.com" },
  ]);
  for (const key of ["account:apple-13", "account:google:google-13", "account:local:all-accounts@example.com"]) {
    await env.STUDIQUO_DATA.put(key, "{}");
  }
  await deleteAccount(env, "apple-13");
  for (const key of ["account:apple-13", "account:google:google-13", "account:local:all-accounts@example.com"]) {
    assert.equal(await env.STUDIQUO_DATA.get(key), null, key);
  }
});

test("14. email-accountsとemail-account-ownerが削除される", async () => {
  const env = environment();
  await seedLinked(env, "apple-14", "indexes@example.com", [{ provider: "apple", sub: "apple-14" }]);
  await deleteAccount(env, "apple-14");
  assert.equal(await env.STUDIQUO_DATA.get("email-accounts:indexes@example.com"), null);
  assert.equal(await env.STUDIQUO_DATA.get("email-account-owner:indexes@example.com"), null);
});

test("15. 紐づくすべてのidentity-canonical aliasが削除される", async () => {
  const env = environment();
  const identities = [
    { provider: "apple", sub: "apple-15" },
    { provider: "google", sub: "google-15" },
    { provider: "email", sub: "aliases@example.com" },
  ];
  await seedLinked(env, "apple-15", "aliases@example.com", identities);
  await deleteAccount(env, "apple-15");
  for (const key of ["apple-15", "google:google-15", "email:aliases@example.com"]) {
    assert.equal(await env.STUDIQUO_DATA.get(`identity-canonical:${key}`), null, key);
  }
});

test("16. パスキーCredentialとユーザー索引がすべて削除される", async () => {
  const env = environment();
  await seedLinked(env, "email:passkeys@example.com", "passkeys@example.com", [
    { provider: "email", sub: "passkeys@example.com" },
  ]);
  const first = { id: "passkey-a", email: "passkeys@example.com" };
  const second = { id: "passkey-b", email: "passkeys@example.com" };
  await env.STUDIQUO_DATA.put("passkeys:credential:passkey-a", JSON.stringify(first));
  await env.STUDIQUO_DATA.put("passkeys:credential:passkey-b", JSON.stringify(second));
  await env.STUDIQUO_DATA.put("passkeys:user:device-a", JSON.stringify([first]));
  await env.STUDIQUO_DATA.put("passkeys:user:device-b", JSON.stringify([second]));
  await deleteAccount(env, "email:passkeys@example.com");
  for (const key of ["passkeys:credential:passkey-a", "passkeys:credential:passkey-b", "passkeys:user:device-a", "passkeys:user:device-b"]) {
    assert.equal(await env.STUDIQUO_DATA.get(key), null, key);
  }
});

test("18. 一部だけ旧形式のidentityデータでも完全削除できる", async () => {
  const env = environment();
  await env.STUDIQUO_DATA.put("identity-canonical:google:partial-google", "legacy-apple");
  await env.STUDIQUO_DATA.put("account:legacy-apple", "{}");
  await env.STUDIQUO_DATA.put("account:google:partial-google", "{}");
  await env.STUDIQUO_DATA.put("session:partial", JSON.stringify({ sub: "google:partial-google" }));
  await deleteAccount(env, "legacy-apple");
  for (const key of ["identity-canonical:google:partial-google", "account:legacy-apple", "account:google:partial-google", "session:partial"]) {
    assert.equal(await env.STUDIQUO_DATA.get(key), null, key);
  }
});

test("19. 旧形式email-accountsだけのアカウントも完全削除できる", async () => {
  const env = environment();
  await env.STUDIQUO_DATA.put("email-accounts:legacy@example.com", JSON.stringify([
    { provider: "apple", sub: "legacy-owner" },
    { provider: "google", sub: "legacy-google" },
  ]));
  await env.STUDIQUO_DATA.put("account:legacy-owner", "{}");
  await env.STUDIQUO_DATA.put("account:google:legacy-google", "{}");
  await deleteAccount(env, "legacy-owner");
  assert.equal(await env.STUDIQUO_DATA.get("email-accounts:legacy@example.com"), null);
  assert.equal(await env.STUDIQUO_DATA.get("account:legacy-owner"), null);
  assert.equal(await env.STUDIQUO_DATA.get("account:google:legacy-google"), null);
});

test("20. identityが上限の10件あるアカウントも全件削除できる", async () => {
  const env = environment();
  const identities = Array.from({ length: 10 }, (_, index) => ({ provider: "google", sub: `google-${index}` }));
  await seedLinked(env, "google:google-0", "ten@example.com", identities);
  for (let index = 0; index < 10; index++) {
    await env.STUDIQUO_DATA.put(`account:google:google-${index}`, "{}");
  }
  await deleteAccount(env, "google:google-0");
  for (let index = 0; index < 10; index++) {
    assert.equal(await env.STUDIQUO_DATA.get(`account:google:google-${index}`), null, `account ${index}`);
    assert.equal(await env.STUDIQUO_DATA.get(`identity-canonical:google:google-${index}`), null, `alias ${index}`);
  }
});

test("41. トークン由来とアカウント由来の全スナップショットが消える", async () => {
  const env = environment();
  const canonical = "account-sync-41";
  await env.STUDIQUO_DATA.put("session:token-hash-a", JSON.stringify({ sub: canonical }));
  await env.STUDIQUO_DATA.put("session:token-hash-b", JSON.stringify({ sub: canonical }));
  const accountHash = hash(`mcp-account:${canonical}`);
  for (const key of ["snapshot:token-hash-a", "snapshot:token-hash-b", `snapshot:${accountHash}`]) {
    await env.STUDIQUO_DATA.put(key, JSON.stringify({ version: 1 }));
  }

  await deleteAccount(env, canonical);

  for (const key of ["snapshot:token-hash-a", "snapshot:token-hash-b", `snapshot:${accountHash}`]) {
    assert.equal(await env.STUDIQUO_DATA.get(key), null, key);
  }
});

test("42. 保留中のMCPインポートが消える", async () => {
  const env = environment();
  const canonical = "account-inbox-42";
  const accountHash = hash(`mcp-account:${canonical}`);
  env._inboxes.set(accountHash, [
    { id: "pending-a", status: "pending" },
    { id: "pending-b", status: "pending" },
  ]);

  await deleteAccount(env, canonical);

  assert.equal(env._inboxes.has(accountHash), false);
});

test("43. MCP access token・refresh token・grantがすべて無効になる", async () => {
  const env = environment();
  const canonical = "account-mcp-43";
  const clientId = "client-43";
  const accessKey = `mcp:access:${hash("mcp_access_43")}`;
  const refreshKey = `mcp:refresh:${hash("mcp_refresh_43")}`;
  const grantKey = `mcp:grant:${hash(canonical)}:${hash(clientId)}`;
  await env.STUDIQUO_DATA.put(accessKey, JSON.stringify({ sub: canonical, clientId }));
  await env.STUDIQUO_DATA.put(refreshKey, JSON.stringify({ sub: canonical, clientId }));
  await env.STUDIQUO_DATA.put(grantKey, JSON.stringify({ sub: canonical, clientId }));

  await deleteAccount(env, canonical);

  for (const key of [accessKey, refreshKey, grantKey]) {
    assert.equal(await env.STUDIQUO_DATA.get(key), null, key);
  }
});

test("44. 削除済みMCPトークンでは資料を作成できない", async () => {
  const env = environment();
  const canonical = "account-mcp-44";
  const clientId = "client-44";
  const accessToken = "mcp_deleted_access_token_44";
  await env.STUDIQUO_DATA.put(`mcp:access:${hash(accessToken)}`, JSON.stringify({ sub: canonical, clientId, scope: "studiquo.read studiquo.write" }));
  await env.STUDIQUO_DATA.put(`mcp:grant:${hash(canonical)}:${hash(clientId)}`, JSON.stringify({ sub: canonical, clientId }));
  await deleteAccount(env, canonical);

  const response = await worker.fetch(new Request("https://example.test/mcp", {
    method: "POST",
    headers: {
      authorization: `Bearer ${accessToken}`,
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: "create_document", arguments: { title: "削除後", body: "作成不可" } },
    }),
  }), env, { waitUntil() {} });

  assert.equal(response.status, 401);
  assert.equal(env._inboxes.size, 0);
});

test("45. Push通知端末が全件削除される", async () => {
  const env = environment();
  const canonical = "account-push-45";
  const chatKey = hash(`chat-account:${canonical}`);
  const devices = [
    { token: "push-token-45-a", environment: "sandbox" },
    { token: "push-token-45-b", environment: "production" },
  ];
  await env.STUDIQUO_DATA.put(`chat:devices:${chatKey}`, JSON.stringify(devices));
  for (const device of devices) await env.STUDIQUO_DATA.put(`chat:device-owner:${device.token}`, chatKey);

  await deleteAccount(env, canonical);

  assert.equal(await env.STUDIQUO_DATA.get(`chat:devices:${chatKey}`), null);
  for (const device of devices) assert.equal(await env.STUDIQUO_DATA.get(`chat:device-owner:${device.token}`), null);
});

test("46. 利用状況のusage_eventsが削除される", async () => {
  const env = environment();
  const canonical = "account-usage-46";
  const usageHash = hash(`usage-account:${canonical}`);
  env._usageEvents.add(usageHash);
  await deleteAccount(env, canonical);
  assert.equal(env._usageEvents.has(usageHash), false);
});

test("47. users_first_seenが削除される", async () => {
  const env = environment();
  const canonical = "account-first-seen-47";
  const usageHash = hash(`usage-account:${canonical}`);
  env._usersFirstSeen.add(usageHash);
  await deleteAccount(env, canonical);
  assert.equal(env._usersFirstSeen.has(usageHash), false);
});

test("47b. 自動エラーの「影響ユーザー」の記録が削除される", async () => {
  const env = environment();
  const canonical = "account-app-errors-47b";
  const usageHash = hash(`usage-account:${canonical}`);
  env._appErrorUsers.add(usageHash);
  await deleteAccount(env, canonical);
  assert.equal(env._appErrorUsers.has(usageHash), false);
});

test("48. 別アカウントのMCP・同期・利用状況データは残る", async () => {
  const env = environment();
  const deleted = "account-delete-48";
  const kept = "account-keep-48";
  const keptSessionHash = "kept-session-hash-48";
  const keptAccountHash = hash(`mcp-account:${kept}`);
  const keptUsageHash = hash(`usage-account:${kept}`);
  const keptClient = "kept-client-48";
  const keptKeys = [
    `snapshot:${keptSessionHash}`,
    `snapshot:${keptAccountHash}`,
    `mcp:access:${hash("kept-access-48")}`,
    `mcp:refresh:${hash("kept-refresh-48")}`,
    `mcp:grant:${hash(kept)}:${hash(keptClient)}`,
  ];
  await env.STUDIQUO_DATA.put(`session:${keptSessionHash}`, JSON.stringify({ sub: kept }));
  await env.STUDIQUO_DATA.put(keptKeys[0], JSON.stringify({ owner: kept }));
  await env.STUDIQUO_DATA.put(keptKeys[1], JSON.stringify({ owner: kept }));
  await env.STUDIQUO_DATA.put(keptKeys[2], JSON.stringify({ sub: kept, clientId: keptClient }));
  await env.STUDIQUO_DATA.put(keptKeys[3], JSON.stringify({ sub: kept, clientId: keptClient }));
  await env.STUDIQUO_DATA.put(keptKeys[4], JSON.stringify({ sub: kept, clientId: keptClient }));
  env._inboxes.set(keptAccountHash, [{ id: "keep", status: "pending" }]);
  env._usageEvents.add(keptUsageHash);
  env._usersFirstSeen.add(keptUsageHash);

  await deleteAccount(env, deleted);

  for (const key of keptKeys) assert.notEqual(await env.STUDIQUO_DATA.get(key), null, key);
  assert.equal(env._inboxes.has(keptAccountHash), true);
  assert.equal(env._usageEvents.has(keptUsageHash), true);
  assert.equal(env._usersFirstSeen.has(keptUsageHash), true);
});

test("49. KV削除が途中で失敗しても再実行できる", async () => {
  const env = environment();
  const canonical = "account-kv-retry-49";
  await seedLinked(env, canonical, "retry49@example.com", [{ provider: "apple", sub: canonical }]);
  await env.STUDIQUO_DATA.put(`account:${canonical}`, "{}");
  await env.STUDIQUO_DATA.put("session:failure-token-49", JSON.stringify({ sub: canonical }));
  await env.STUDIQUO_DATA.put("snapshot:failure-token-49", JSON.stringify({ version: 1 }));
  const originalDelete = env.STUDIQUO_DATA.delete.bind(env.STUDIQUO_DATA);
  let failed = false;
  env.STUDIQUO_DATA.delete = async key => {
    if (key === "snapshot:failure-token-49" && !failed) {
      failed = true;
      throw new Error("injected KV failure");
    }
    return originalDelete(key);
  };

  await assert.rejects(deleteAccount(env, canonical), /injected KV failure/);
  assert.notEqual(await env.STUDIQUO_DATA.get("snapshot:failure-token-49"), null);
  await deleteAccount(env, canonical);
  assert.equal(await env.STUDIQUO_DATA.get("snapshot:failure-token-49"), null);
  const state = await env.STUDIQUO_DATA.get(`account-deletion:${hash(canonical)}`, "json");
  assert.ok(Number.isFinite(state.deletedAt) && state.deletedAt <= Date.now());
  assert.deepEqual(state, { status: "deleted", deletedAt: state.deletedAt, identityKeys: [canonical] });
});

test("50. Durable Objectの削除処理が途中で失敗しても再実行できる", async () => {
  const env = environment();
  const canonical = "account-do-retry-50";
  const chatKey = hash(`chat-account:${canonical}`);
  const roomID = "room-retry-50";
  await env.STUDIQUO_DATA.put(`chat:user:${chatKey}`, JSON.stringify({ code: "RETRY50", linkToken: "LINK50", groups: [{ roomID }] }));
  let attempts = 0;
  env.USER_REGISTRY = { getByName() { return { async resolveChatKey() { return chatKey; } }; } };
  env.CHAT_ROOM = { getByName() { return {
    async removeDeletedAccount() {
      attempts += 1;
      if (attempts === 1) throw new Error("injected Durable Object failure");
      return { status: "removed" };
    },
  }; } };

  await assert.rejects(deleteAccount(env, canonical), /injected Durable Object failure/);
  assert.notEqual(await env.STUDIQUO_DATA.get(`chat:user:${chatKey}`), null);
  await deleteAccount(env, canonical);
  assert.equal(attempts, 2);
  assert.equal(await env.STUDIQUO_DATA.get(`chat:user:${chatKey}`), null);
});

test("51. D1削除が失敗した場合に成功レスポンスを返さない", async () => {
  const env = environment();
  const canonical = "account-d1-failure-51";
  const token = `${Math.floor(Date.now() / 1000)}.${"d".repeat(40)}`;
  await env.STUDIQUO_DATA.put(`session:${hash(token)}`, JSON.stringify({ sub: canonical }));
  env.ADMIN_DB.prepare = () => ({ bind: () => ({ async run() { throw new Error("injected D1 failure"); } }) });

  const response = await worker.fetch(new Request("https://example.test/api/account", {
    method: "DELETE",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ confirmation: "DELETE" }),
  }), env, { waitUntil() {} });

  assert.notEqual(response.status, 200);
  assert.equal((await env.STUDIQUO_DATA.get(`account-deletion:${hash(canonical)}`, "json")).status, "deleting");
});

test("52. 同じ削除要求を2回送っても安全", async () => {
  const env = environment();
  const canonical = "account-idempotent-52";
  await seedLinked(env, canonical, "twice52@example.com", [{ provider: "apple", sub: canonical }]);
  await env.STUDIQUO_DATA.put(`account:${canonical}`, "{}");

  assert.deepEqual(await deleteAccount(env, canonical), { deleted: true });
  assert.deepEqual(await deleteAccount(env, canonical), { deleted: true });
  assert.equal(await env.STUDIQUO_DATA.get(`account:${canonical}`), null);
  const state = await env.STUDIQUO_DATA.get(`account-deletion:${hash(canonical)}`, "json");
  assert.ok(Number.isFinite(state.deletedAt) && state.deletedAt <= Date.now());
  assert.deepEqual(state, { status: "deleted", deletedAt: state.deletedAt, identityKeys: [canonical] });
});

test("53. 同時に2回削除してもデータが復活しない", async () => {
  const env = environment();
  const canonical = "account-concurrent-53";
  await seedLinked(env, canonical, "concurrent53@example.com", [{ provider: "apple", sub: canonical }]);
  await env.STUDIQUO_DATA.put(`account:${canonical}`, "{}");
  await env.STUDIQUO_DATA.put("session:concurrent-53", JSON.stringify({ sub: canonical }));
  await env.STUDIQUO_DATA.put("snapshot:concurrent-53", "{}");

  const results = await Promise.all([deleteAccount(env, canonical), deleteAccount(env, canonical)]);
  assert.deepEqual(results, [{ deleted: true }, { deleted: true }]);
  for (const key of [`account:${canonical}`, "session:concurrent-53", "snapshot:concurrent-53", "email-accounts:concurrent53@example.com"]) {
    assert.equal(await env.STUDIQUO_DATA.get(key), null, key);
  }
});

test("54. 大量のセッションやMCP接続があってもページネーション漏れがない", async () => {
  const env = environment();
  const canonical = "account-pages-54";
  const originalList = env.STUDIQUO_DATA.list.bind(env.STUDIQUO_DATA);
  void originalList;
  env.STUDIQUO_DATA.list = async ({ prefix = "", cursor } = {}) => {
    const keys = [...env._values.keys()].filter(key => key.startsWith(prefix)).sort();
    const start = cursor ? Number(cursor) : 0;
    const page = keys.slice(start, start + 17);
    const next = start + page.length;
    return {
      keys: page.map(name => ({ name })),
      list_complete: next >= keys.length,
      cursor: next < keys.length ? String(next) : undefined,
    };
  };
  for (let index = 0; index < 130; index += 1) {
    const sessionHash = `page-session-${String(index).padStart(3, "0")}`;
    await env.STUDIQUO_DATA.put(`session:${sessionHash}`, JSON.stringify({ sub: canonical }));
    await env.STUDIQUO_DATA.put(`snapshot:${sessionHash}`, "{}");
    await env.STUDIQUO_DATA.put(`mcp:access:${String(index).padStart(3, "0")}`, JSON.stringify({ sub: canonical, clientId: `client-${index}` }));
    await env.STUDIQUO_DATA.put(`mcp:grant:${hash(canonical)}:${String(index).padStart(3, "0")}`, "{}");
  }

  await deleteAccount(env, canonical);

  for (const prefix of ["session:page-session-", "snapshot:page-session-", "mcp:access:", `mcp:grant:${hash(canonical)}:`]) {
    assert.equal([...env._values.keys()].filter(key => key.startsWith(prefix)).length, 0, prefix);
  }
});

test("55. 削除途中のアカウントでログイン・書き込みできない", async () => {
  const env = environment();
  const canonical = "account-in-progress-55";
  const oldToken = `${Math.floor(Date.now() / 1000)}.${"o".repeat(40)}`;
  await env.STUDIQUO_DATA.put(`session:${hash(oldToken)}`, JSON.stringify({ sub: canonical }));
  let releaseD1;
  const d1Gate = new Promise(resolve => { releaseD1 = resolve; });
  let reachedD1;
  const reachedD1Promise = new Promise(resolve => { reachedD1 = resolve; });
  env.ADMIN_DB.prepare = () => ({ bind: () => ({ async all() { return { results: [] }; }, async run() { reachedD1(); await d1Gate; return { success: true }; } }) });
  const deletion = deleteAccount(env, canonical);
  await reachedD1Promise;

  assert.equal(await mintSession(env, canonical, "n".repeat(40)), null);
  const write = await worker.fetch(new Request("https://example.test/api/snapshot", {
    method: "PUT",
    headers: { authorization: `Bearer ${oldToken}`, "content-type": "application/json" },
    body: JSON.stringify({ version: 1 }),
  }), env, { waitUntil() {} });
  assert.equal(write.status, 401);
  releaseD1();
  await deletion;
});

test("56. タイムアウト後に再試行すると残りを削除できる", async () => {
  const env = environment();
  const canonical = "account-timeout-56";
  await seedLinked(env, canonical, "timeout56@example.com", [{ provider: "apple", sub: canonical }]);
  await env.STUDIQUO_DATA.put(`account:${canonical}`, "{}");
  await env.STUDIQUO_DATA.put("session:timeout-token-56", JSON.stringify({ sub: canonical }));
  await env.STUDIQUO_DATA.put("snapshot:timeout-token-56", "{}");
  const originalDelete = env.STUDIQUO_DATA.delete.bind(env.STUDIQUO_DATA);
  let timedOut = false;
  env.STUDIQUO_DATA.delete = async key => {
    if (key === "snapshot:timeout-token-56" && !timedOut) {
      timedOut = true;
      throw new Error("operation timed out");
    }
    return originalDelete(key);
  };

  await assert.rejects(deleteAccount(env, canonical), /timed out/);
  assert.equal((await env.STUDIQUO_DATA.get(`account-deletion:${hash(canonical)}`, "json")).status, "deleting");
  await deleteAccount(env, canonical);
  assert.equal(await env.STUDIQUO_DATA.get("snapshot:timeout-token-56"), null);
  assert.equal((await env.STUDIQUO_DATA.get(`account-deletion:${hash(canonical)}`, "json")).status, "deleted");
});

// A RATE_COUNTER double that records what happens to each named object, with
// the same contracts as the real one for the methods deletion uses.
function fakeRateCounter(env, { failPurgeOnce = false } = {}) {
  const generations = new Map();
  const purged = [];
  const retired = new Map();
  const log = [];
  let shouldFail = failPurgeOnce;
  return {
    purged, retired, generations, log,
    getByName(name) {
      return {
        ...accountGenerationMethods(name, generations, () => env.STUDIQUO_DATA),
        async retireAccountGeneration(ttlSeconds) {
          // Retired before the account's own keys are touched.
          log.push({ call: "retire", name, accountStillThere: (await env.STUDIQUO_DATA.get("account:local:local@example.com")) !== null });
          generations.set(name, (generations.get(name) ?? 0) + 1);
          retired.set(name, ttlSeconds);
        },
        async purgeAll() {
          log.push({ call: "purge", name, accountStillThere: (await env.STUDIQUO_DATA.get("account:local:local@example.com")) !== null });
          if (shouldFail) { shouldFail = false; throw new Error("DO down"); }
          purged.push(name);
        },
      };
    },
  };
}

const sha = value => createHash("sha256").update(value).digest("hex");

test("退会後に、進行中のパスワードハッシュのアップグレードがローカルアカウントを復活させない", async () => {
  const env = environment();
  env.RATE_COUNTER = fakeRateCounter(env);
  await seedLinked(env, "email:local@example.com", "local@example.com", [{ provider: "email", sub: "local@example.com" }]);
  await env.STUDIQUO_DATA.put("account:local:local@example.com", JSON.stringify({ gen: 3 }));
  const stub = env.RATE_COUNTER.getByName(`account-gen:${sha("local@example.com")}`);
  for (let i = 0; i < 3; i++) await stub.nextAccountGeneration();

  await deleteAccount(env, "email:local@example.com");
  assert.equal(await env.STUDIQUO_DATA.get("account:local:local@example.com"), null);

  // The login that started before the deletion now tries to land its upgrade.
  assert.equal(await stub.upgradeAccountIfCurrent("account:local:local@example.com", "{\"algo\":\"argon2id\"}", 3), false);
  assert.equal(await env.STUDIQUO_DATA.get("account:local:local@example.com"), null);
});

test("退会は、メールに紐づく国・失敗回数・通知枠・コード試行のDurable Objectを消し、世代は期限付きで残す", async () => {
  const env = environment();
  env.RATE_COUNTER = fakeRateCounter(env);
  await seedLinked(env, "email:local@example.com", "local@example.com", [{ provider: "email", sub: "local@example.com" }]);
  await env.STUDIQUO_DATA.put("account:local:local@example.com", "{}");

  await deleteAccount(env, "email:local@example.com");

  const hash = sha("local@example.com");
  for (const name of ["login-seen", "login-fail-account", "login-notice", "email-code-send", "email-code-confirm"]) {
    assert.ok(env.RATE_COUNTER.purged.includes(`${name}:${hash}`), `${name} should be purged`);
  }
  // The generation is retired with a bounded lifetime, never purged outright.
  assert.ok(!env.RATE_COUNTER.purged.includes(`account-gen:${hash}`));
  assert.equal(env.RATE_COUNTER.retired.get(`account-gen:${hash}`), 7 * 86_400);
  assert.ok(env.RATE_COUNTER.generations.get(`account-gen:${hash}`) >= 1);
  assert.ok(env.RATE_COUNTER.purged.every(name => name.endsWith(`:${hash}`)), "nothing belonging to anyone else");
});

test("退会は、連携した別のメールアドレス分のDurable Objectも消し、他人のものには触れない", async () => {
  const env = environment();
  env.RATE_COUNTER = fakeRateCounter(env);
  await seedLinked(env, "apple:a-1", "owner@example.com", [{ provider: "apple", sub: "a-1" }, { provider: "email", sub: "owner@example.com" }]);
  await env.STUDIQUO_DATA.put("account:local:owner@example.com", "{}");
  await seedLinked(env, "apple:b-1", "someone-else@example.com", [{ provider: "apple", sub: "b-1" }]);

  await deleteAccount(env, "apple:a-1");

  assert.ok(env.RATE_COUNTER.purged.includes(`login-seen:${sha("owner@example.com")}`));
  assert.ok(env.RATE_COUNTER.purged.every(name => !name.endsWith(sha("someone-else@example.com"))));
});

test("退会の再実行でも、同じ後始末が冪等に完了する", async () => {
  const env = environment();
  env.RATE_COUNTER = fakeRateCounter(env);
  await seedLinked(env, "email:local@example.com", "local@example.com", [{ provider: "email", sub: "local@example.com" }]);
  await env.STUDIQUO_DATA.put("account:local:local@example.com", "{}");
  await deleteAccount(env, "email:local@example.com");
  await deleteAccount(env, "email:local@example.com");
  assert.equal(await env.STUDIQUO_DATA.get("account:local:local@example.com"), null);
});

test("退会は、RATE_COUNTERが無い環境でもローカルアカウントを削除できる", async () => {
  const env = environment();
  await seedLinked(env, "email:local@example.com", "local@example.com", [{ provider: "email", sub: "local@example.com" }]);
  await env.STUDIQUO_DATA.put("account:local:local@example.com", "{}");
  await deleteAccount(env, "email:local@example.com");
  assert.equal(await env.STUDIQUO_DATA.get("account:local:local@example.com"), null);
});

test("退会は、世代の退役を先に、残りのDO削除を本体の削除の後に行う", async () => {
  const env = environment();
  env.RATE_COUNTER = fakeRateCounter(env);
  await seedLinked(env, "email:local@example.com", "local@example.com", [{ provider: "email", sub: "local@example.com" }]);
  await env.STUDIQUO_DATA.put("account:local:local@example.com", "{}");

  await deleteAccount(env, "email:local@example.com");

  const retire = env.RATE_COUNTER.log.filter(entry => entry.call === "retire");
  const purge = env.RATE_COUNTER.log.filter(entry => entry.call === "purge");
  assert.ok(retire.length > 0 && purge.length > 0);
  assert.ok(retire.every(entry => entry.accountStillThere), "generation retired while the account still exists");
  assert.ok(purge.every(entry => !entry.accountStillThere), "the rest only after the account is gone");
});

test("退会の途中でDO削除が失敗しても、本体は消え、再実行で残りが完了する", async () => {
  const env = environment();
  env.RATE_COUNTER = fakeRateCounter(env, { failPurgeOnce: true });
  await seedLinked(env, "email:local@example.com", "local@example.com", [{ provider: "email", sub: "local@example.com" }]);
  await env.STUDIQUO_DATA.put("account:local:local@example.com", "{}");
  await env.STUDIQUO_DATA.put("email-verify:local@example.com", "{}");

  await assert.rejects(() => deleteAccount(env, "email:local@example.com"), /DO down/);
  // The account itself is already gone, not held up behind the failure.
  assert.equal(await env.STUDIQUO_DATA.get("account:local:local@example.com"), null);
  assert.equal(await env.STUDIQUO_DATA.get("email-verify:local@example.com"), null);
  assert.ok(await env.STUDIQUO_DATA.get(`privacy-account-delete:${sha("email:local@example.com")}`) !== null, "the job is still pending, so it will be retried");

  await deleteAccount(env, "email:local@example.com");
  const hash = sha("local@example.com");
  for (const name of ["login-seen", "login-fail-account", "login-notice", "email-code-send", "email-code-confirm"]) {
    assert.ok(env.RATE_COUNTER.purged.includes(`${name}:${hash}`), name);
  }
  assert.equal(await env.STUDIQUO_DATA.get(`privacy-account-delete:${sha("email:local@example.com")}`), null);
});

test("退会は、大文字小文字の違うメールアドレスでも、同じ小文字ハッシュのDOを対象にする", async () => {
  const env = environment();
  env.RATE_COUNTER = fakeRateCounter(env);
  await seedLinked(env, "email:mixed@example.com", "mixed@example.com", [{ provider: "email", sub: "Mixed@Example.com" }]);
  await env.STUDIQUO_DATA.put("account:local:Mixed@Example.com", "{}");

  await deleteAccount(env, "email:mixed@example.com");

  assert.ok(env.RATE_COUNTER.purged.includes(`login-seen:${sha("mixed@example.com")}`));
  assert.ok(!env.RATE_COUNTER.purged.some(name => name.endsWith(sha("Mixed@Example.com"))));
});
