// Per-feature kill switches: stop one part of the service without stopping the rest.
//
//   DISABLED_FEATURES="chat,email"     comma-separated names from FEATURES below
//
// Unset (or empty) changes nothing. Names are case-insensitive and may have spaces
// around them; a name that is not in FEATURES is ignored (the list /health shows
// only the names that took effect, so a typo is visible there). A stopped
// feature's routes answer 503 with `code: "feature_disabled"` and the feature's
// name, so the app can say what is paused. MAINTENANCE_MODE (app-gate.ts) comes
// first and stops everything.
//
// What is never stopped by this: /health, the legal and invite pages, the public
// announcements, the admin pages, and the account's own exits: deleting the
// account, signing out and refreshing a session.
//
// Two features are side effects, not routes: "push" (sendPush in push.ts) and
// "email" (the three places that call Resend; the route that sends the
// confirmation code is also stopped here, so the app is told instead of waiting
// for a code that will not come).
import { json } from "./http.ts";
import type { Env } from "./env.ts";

export const FEATURES = ["ai", "chat", "collab", "mcp", "signin", "email", "push"];

// A name that is not in FEATURES does nothing, which is easy to miss in an
// emergency ("chats" for "chat"). It is logged once per name per isolate, and
// /health lists only the names that took effect.
const warnedNames = new Set();

export function disabledFeatures(env: Env) {
  const names = String(env?.DISABLED_FEATURES ?? "")
    .split(",")
    .map(name => name.trim().toLowerCase())
    .filter(Boolean);
  for (const name of names) {
    if (!FEATURES.includes(name) && !warnedNames.has(name)) {
      warnedNames.add(name);
      console.warn(JSON.stringify({ message: "DISABLED_FEATURES has a name that stops nothing", name: name.slice(0, 40) }));
    }
  }
  return new Set(names.filter(name => FEATURES.includes(name)));
}

export function featureDisabled(env: Env, feature: any) {
  return disabledFeatures(env).has(feature);
}

/**
 * The feature a request belongs to, or null when it is not one a switch covers.
 *
 * A way out of the service must never sit under a stoppable prefix: keep the
 * account's exits (deleting it, signing out, refreshing a session) under
 * /api/account and /api/session, and do not put them under /api/auth/. The one
 * exit that does sit under a prefix, disconnecting an AI app (DELETE
 * /api/mcp/connections/:id), is listed here so that stopping "mcp" after a bad
 * connection does not stop the person from cutting it.
 */
export function featureForPath(pathname: string, method = "GET") {
  if (method === "DELETE" && pathname.startsWith("/api/mcp/connections/")) return null;
  if (pathname === "/api/auth/email/send-code") return "email";
  if (pathname.startsWith("/api/auth/") || pathname.startsWith("/api/passkeys/login/")) return "signin";
  if (pathname.startsWith("/api/ai/")) return "ai";
  if (pathname.startsWith("/api/chat/")) return "chat";
  if (pathname.startsWith("/api/document/")) return "collab";
  if (pathname === "/mcp" || pathname.startsWith("/oauth/") || pathname.startsWith("/api/mcp/")) return "mcp";
  return null;
}

/** A 503 for a request whose feature is stopped, or null. */
export function featureGateRejection(env: Env, pathname: string, method = "GET") {
  const feature = featureForPath(pathname, method);
  if (!feature || !featureDisabled(env, feature)) return null;
  const response = json({
    error: "この機能は一時的に停止しています。しばらくしてからもう一度お試しください。",
    code: "feature_disabled",
    feature,
  }, 503);
  response.headers.set("retry-after", "300");
  return response;
}
