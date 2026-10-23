import assert from "node:assert/strict";
import { generateKeyPair, exportPKCS8, jwtVerify } from "jose";
import test from "node:test";
import { sendPush } from "./push.ts";
import { partialEnv, type Untyped } from "./test-env.ts";

async function fixture() {
  const values = new Map();
  const { privateKey, publicKey } = await generateKeyPair("ES256", { extractable: true });
  const env = partialEnv({
    APNS_AUTH_KEY: await exportPKCS8(privateKey),
    APNS_KEY_ID: "KEY1234567",
    APNS_TEAM_ID: "TEAM123456",
    APNS_TOPIC: "com.yabuko.studiquo",
    STUDIQUO_DATA: {
      async get(key: string, type: string) {
        const value = values.get(key) ?? null;
        return type === "json" && value ? JSON.parse(value) : value;
      },
      async put(key: string, value: string) { values.set(key, value); },
      async delete(key: string) { values.delete(key); },
    },
  });
  return { env, values, publicKey };
}

function seedDevices(values: Map<any,any>, devices: unknown[]) {
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
  const urls: Untyped[] = [];
  await sendPush(env, "user-a", notification, {
    fetchImpl: async (url: unknown) => { urls.push(url); return new Response(null, { status: 200 }); },
  });
  assert.match(urls[0], /^https:\/\/api\.sandbox\.push\.apple\.com\/3\/device\//);
});

