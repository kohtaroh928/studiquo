import assert from "node:assert/strict";
import { generateKeyPair, exportPKCS8, jwtVerify } from "jose";
import test from "node:test";
import { sendPush } from "./push.js";

async function fixture() {
  const values = new Map();
  const { privateKey, publicKey } = await generateKeyPair("ES256", { extractable: true });
  const env = {
    APNS_AUTH_KEY: await exportPKCS8(privateKey),
    APNS_KEY_ID: "KEY1234567",
    APNS_TEAM_ID: "TEAM123456",
    APNS_TOPIC: "com.yabuko.studiquo",
    STUDIQUO_DATA: {
      async get(key, type) {
        const value = values.get(key) ?? null;
        return type === "json" && value ? JSON.parse(value) : value;
      },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
    },
  };
  return { env, values, publicKey };
}

function seedDevices(values, devices) {
  values.set("chat:devices:user-a", JSON.stringify(devices));
}

const sandboxToken = "a".repeat(64);
const productionToken = "b".repeat(64);
const notification = {
  category: "friendMessage",
  title: "New message",
  body: "A friend sent you a message.",
  badge: 2,
  data: { roomID: "room-1" },
};

test("sandbox devices use the sandbox APNs endpoint", async () => {
  const { env, values } = await fixture();
  seedDevices(values, [{ token: sandboxToken, environment: "sandbox", updatedAt: 1 }]);
  const urls = [];
  await sendPush(env, "user-a", notification, {
    fetchImpl: async url => { urls.push(url); return new Response(null, { status: 200 }); },
  });
  assert.match(urls[0], /^https:\/\/api\.sandbox\.push\.apple\.com\/3\/device\//);
});

test("production devices use the production APNs endpoint", async () => {
  const { env, values } = await fixture();
  seedDevices(values, [{ token: productionToken, environment: "production", updatedAt: 1 }]);
  const urls = [];
  await sendPush(env, "user-a", notification, {
    fetchImpl: async url => { urls.push(url); return new Response(null, { status: 200 }); },
  });
  assert.match(urls[0], /^https:\/\/api\.push\.apple\.com\/3\/device\//);
  assert.doesNotMatch(urls[0], /sandbox/);
});

test("one JWT is reused for every device in a multi-device send", async () => {
  const { env, values } = await fixture();
  seedDevices(values, [
    { token: sandboxToken, environment: "sandbox", updatedAt: 1 },
    { token: productionToken, environment: "production", updatedAt: 2 },
  ]);
  const authorizationHeaders = [];
  await sendPush(env, "user-a", notification, {
    fetchImpl: async (_url, init) => {
      authorizationHeaders.push(init.headers.authorization);
      return new Response(null, { status: 200 });
    },
  });
  assert.equal(authorizationHeaders.length, 2);
  assert.equal(authorizationHeaders[0], authorizationHeaders[1]);
});

test("sandbox and production devices use their environment-specific signing keys", async () => {
  const { env, values } = await fixture();
  const sandboxPair = await generateKeyPair("ES256", { extractable: true });
  const productionPair = await generateKeyPair("ES256", { extractable: true });
  delete env.APNS_AUTH_KEY;
  delete env.APNS_KEY_ID;
  env.APNS_SANDBOX_AUTH_KEY = await exportPKCS8(sandboxPair.privateKey);
  env.APNS_SANDBOX_KEY_ID = "SANDBOX001";
  env.APNS_PRODUCTION_AUTH_KEY = await exportPKCS8(productionPair.privateKey);
  env.APNS_PRODUCTION_KEY_ID = "PRODUCT001";
  seedDevices(values, [
    { token: sandboxToken, environment: "sandbox", updatedAt: 1 },
    { token: productionToken, environment: "production", updatedAt: 2 },
  ]);
  const authorizations = new Map();
  await sendPush(env, "user-a", notification, {
    fetchImpl: async (url, init) => {
      authorizations.set(url.includes("sandbox") ? "sandbox" : "production", init.headers.authorization.replace("bearer ", ""));
      return new Response(null, { status: 200 });
    },
  });

  const sandboxJWT = await jwtVerify(authorizations.get("sandbox"), sandboxPair.publicKey, { issuer: env.APNS_TEAM_ID });
  const productionJWT = await jwtVerify(authorizations.get("production"), productionPair.publicKey, { issuer: env.APNS_TEAM_ID });
  assert.equal(sandboxJWT.protectedHeader.kid, "SANDBOX001");
  assert.equal(productionJWT.protectedHeader.kid, "PRODUCT001");
});

test("the APNs JWT uses ES256 and contains the configured Team ID", async () => {
  const { env, values, publicKey } = await fixture();
  seedDevices(values, [{ token: sandboxToken, environment: "sandbox", updatedAt: 1 }]);
  let authorization;
  await sendPush(env, "user-a", notification, {
    now: 1_800_000_000_000,
    fetchImpl: async (_url, init) => {
      authorization = init.headers.authorization;
      return new Response(null, { status: 200 });
    },
  });
  const verified = await jwtVerify(authorization.replace("bearer ", ""), publicKey, {
    issuer: env.APNS_TEAM_ID,
  });
  assert.equal(verified.protectedHeader.alg, "ES256");
  assert.equal(verified.payload.iss, env.APNS_TEAM_ID);
});

test("the APNs payload includes badge and deep-link data", async () => {
  const { env, values } = await fixture();
  seedDevices(values, [{ token: sandboxToken, environment: "sandbox", updatedAt: 1 }]);
  let payload;
  await sendPush(env, "user-a", notification, {
    fetchImpl: async (_url, init) => {
      payload = JSON.parse(init.body);
      return new Response(null, { status: 200 });
    },
  });
  assert.equal(payload.aps.badge, 2);
  assert.equal(payload.aps.category, "studiquo.friendMessage");
  assert.equal(payload.roomID, "room-1");
});

test("a disabled category is filtered per device without affecting enabled devices", async () => {
  const { env, values } = await fixture();
  seedDevices(values, [
    { token: sandboxToken, environment: "sandbox", preferences: { friendMessage: false }, updatedAt: 1 },
    { token: productionToken, environment: "production", preferences: { friendMessage: true }, updatedAt: 2 },
  ]);
  const deliveredTokens = [];
  const result = await sendPush(env, "user-a", notification, {
    fetchImpl: async url => {
      deliveredTokens.push(url.split("/").at(-1));
      return new Response(null, { status: 200 });
    },
  });
  assert.deepEqual(deliveredTokens, [productionToken]);
  assert.equal(result.length, 1);
});

test("new-device alerts can exclude the installation that just registered", async () => {
  const { env, values } = await fixture();
  seedDevices(values, [
    { token: sandboxToken, environment: "sandbox", installationID: "old-installation", updatedAt: 1 },
    { token: productionToken, environment: "production", installationID: "new-installation", updatedAt: 2 },
  ]);
  const deliveredTokens = [];
  await sendPush(env, "user-a", { ...notification, category: "newDeviceLogin" }, {
    excludeInstallationID: "new-installation",
    fetchImpl: async url => {
      deliveredTokens.push(url.split("/").at(-1));
      return new Response(null, { status: 200 });
    },
  });
  assert.deepEqual(deliveredTokens, [sandboxToken]);
});

test("an invalid device does not prevent delivery to another device", async () => {
  const { env, values } = await fixture();
  seedDevices(values, [
    { token: sandboxToken, environment: "sandbox", updatedAt: 1 },
    { token: productionToken, environment: "production", updatedAt: 2 },
  ]);
  const result = await sendPush(env, "user-a", notification, {
    fetchImpl: async url => url.includes(sandboxToken)
      ? Response.json({ reason: "Unregistered" }, { status: 410 })
      : new Response(null, { status: 200 }),
  });
  assert.equal(result.find(item => item.token === sandboxToken).delivered, false);
  assert.equal(result.find(item => item.token === productionToken).delivered, true);
});

test("APNs 410 Unregistered removes the device token from KV", async () => {
  const { env, values } = await fixture();
  seedDevices(values, [{ token: sandboxToken, environment: "sandbox", updatedAt: 1 }]);
  values.set(`chat:device-owner:${sandboxToken}`, "user-a");
  await sendPush(env, "user-a", notification, {
    fetchImpl: async () => Response.json({ reason: "Unregistered" }, { status: 410 }),
  });
  assert.equal(values.has("chat:devices:user-a"), false);
});

test("removing an invalid device also removes its owner mapping", async () => {
  const { env, values } = await fixture();
  seedDevices(values, [{ token: sandboxToken, environment: "sandbox", updatedAt: 1 }]);
  values.set(`chat:device-owner:${sandboxToken}`, "user-a");
  await sendPush(env, "user-a", notification, {
    fetchImpl: async () => Response.json({ reason: "Unregistered" }, { status: 410 }),
  });
  assert.equal(values.has(`chat:device-owner:${sandboxToken}`), false);
});
