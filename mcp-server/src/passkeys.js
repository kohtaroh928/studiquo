import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from "@simplewebauthn/server";

const RP_ID = "studiquo-mcp.studiquo-mcp-server.workers.dev";
const ORIGIN = `https://${RP_ID}`;
const APP_ID = "972G4VGUA6.com.yabuko.studiquo";

function json(value, status = 200) {
  return Response.json(value, { status, headers: {
    "cache-control": "no-store",
    "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
    "referrer-policy": "no-referrer",
    "x-content-type-options": "nosniff",
  } });
}

function tokenFrom(request) {
  const match = /^Bearer\s+(.+)$/i.exec(request.headers.get("authorization") ?? "");
  const token = match?.[1]?.trim() ?? "";
  return token.length >= 32 && token.length <= 256 ? token : null;
}

async function digest(value) {
  const data = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(data), byte => byte.toString(16).padStart(2, "0")).join("");
}

async function body(request) {
  const declared = Number(request.headers.get("content-length") ?? 0);
  if (declared > 100_000) return null;
  if (!request.body) return null;
  const reader = request.body.getReader();
  const decoder = new TextDecoder();
  let received = 0;
  let text = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    received += value.byteLength;
    if (received > 100_000) { await reader.cancel(); return null; }
    text += decoder.decode(value, { stream: true });
  }
  text += decoder.decode();
  try { return JSON.parse(text); } catch { return null; }
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
    const token = tokenFrom(request);
    const payload = await body(request);
    const email = String(payload?.email ?? "").trim().toLowerCase();
    if (!token || email.length > 254 || !email.includes("@")) return json({ error: "Invalid request." }, 400);
    const userKey = await digest(token);
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
    const token = tokenFrom(request);
    const payload = await body(request);
    const transaction = String(payload?.transaction ?? "");
    const pending = await env.STUDIQUO_DATA.get(`passkeys:challenge:${transaction}`, "json");
    if (!token || !pending || pending.kind !== "registration" || pending.userKey !== await digest(token)) {
      return json({ error: "Registration expired." }, 400);
    }
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
    const payload = await body(request);
    const transaction = String(payload?.transaction ?? "");
    const credentialID = String(payload?.credential?.id ?? "");
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
      return json({ authenticated: true, email: record.email });
    } catch {
      return json({ error: "Passkey verification failed." }, 401);
    }
  }

  return json({ error: "Not found" }, 404);
}