test("production devices use the production APNs endpoint", async () => {
  const { env, values } = await fixture();
  seedDevices(values, [{ token: productionToken, environment: "production", updatedAt: 1 }]);
  const urls: Untyped[] = [];
  await sendPush(env, "user-a", notification, {
    fetchImpl: async (url: unknown) => { urls.push(url); return new Response(null, { status: 200 }); },
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
  const authorizationHeaders: any[] = [];
  await sendPush(env, "user-a", notification, {
    fetchImpl: async (_url: unknown, init?: Untyped) => {
      authorizationHeaders.push((init!.headers as Record<string, string>).authorization);
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
    fetchImpl: async (url: Untyped, init?: Untyped) => {
      authorizations.set(url.includes("sandbox") ? "sandbox" : "production", (init!.headers as Record<string, string>).authorization.replace("bearer ", ""));
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
    fetchImpl: async (_url: unknown, init?: Untyped) => {
      authorization = (init!.headers as Record<string, string>).authorization;
      return new Response(null, { status: 200 });
    },
  });
  const verified = await jwtVerify(authorization!.replace("bearer ", ""), publicKey, {
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
    fetchImpl: async (_url: unknown, init?: Untyped) => {
      payload = JSON.parse(init!.body! as string);
      return new Response(null, { status: 200 });
    },
  });
  assert.equal(payload!.aps.badge, 2);
  assert.equal(payload!.aps.category, "studiquo.friendMessage");
  assert.equal(payload!.roomID, "room-1");
});

test("a disabled category is filtered per device without affecting enabled devices", async () => {
  const { env, values } = await fixture();
  seedDevices(values, [
    { token: sandboxToken, environment: "sandbox", preferences: { friendMessage: false }, updatedAt: 1 },
    { token: productionToken, environment: "production", preferences: { friendMessage: true }, updatedAt: 2 },
  ]);
  const deliveredTokens: unknown[] = [];
  const result = await sendPush(env, "user-a", notification, {
    fetchImpl: async (url: Untyped) => {
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
  const deliveredTokens: unknown[] = [];
  await sendPush(env, "user-a", { ...notification, category: "newDeviceLogin" }, {
    excludeInstallationID: "new-installation",
    fetchImpl: async (url: Untyped) => {
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
    fetchImpl: async (url: Untyped) => url.includes(sandboxToken)
      ? Response.json({ reason: "Unregistered" }, { status: 410 })
      : new Response(null, { status: 200 }),
  });
  assert.equal(result.find(item => item.token === sandboxToken)!.delivered, false);
  assert.equal(result.find(item => item.token === productionToken)!.delivered, true);
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

test("a device that turned the banner off gets a quiet (passive, soundless) notification", async () => {
  const { env, values } = await fixture();
  seedDevices(values, [
    { token: sandboxToken, environment: "sandbox", updatedAt: 1, banners: { friendMessage: false } },
    { token: productionToken, environment: "production", updatedAt: 1 },
  ]);
  const sent: { token: any; headers: HeadersInit; aps: any; }[] = [];
  await sendPush(env, "user-a", notification, {
    fetchImpl: async (url: Untyped, init?: Untyped) => {
      sent.push({ token: url.split("/").pop(), headers: init!.headers as Record<string, string>, aps: JSON.parse(init!.body! as string).aps });
      return new Response(null, { status: 200 });
    },
  });
  const quiet = sent.find(item => item.token === sandboxToken);
  const loud = sent.find(item => item.token === productionToken);
  assert.equal(quiet!.aps["interruption-level"], "passive");
  assert.equal(quiet!.aps.sound, undefined, "静かな通知に音を付けてはいけません。");
  assert.equal((quiet!.headers as Record<string, string>)["apns-priority"], "5");
  assert.equal(quiet!.aps.alert.title, "New message", "本文は同じで、見せ方だけが静かになります。");
  assert.equal(quiet!.aps.category, "studiquo.friendMessage");
  assert.equal(loud!.aps.sound, "default");
  assert.equal(loud!.aps["interruption-level"], undefined);
  assert.equal((loud!.headers as Record<string, string>)["apns-priority"], "10");
});

test("turning the banner off for one category does not quiet the others", async () => {
  const { env, values } = await fixture();
  seedDevices(values, [{ token: sandboxToken, environment: "sandbox", updatedAt: 1, banners: { groupInvite: false } }]);
  let aps;
  await sendPush(env, "user-a", notification, {
    fetchImpl: async (url: unknown, init?: Untyped) => { aps = JSON.parse(init!.body! as string).aps; return new Response(null, { status: 200 }); },
  });
  assert.equal(aps!.sound, "default");
  assert.equal(aps!["interruption-level"], undefined);
});

// ---- Failure paths: what is kept, what is dropped, and that nothing throws ----

const quietly = async <T>(run: () => Promise<T>) => {
  const real = console.error;
  console.error = () => {};
  try { return await run(); } finally { console.error = real; }
};

test("an APNs 400 naming a bad token drops the device; a 400 for another reason, 429 or 500 keeps it", async () => {
  for (const [status, reason, dropped] of [
    [400, "BadDeviceToken", true], [400, "DeviceTokenNotForTopic", true],
    [400, "PayloadTooLarge", false], [429, "TooManyRequests", false], [500, "InternalServerError", false],
  ] as const) {
    const { env, values } = await fixture();
    seedDevices(values, [{ token: sandboxToken, environment: "sandbox", updatedAt: 1 }]);
    const [result] = await quietly<Untyped[]>(() => sendPush(env, "user-a", notification, {
      fetchImpl: async () => Response.json({ reason }, { status }),
    }));
    assert.deepEqual([result.delivered, result.status, result.reason], [false, status, reason]);
    assert.equal(values.has("chat:devices:user-a"), !dropped, `${status} ${reason}`);
  }
});

test("an APNs error with no readable body is a failed delivery with no reason, and keeps the device", async () => {
  for (const body of ["<html>bad gateway</html>", "", "null", "[]"]) {
    const { env, values } = await fixture();
    seedDevices(values, [{ token: sandboxToken, environment: "sandbox", updatedAt: 1 }]);
    const [result] = await quietly<Untyped[]>(() => sendPush(env, "user-a", notification, {
      fetchImpl: async () => new Response(body, { status: 502 }),
    }));
    assert.deepEqual([result.delivered, result.status, result.reason], [false, 502, null], JSON.stringify(body));
    assert.equal(values.has("chat:devices:user-a"), true);
  }
});

test("a 410 without a reason still drops the device", async () => {
  const { env, values } = await fixture();
  seedDevices(values, [{ token: sandboxToken, environment: "sandbox", updatedAt: 1 }]);
  await quietly(() => sendPush(env, "user-a", notification, { fetchImpl: async () => new Response("", { status: 410 }) }));
  assert.equal(values.has("chat:devices:user-a"), false);
});

test("a network failure for one device doesn't throw and doesn't stop the others", async () => {
  const { env, values } = await fixture();
  seedDevices(values, [
    { token: sandboxToken, environment: "sandbox", updatedAt: 1 },
    { token: productionToken, environment: "production", updatedAt: 2 },
  ]);
  const results = await quietly(() => sendPush(env, "user-a", notification, {
    fetchImpl: async (url: unknown) => {
      if (String(url).includes(sandboxToken)) throw new Error("connection reset");
      return new Response(null, { status: 200 });
    },
  }));
  assert.equal(results.find(item => item.token === sandboxToken)!.delivered, false);
  assert.equal(results.find(item => item.token === productionToken)!.delivered, true);
  assert.equal(values.has("chat:devices:user-a"), true, "a network failure doesn't remove a device");
});

test("a notification too large for APNs is not sent to anyone, and every device is reported undelivered", async () => {
  const { env, values } = await fixture();
  seedDevices(values, [
    { token: sandboxToken, environment: "sandbox", updatedAt: 1 },
    { token: productionToken, environment: "production", updatedAt: 2 },
  ]);
  let calls = 0;
  const results = await quietly(() => sendPush(env, "user-a", { ...notification, body: "あ".repeat(2_000) }, {
    fetchImpl: async () => { calls++; return new Response(null, { status: 200 }); },
  }));
  assert.equal(calls, 0);
  assert.deepEqual(results.map(item => item.delivered), [false, false]);
});

test("a device whose environment has no signing key is reported as missing configuration and nothing is sent for it", async () => {
  const { env, values } = await fixture();
  const sandboxOnly = partialEnv({ ...env, APNS_AUTH_KEY: undefined, APNS_KEY_ID: undefined, APNS_SANDBOX_AUTH_KEY: env.APNS_AUTH_KEY, APNS_SANDBOX_KEY_ID: "SANDBOXKEY1" });
  seedDevices(values, [
    { token: sandboxToken, environment: "sandbox", updatedAt: 1 },
    { token: productionToken, environment: "production", updatedAt: 2 },
  ]);
  const urls: string[] = [];
  const results = await quietly(() => sendPush(sandboxOnly, "user-a", notification, {
    fetchImpl: async (url: unknown) => { urls.push(String(url)); return new Response(null, { status: 200 }); },
  }));
  assert.equal(urls.length, 1);
  assert.match(urls[0], /sandbox/);
  assert.deepEqual(results.find(item => item.token === productionToken), { token: productionToken, delivered: false, reason: "MissingConfiguration" });
  assert.equal(results.find(item => item.token === sandboxToken)!.delivered, true);
});

test("nothing is sent, and nothing throws, without a team id or topic, with no devices, or with the push switch off", async () => {
  const sentTo = async (changes: Record<string, unknown>, devices: unknown[] = [{ token: sandboxToken, environment: "sandbox", updatedAt: 1 }]) => {
    const { env, values } = await fixture();
    seedDevices(values, devices);
    let calls = 0;
    const result = await quietly(() => sendPush(partialEnv({ ...env, ...changes }), "user-a", notification, {
      fetchImpl: async () => { calls++; return new Response(null, { status: 200 }); },
    }));
    return { calls, result };
  };
  assert.deepEqual(await sentTo({ APNS_TEAM_ID: undefined }), { calls: 0, result: [] });
  assert.deepEqual(await sentTo({ APNS_TOPIC: undefined }), { calls: 0, result: [] });
  assert.deepEqual(await sentTo({}, []), { calls: 0, result: [] });
  assert.deepEqual(await sentTo({ DISABLED_FEATURES: "push" }), { calls: 0, result: [] });
});

test("the payload keeps the app's own data but never lets it set aps, and ignores data that isn't an object", async () => {
  const bodies: Untyped[] = [];
  const send = async (data: unknown) => {
    const { env, values } = await fixture();
    seedDevices(values, [{ token: sandboxToken, environment: "sandbox", updatedAt: 1 }]);
    await sendPush(env, "user-a", { ...notification, data: data as Record<string, unknown> }, {
      fetchImpl: async (_url: unknown, init?: Untyped) => { bodies.push(JSON.parse(init.body)); return new Response(null, { status: 200 }); },
    });
  };
  await send({ roomID: "room-1", aps: { alert: "forged", "content-available": 1 } });
  await send(["not", "an", "object"]);
  await send(null);
  assert.equal(bodies[0].roomID, "room-1");
  assert.equal(bodies[0].aps.alert.title, "New message", "the app's own aps is dropped");
  assert.equal(bodies[0].aps["content-available"], undefined);
  for (const body of bodies.slice(1)) assert.deepEqual(Object.keys(body), ["aps"]);
});
