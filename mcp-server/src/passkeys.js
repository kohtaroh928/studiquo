import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from "@simplewebauthn/server";
import { isRevoked } from "./revocation.js";
import { isExpired } from "./token.js";
import { checkRateLimit, clientKey } from "./rate-limit.js";
import { bearerToken, sha256Hex } from "./auth.js";
import { json, readJSONLimited } from "./http.js";
import { mintSession, hasRealSession } from "./session.js";

const RP_ID = "studiquo-mcp.studiquo-mcp-server.workers.dev";
const ORIGIN = `https://${RP_ID}`;
const APP_ID = "972G4VGUA6.com.yabuko.studiquo";

// Shared budget for every rate-limited endpoint below. Change this one value
// (and the matching `simple.limit` entries in wrangler.jsonc) to retune all
// four at once.
const RATE_LIMIT_PER_MINUTE = 5;

async function body(request) {
  return readJSONLimited(request, 100_000);
}

function transactionID() {
  return crypto.randomUUID();
}

export function associationFile() {
  return json({ webcredentials: { apps: [APP_ID] } });
}

export async function handlePasskeys(url, request, env) {
  if (!url.pathname.startsWith("/api/passkeys/")) return null;

  if (url.pathname === "/api/passkeys/register/options" && request.method === "POST") {
    const token = bearerToken(request);
    const payload = await body(request);
    const email = String(payload?.email ?? "").trim().toLowerCase();
    if (!token || email.length > 254 || !email.includes("@")) return json({ error: "Invalid request." }, 400);
    if (isExpired(token)) return json({ error: "This token has expired. Reconnect from Studiquo to get a new one." }, 401);
    if (!(await hasRealSession(env, token))) return json({ error: "Reconnect from Studiquo to get a new token." }, 401);
    const userKey = await sha256Hex(token);
    const allowed = await checkRateLimit(env, env.RATE_LIMIT_PASSKEY_REGISTER_OPTIONS, "passkey-register-options", userKey, RATE_LIMIT_PER_MINUTE);
    if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);
    if (await isRevoked(env, userKey)) return json({ error: "This token has been revoked. Reconnect from Studiquo to get a new one." }, 401);
    const existing = await env.STUDIQUO_DATA.get(`passkeys:user:${userKey}`, "json") ?? [];
    const options = await generateRegistrationOptions({
      rpName: "Studiquo",
      rpID: RP_ID,
      userName: email,
      userDisplayName: email,
      userID: new TextEncoder().encode(userKey),
      attestationType: "none",
      excludeCredentials: existing.map(item => ({ id: item.id, transports: item.transports ?? ["internal"] })),
      authenticatorSelection: {
        authenticatorAttachment: "platform",
        residentKey: "required",
        userVerification: "required",
      },
      supportedAlgorithmIDs: [-7],
    });
    const transaction = transactionID();
    await env.STUDIQUO_DATA.put(`passkeys:challenge:${transaction}`, JSON.stringify({
      kind: "registration", challenge: options.challenge, userKey, email,
    }), { expirationTtl: 300 });
    return json({ transaction, options });
  }

  if (url.pathname === "/api/passkeys/register/verify" && request.method === "POST") {
    const token = bearerToken(request);
    if (token) {
      const allowed = await checkRateLimit(env, env.RATE_LIMIT_PASSKEY_REGISTER_VERIFY, "passkey-register-verify", await sha256Hex(token), RATE_LIMIT_PER_MINUTE);
      if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);
    }
    const payload = await body(request);
    const transaction = String(payload?.transaction ?? "");
    const pending = await env.STUDIQUO_DATA.get(`passkeys:challenge:${transaction}`, "json");
    if (!token || !pending || pending.kind !== "registration" || pending.userKey !== await sha256Hex(token)) {
      return json({ error: "Registration expired." }, 400);
    }
    if (isExpired(token)) return json({ error: "This token has expired. Reconnect from Studiquo to get a new one." }, 401);
    if (!(await hasRealSession(env, token))) return json({ error: "Reconnect from Studiquo to get a new token." }, 401);
    if (await isRevoked(env, pending.userKey)) return json({ error: "This token has been revoked. Reconnect from Studiquo to get a new one." }, 401);
    await env.STUDIQUO_DATA.delete(`passkeys:challenge:${transaction}`);
    try {
      const verification = await verifyRegistrationResponse({
        response: payload.credential,
        expectedChallenge: pending.challenge,
        expectedOrigin: ORIGIN,
        expectedRPID: RP_ID,
        requireUserVerification: true,
      });
      if (!verification.verified) return json({ error: "Passkey verification failed." }, 401);
      const saved = await env.STUDIQUO_DATA.get(`passkeys:user:${pending.userKey}`, "json") ?? [];
      const credential = verification.registrationInfo.credential;
      const record = {
        id: credential.id,
        publicKey: Array.from(credential.publicKey),
        counter: credential.counter,
        transports: credential.transports ?? ["internal"],
        email: pending.email,
        userKey: pending.userKey,
      };
      const updated = [...saved.filter(item => item.id !== record.id), record].slice(-10);
      await Promise.all([
        env.STUDIQUO_DATA.put(`passkeys:user:${pending.userKey}`, JSON.stringify(updated)),
        env.STUDIQUO_DATA.put(`passkeys:credential:${record.id}`, JSON.stringify(record)),
      ]);
      return json({ registered: true });
    } catch {
      return json({ error: "Passkey verification failed." }, 401);
    }
  }

  if (url.pathname === "/api/passkeys/login/options" && request.method === "POST") {
    const allowed = await checkRateLimit(env, env.RATE_LIMIT_PASSKEY_LOGIN_OPTIONS, "passkey-login-options", clientKey(request), RATE_LIMIT_PER_MINUTE);
    if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);

    const options = await generateAuthenticationOptions({
      rpID: RP_ID,
      userVerification: "required",
      allowCredentials: [],
    });
    const transaction = transactionID();
    await env.STUDIQUO_DATA.put(`passkeys:challenge:${transaction}`, JSON.stringify({
      kind: "authentication", challenge: options.challenge,
    }), { expirationTtl: 300 });
    return json({ transaction, options });
  }

  if (url.pathname === "/api/passkeys/login/verify" && request.method === "POST") {
    const allowed = await checkRateLimit(env, env.RATE_LIMIT_PASSKEY_LOGIN_VERIFY, "passkey-login-verify", clientKey(request), RATE_LIMIT_PER_MINUTE);
    if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);

    const payload = await body(request);
    const transaction = String(payload?.transaction ?? "");
    const credentialID = String(payload?.credential?.id ?? "");
    const randomValue = payload?.randomValue;
    if (typeof randomValue !== "string" || randomValue.length < 16 || randomValue.length > 200) {
      return json({ error: "randomValue is required." }, 400);
    }
    const [pending, record] = await Promise.all([
      env.STUDIQUO_DATA.get(`passkeys:challenge:${transaction}`, "json"),
      env.STUDIQUO_DATA.get(`passkeys:credential:${credentialID}`, "json"),
    ]);
    if (!pending || pending.kind !== "authentication" || !record) return json({ error: "Login expired." }, 400);
    await env.STUDIQUO_DATA.delete(`passkeys:challenge:${transaction}`);
    try {
      const verification = await verifyAuthenticationResponse({
        response: payload.credential,
        expectedChallenge: pending.challenge,
        expectedOrigin: ORIGIN,
        expectedRPID: RP_ID,
        credential: {
          id: record.id,
          publicKey: new Uint8Array(record.publicKey),
          counter: record.counter,
          transports: record.transports,
        },
        requireUserVerification: true,
      });
      if (!verification.verified) return json({ error: "Passkey verification failed." }, 401);
      record.counter = verification.authenticationInfo.newCounter;
      await env.STUDIQUO_DATA.put(`passkeys:credential:${record.id}`, JSON.stringify(record));
      // A successful passkey assertion is itself the proof of identity, same
      // as a verified Apple/Google token — mint a real session the same way
      // those exchanges do, rather than leaving the client to keep reusing
      // whatever bearer token it happened to already hold.
      const token = await mintSession(env, `email:${record.email}`, randomValue);
      if (!token) return json({ error: "Invalid randomValue." }, 400);
      return json({ authenticated: true, email: record.email, token });
    } catch {
      return json({ error: "Passkey verification failed." }, 401);
    }
  }

  return json({ error: "Not found" }, 404);
}
