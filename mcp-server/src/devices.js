import { checkRateLimit } from "./rate-limit.js";
import { json, readJSONLimited } from "./http.js";
import { sendPush } from "./push.js";

const MAX_BODY = 2_000;
const MAX_DEVICES_PER_USER = 20;
const DEVICE_TOKEN_PATTERN = /^[a-f0-9]{32,400}$/i;
const DEVICE_ENVIRONMENTS = new Set(["sandbox", "production"]);
const NOTIFICATION_CATEGORIES = new Set([
  "calendarDeadline", "friendMessage", "friendRequest", "groupInvite", "shareInvite",
  "flashcardReview", "aiTaskComplete", "studyStreak", "newDeviceLogin", "announcement",
]);

export function deviceStorageKey(userKey) {
  return `chat:devices:${userKey}`;
}

export async function loadDevices(env, userKey) {
  const value = await env.STUDIQUO_DATA.get(deviceStorageKey(userKey), "json");
  return Array.isArray(value) ? value : [];
}

export async function removeDevice(env, userKey, deviceToken) {
  const devices = await loadDevices(env, userKey);
  const remaining = devices.filter(device => device.token !== deviceToken);
  if (remaining.length === devices.length) return false;
  if (remaining.length === 0) await env.STUDIQUO_DATA.delete(deviceStorageKey(userKey));
  else await env.STUDIQUO_DATA.put(deviceStorageKey(userKey), JSON.stringify(remaining));
  const ownerKey = `chat:device-owner:${deviceToken}`;
  if (await env.STUDIQUO_DATA.get(ownerKey) === userKey) await env.STUDIQUO_DATA.delete(ownerKey);
  return true;
}

function parseDevice(body) {
  const token = String(body?.deviceToken ?? "").trim().toLowerCase();
  const environment = String(body?.environment ?? "");
  if (!DEVICE_TOKEN_PATTERN.test(token) || token.length % 2 !== 0) return null;
  if (!DEVICE_ENVIRONMENTS.has(environment)) return null;
  const installationID = typeof body?.installationID === "string"
    ? body.installationID.trim().slice(0, 100)
    : null;
  const deviceName = typeof body?.deviceName === "string"
    ? body.deviceName.trim().slice(0, 80)
    : null;
  // BCP 47 code of the app's language, so a broadcast (e.g. an announcement)
  // can be pushed in each device's own language.
  const language = typeof body?.language === "string" && /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$/.test(body.language.trim())
    ? body.language.trim()
    : null;
  const preferences = {};
  if (body?.preferences && typeof body.preferences === "object" && !Array.isArray(body.preferences)) {
    for (const [category, enabled] of Object.entries(body.preferences)) {
      if (NOTIFICATION_CATEGORIES.has(category) && typeof enabled === "boolean") preferences[category] = enabled;
    }
  }
  return {
    token,
    environment,
    ...(installationID ? { installationID } : {}),
    ...(deviceName ? { deviceName } : {}),
    ...(language ? { language } : {}),
    ...(Object.keys(preferences).length ? { preferences } : {}),
  };
}

export async function handleDeviceRoutes(url, request, env, userKey, ctx) {
  if (url.pathname !== "/api/chat/devices") return null;

  if (request.method === "POST") {
    const allowed = await checkRateLimit(env.RATE_LIMIT_CHAT_DEVICE_REGISTER, userKey);
    if (!allowed) return json({ error: "Too many device registrations. Please try again later." }, 429);
    const body = await readJSONLimited(request, MAX_BODY);
    if (body === null) return json({ error: "Invalid device registration." }, 400);
    const device = parseDevice(body);
    if (!device) return json({ error: "Invalid device registration." }, 400);

    const now = Date.now();
    const ownerKey = `chat:device-owner:${device.token}`;
    const previousOwner = await env.STUDIQUO_DATA.get(ownerKey);
    if (previousOwner && previousOwner !== userKey) {
      await removeDevice(env, previousOwner, device.token);
    }
    const existing = await loadDevices(env, userKey);
    const previousDevice = existing.find(item => item.token === device.token);
    const mergedDevice = {
      ...previousDevice,
      ...device,
      preferences: device.preferences ?? previousDevice?.preferences,
      updatedAt: now,
    };
    const devices = [
      ...existing.filter(item => item.token !== device.token),
      mergedDevice,
    ].slice(-MAX_DEVICES_PER_USER);
    await Promise.all([
      env.STUDIQUO_DATA.put(deviceStorageKey(userKey), JSON.stringify(devices)),
      env.STUDIQUO_DATA.put(ownerKey, userKey),
    ]);
    const isNewInstallation = Boolean(device.installationID)
      && !existing.some(item => item.installationID === device.installationID);
    const otherDevices = existing.filter(item => item.token !== device.token && item.installationID !== device.installationID);
    if (isNewInstallation && otherDevices.length > 0) {
      const delivery = sendPush(env, userKey, {
        category: "newDeviceLogin",
        title: "新しい端末からのログイン",
        body: `${device.deviceName || "新しい端末"}でStudiquoへのログインが確認されました。`,
        data: { route: "newDeviceLogin" },
      }, { devices: otherDevices, excludeInstallationID: device.installationID });
      if (ctx?.waitUntil) ctx.waitUntil(delivery);
      else await delivery;
    }
    return json({ status: "registered" });
  }

  if (request.method === "DELETE") {
    const body = await readJSONLimited(request, MAX_BODY);
    if (body === null) return json({ error: "Invalid device registration." }, 400);
    const token = String(body?.deviceToken ?? "").trim().toLowerCase();
    if (!DEVICE_TOKEN_PATTERN.test(token) || token.length % 2 !== 0) {
      return json({ error: "Invalid device registration." }, 400);
    }
    await removeDevice(env, userKey, token);
    return json({ status: "unregistered" });
  }

  return json({ error: "Method not allowed." }, 405);
}
