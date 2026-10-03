import assert from "node:assert/strict";
import { exportPKCS8, generateKeyPair } from "jose";
import test from "node:test";
import { handleDeviceRoutes, loadDevices } from "./devices.js";

function environment(limit = 5) {
  const values = new Map();
  let count = 0;
  return {
    STUDIQUO_DATA: {
      async get(key, type) {
        const value = values.get(key) ?? null;
        return type === "json" && value ? JSON.parse(value) : value;
      },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
    },
    RATE_LIMIT_CHAT_DEVICE_REGISTER: {
      async limit() { count += 1; return { success: count <= limit }; },
    },
  };
}

function request(method, body) {
  return new Request("https://example.test/api/chat/devices", {
    method,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

const firstToken = "a".repeat(64);
const secondToken = "b".repeat(64);

test("device registration is idempotent and keeps multiple devices", async () => {
  const env = environment();
  const url = new URL("https://example.test/api/chat/devices");
  assert.equal((await handleDeviceRoutes(url, request("POST", { deviceToken: firstToken, environment: "sandbox" }), env, "user-a")).status, 200);
  assert.equal((await handleDeviceRoutes(url, request("POST", { deviceToken: firstToken.toUpperCase(), environment: "production" }), env, "user-a")).status, 200);
  assert.equal((await handleDeviceRoutes(url, request("POST", { deviceToken: secondToken, environment: "production" }), env, "user-a")).status, 200);

  const devices = await loadDevices(env, "user-a");
  assert.equal(devices.length, 2);
  assert.equal(devices.find(device => device.token === firstToken).environment, "production");
});

test("device registration stores installation metadata and category preferences", async () => {
  const env = environment();
  const url = new URL("https://example.test/api/chat/devices");
  await handleDeviceRoutes(url, request("POST", {
    deviceToken: firstToken,
    environment: "sandbox",
    installationID: "installation-a",
    deviceName: "Study iPad",
    preferences: { friendMessage: false, groupInvite: true, unknownCategory: false },
  }), env, "user-a");

  const [device] = await loadDevices(env, "user-a");
  assert.equal(device.installationID, "installation-a");
  assert.equal(device.deviceName, "Study iPad");
  assert.deepEqual(device.preferences, { friendMessage: false, groupInvite: true });
});

test("registering a genuinely new installation alerts the account's existing device only", async () => {
  const env = environment();
  const { privateKey } = await generateKeyPair("ES256", { extractable: true });
  Object.assign(env, {
    APNS_AUTH_KEY: await exportPKCS8(privateKey),
    APNS_KEY_ID: "KEY1234567",
    APNS_TEAM_ID: "TEAM123456",
    APNS_TOPIC: "com.yabuko.studiquo",
  });
  const url = new URL("https://example.test/api/chat/devices");
  await handleDeviceRoutes(url, request("POST", {
    deviceToken: firstToken,
    environment: "sandbox",
    installationID: "installation-a",
    deviceName: "Old iPad",
  }), env, "user-a");

  const originalFetch = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (requestURL, init) => {
    calls.push({ requestURL, payload: JSON.parse(init.body) });
    return new Response(null, { status: 200 });
  };
  try {
    await handleDeviceRoutes(url, request("POST", {
      deviceToken: secondToken,
      environment: "production",
      installationID: "installation-b",
      deviceName: "New iPhone",
    }), env, "user-a");
  } finally {
    globalThis.fetch = originalFetch;
  }

  assert.equal(calls.length, 1);
  assert.match(calls[0].requestURL, new RegExp(`${firstToken}$`));
  assert.equal(calls[0].payload.aps.category, "studiquo.newDeviceLogin");
  assert.equal(calls[0].payload.route, "newDeviceLogin");
});

test("registering the same installation for another account transfers ownership", async () => {
  const env = environment();
  const url = new URL("https://example.test/api/chat/devices");
  await handleDeviceRoutes(url, request("POST", { deviceToken: firstToken, environment: "sandbox" }), env, "user-a");
  await handleDeviceRoutes(url, request("POST", { deviceToken: firstToken, environment: "sandbox" }), env, "user-b");

  assert.deepEqual(await loadDevices(env, "user-a"), []);
  assert.equal((await loadDevices(env, "user-b")).length, 1);
});

test("device unregister is idempotent", async () => {
  const env = environment();
  const url = new URL("https://example.test/api/chat/devices");
  await handleDeviceRoutes(url, request("POST", { deviceToken: firstToken, environment: "sandbox" }), env, "user-a");
  assert.equal((await handleDeviceRoutes(url, request("DELETE", { deviceToken: firstToken }), env, "user-a")).status, 200);
  assert.equal((await handleDeviceRoutes(url, request("DELETE", { deviceToken: firstToken }), env, "user-a")).status, 200);
  assert.deepEqual(await loadDevices(env, "user-a"), []);
});

test("device registration validates tokens, environments, and rate limits", async () => {
  const env = environment(2);
  const url = new URL("https://example.test/api/chat/devices");
  assert.equal((await handleDeviceRoutes(url, request("POST", { deviceToken: "not-a-token", environment: "sandbox" }), env, "user-a")).status, 400);
  assert.equal((await handleDeviceRoutes(url, request("POST", { deviceToken: firstToken, environment: "preview" }), env, "user-a")).status, 400);
  assert.equal((await handleDeviceRoutes(url, request("POST", { deviceToken: firstToken, environment: "sandbox" }), env, "user-a")).status, 429);
});

test("device registration keeps a valid language and the announcement preference", async () => {
  const env = environment();
  const url = new URL("https://example.test/api/chat/devices");
  await handleDeviceRoutes(url, request("POST", {
    deviceToken: firstToken, environment: "production", language: "zh-Hans", preferences: { announcement: false },
  }), env, "user-a");
  // A later registration without a language (older app) keeps the stored one;
  // a malformed one is ignored rather than rejected.
  await handleDeviceRoutes(url, request("POST", { deviceToken: firstToken, environment: "production" }), env, "user-a");
  await handleDeviceRoutes(url, request("POST", { deviceToken: secondToken, environment: "production", language: "not a code" }), env, "user-a");

  const devices = await loadDevices(env, "user-a");
  const first = devices.find(device => device.token === firstToken);
  assert.equal(first.language, "zh-Hans");
  assert.equal(first.preferences.announcement, false);
  assert.equal(devices.find(device => device.token === secondToken).language, undefined);
});
