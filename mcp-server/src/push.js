import { SignJWT, importPKCS8 } from "jose";
import { loadDevices, removeDevice } from "./devices.js";

const INVALID_TOKEN_REASONS = new Set(["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"]);

function apnsHost(environment) {
  return environment === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
}

function apnsCredentials(env, environment) {
  const sandbox = environment === "sandbox";
  return {
    authKey: (sandbox ? env.APNS_SANDBOX_AUTH_KEY : env.APNS_PRODUCTION_AUTH_KEY) ?? env.APNS_AUTH_KEY,
    keyID: (sandbox ? env.APNS_SANDBOX_KEY_ID : env.APNS_PRODUCTION_KEY_ID) ?? env.APNS_KEY_ID,
  };
}

export async function createAPNsJWT(env, now = Date.now(), environment = "production") {
  const credentials = apnsCredentials(env, environment);
  const key = await importPKCS8(credentials.authKey, "ES256");
  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: credentials.keyID })
    .setIssuer(env.APNS_TEAM_ID)
    .setIssuedAt(Math.floor(now / 1_000))
    .sign(key);
}

async function apnsErrorReason(response) {
  try {
    const payload = await response.json();
    return typeof payload?.reason === "string" ? payload.reason : null;
  } catch {
    return null;
  }
}

/**
 * Best-effort push delivery. It deliberately returns per-device results and
 * never throws into the chat/friend action that triggered it.
 */
export async function sendPush(env, userKey, notification, options = {}) {
  const fetchImpl = options.fetchImpl ?? fetch;
  const now = options.now ?? Date.now();
  if (!env.APNS_TEAM_ID || !env.APNS_TOPIC) {
    console.error(JSON.stringify({ event: "apns_configuration_missing" }));
    return [];
  }

  const devices = (options.devices ?? await loadDevices(env, userKey)).filter(device => {
    if (options.excludeInstallationID && device.installationID === options.excludeInstallationID) return false;
    const category = notification.category;
    return !category || device.preferences?.[category] !== false;
  });
  if (devices.length === 0) return [];

  // A modern APNs key is scoped to either Sandbox or Production. Cache one
  // signing operation per actual key so mixed device lists use the correct
  // credential, while a legacy all-environments key is still signed once.
  const jwtByCredential = new Map();
  const jwtFor = async environment => {
    const credentials = apnsCredentials(env, environment);
    if (!credentials.authKey || !credentials.keyID) return null;
    const cacheKey = `${credentials.keyID}\u0000${credentials.authKey}`;
    if (!jwtByCredential.has(cacheKey)) {
      jwtByCredential.set(cacheKey, createAPNsJWT(env, now, environment));
    }
    return jwtByCredential.get(cacheKey);
  };

  const aps = {
    alert: { title: String(notification.title ?? ""), body: String(notification.body ?? "") },
    sound: "default",
    ...(notification.category ? { category: `studiquo.${notification.category}` } : {}),
    ...(notification.threadID ? { "thread-id": String(notification.threadID) } : {}),
    ...(Number.isSafeInteger(notification.badge) ? { badge: notification.badge } : {}),
  };
  const customData = notification.data && typeof notification.data === "object" && !Array.isArray(notification.data)
    ? { ...notification.data }
    : {};
  delete customData.aps;
  const payload = JSON.stringify({ ...customData, aps });
  if (new TextEncoder().encode(payload).byteLength > 4_096) {
    console.error(JSON.stringify({ event: "apns_payload_too_large" }));
    return devices.map(device => ({ token: device.token, delivered: false }));
  }

  return Promise.all(devices.map(async device => {
    try {
      const jwt = await jwtFor(device.environment);
      if (!jwt) {
        console.error(JSON.stringify({ event: "apns_configuration_missing", environment: device.environment }));
        return { token: device.token, delivered: false, reason: "MissingConfiguration" };
      }
      const response = await fetchImpl(`https://${apnsHost(device.environment)}/3/device/${device.token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": env.APNS_TOPIC,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "apns-expiration": String(Math.floor(now / 1_000) + 3_600),
          "content-type": "application/json",
        },
        body: payload,
      });
      if (response.ok) return { token: device.token, delivered: true };
      const reason = await apnsErrorReason(response);
      if (response.status === 410 || (response.status === 400 && INVALID_TOKEN_REASONS.has(reason))) {
        await removeDevice(env, userKey, device.token);
      }
      console.error(JSON.stringify({ event: "apns_delivery_failed", status: response.status, reason }));
      return { token: device.token, delivered: false, status: response.status, reason };
    } catch (error) {
      console.error(JSON.stringify({ event: "apns_request_failed", environment: device.environment, error: String(error) }));
      return { token: device.token, delivered: false };
    }
  }));
}
