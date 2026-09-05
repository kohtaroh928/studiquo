import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import * as z from "zod/v4";
import { handleAI } from "./ai.js";
import { associationFile, handlePasskeys } from "./passkeys.js";
import { handleChat } from "./chat.js";
import { isRevoked, revoke } from "./revocation.js";
import { isExpired } from "./token.js";
import { verifyAppleIdentityToken } from "./apple-auth.js";
import { verifyGoogleIdentityToken } from "./google-auth.js";
import { linkVerifiedEmail } from "./oauth-links.js";
import { sendVerificationCode, confirmVerificationCode } from "./email-verification.js";
import { upsertLocalAccount, verifyLocalAccount } from "./local-auth.js";
import { mintSession, hasRealSession } from "./session.js";
import { checkRateLimit, clientKey } from "./rate-limit.js";
import { bearerToken, sha256Hex } from "./auth.js";
import { json, readTextLimited } from "./http.js";

function toolResult(value) {
  return {
    content: [{ type: "text", text: JSON.stringify(value, null, 2) }],
    structuredContent: { result: value }
  };
}

async function loadSnapshot(env, key) {
  const value = await env.STUDIQUO_DATA.get(`snapshot:${key}`, "json");
  if (!value) throw new Error("No Studiquo data has been synced for this account yet.");
  return value;
}

async function queueAction(env, key, action) {
  const storageKey = `actions:${key}`;
  const existing = await env.STUDIQUO_DATA.get(storageKey, "json");
  const actions = Array.isArray(existing) ? existing : [];
  if (actions.length >= 1_000) throw new Error("Too many pending actions. Sync the app before adding more.");
  actions.push(action);
  await env.STUDIQUO_DATA.put(storageKey, JSON.stringify(actions));
}

function createServer(env, key) {
  const server = new McpServer(
    { name: "studiquo", version: "0.2.0" },
    { instructions: "Access only the authenticated user's Studiquo data. Write tools queue changes for approval/import in the iPad app." }
  );

  server.registerTool(
    "list_notebooks",
    {
      description: "List the authenticated user's Studiquo notebooks and pages.",
      inputSchema: z.object({})
    },
    async () => {
      const data = await loadSnapshot(env, key);
      return toolResult(data.notebooks.map(notebook => ({
        id: notebook.id,
        title: notebook.title,
        tags: notebook.tags ?? [],
        pageCount: notebook.pages.length,
        pages: notebook.pages.map(page => ({ id: page.id, title: page.title }))
      })));
    }
  );

  server.registerTool(
    "search_notes",
    {
      description: "Search notebook titles, page titles, and on-device OCR text.",
      inputSchema: z.object({
        query: z.string().min(1).max(500),
        limit: z.number().int().min(1).max(100).default(20)
      })
    },
    async ({ query, limit }) => {
      const data = await loadSnapshot(env, key);
      const needle = query.toLocaleLowerCase("ja");
      const matches = data.notebooks
        .flatMap(notebook => notebook.pages.flatMap(page => {
          const haystack = `${notebook.title}\n${page.title}\n${page.recognizedText ?? ""}`.toLocaleLowerCase("ja");
          return haystack.includes(needle)
            ? [{
                notebookId: notebook.id,
                notebookTitle: notebook.title,
                pageId: page.id,
                pageTitle: page.title,
                recognizedText: page.recognizedText ?? ""
              }]
            : [];
        }))
        .slice(0, limit);
      return toolResult(matches);
    }
  );

  server.registerTool(
    "list_flashcard_decks",
    {
      description: "List flashcard decks, optionally including cards.",
      inputSchema: z.object({ includeCards: z.boolean().default(false) })
    },
    async ({ includeCards }) => {
      const data = await loadSnapshot(env, key);
      return toolResult(data.flashcardDecks.map(deck => includeCards ? deck : ({
        id: deck.id,
        title: deck.title,
        cardCount: deck.cards.length
      })));
    }
  );

  server.registerTool(
    "list_calendar_events",
    {
      description: "List Studiquo calendar events.",
      inputSchema: z.object({ limit: z.number().int().min(1).max(200).default(80) })
    },
    async ({ limit }) => {
      const data = await loadSnapshot(env, key);
      return toolResult((data.calendarEvents ?? []).slice(0, limit));
    }
  );

  server.registerTool(
    "create_flashcards",
    {
      description: "Queue a flashcard deck for import into Studiquo.",
      inputSchema: z.object({
        deckTitle: z.string().min(1).max(100),
        cards: z.array(z.object({
          question: z.string().min(1).max(4_000),
          answer: z.string().min(1).max(8_000)
        })).min(1).max(200)
      })
    },
    async ({ deckTitle, cards }) => {
      await queueAction(env, key, { type: "create_flashcards", deckTitle, cards });
      return toolResult({ queued: true, deckTitle, cardCount: cards.length });
    }
  );

  server.registerTool(
    "add_calendar_event",
    {
      description: "Queue a calendar event for import into Studiquo. Dates must be ISO 8601.",
      inputSchema: z.object({
        title: z.string().min(1).max(150),
        startDate: z.iso.datetime(),
        endDate: z.iso.datetime(),
        kind: z.enum(["test", "classLesson", "other"]).default("other"),
        notes: z.string().max(2000).default("")
      })
    },
    async input => {
      await queueAction(env, key, { type: "add_calendar_event", ...input });
      return toolResult({ queued: true, title: input.title });
    }
  );

  return server;
}

async function handleMCP(request, env) {
  const token = bearerToken(request);
  if (!token) return json({ error: "A valid bearer token is required." }, 401);
  if (isExpired(token)) return json({ error: "This token has expired. Reconnect from Studiquo to get a new one." }, 401);
  if (!(await hasRealSession(env, token))) return json({ error: "Reconnect from Studiquo to get a new token." }, 401);
  const key = await sha256Hex(token);
  if (await isRevoked(env, key)) return json({ error: "This token has been revoked. Reconnect from Studiquo to get a new one." }, 401);
  if (!(await env.STUDIQUO_DATA.get(`snapshot:${key}`))) {
    return json({ error: "Run sync in Studiquo before connecting an AI client." }, 401);
  }
  const server = createServer(env, key);
  const transport = new WebStandardStreamableHTTPServerTransport({
    sessionIdGenerator: undefined,
    enableJsonResponse: true,
  });
  await server.connect(transport);
  return transport.handleRequest(request);
}

export default {
  async fetch(request, env, ctx) {
    try {
      const url = new URL(request.url);
      if (url.pathname === "/health") return json({ ok: true, service: "studiquo-mcp" });
      if (url.pathname === "/.well-known/apple-app-site-association") return associationFile();

      const passkeys = await handlePasskeys(url, request, env);
      if (passkeys) return passkeys;
      const chat = await handleChat(url, request, env);
      if (chat) return chat;

    if (url.pathname === "/mcp") {
      return handleMCP(request, env);
    }

    if (url.pathname.startsWith("/api/")) {
      // Sign in with Apple / Google both mint their own token, so — unlike
      // every other /api/* route — they must run before the bearer-token
      // gate below.
      if (url.pathname === "/api/auth/apple" && request.method === "POST") {
        return handleAppleSignIn(request, env);
      }
      if (url.pathname === "/api/auth/google" && request.method === "POST") {
        return handleGoogleSignIn(request, env);
      }
      if (url.pathname === "/api/auth/email/send-code" && request.method === "POST") {
        return handleSendEmailVerification(request, env);
      }
      if (url.pathname === "/api/auth/email/confirm-code" && request.method === "POST") {
        return handleConfirmEmailVerification(request, env);
      }
      if (url.pathname === "/api/auth/local/login" && request.method === "POST") {
        return handleLocalLogin(request, env);
      }

      const token = bearerToken(request);
      if (!token) return json({ error: "A valid bearer token is required." }, 401);
      if (isExpired(token)) return json({ error: "This token has expired. Reconnect from Studiquo to get a new one." }, 401);
      if (!(await hasRealSession(env, token))) return json({ error: "Reconnect from Studiquo to get a new token." }, 401);
      const key = await sha256Hex(token);
      if (await isRevoked(env, key)) return json({ error: "This token has been revoked. Reconnect from Studiquo to get a new one." }, 401);

      if (url.pathname === "/api/session/revoke" && request.method === "POST") {
        await revoke(env, key);
        return json({ revoked: true });
      }

      if (url.pathname === "/api/snapshot" && request.method === "PUT") {
        const declaredSize = Number(request.headers.get("content-length") ?? 0);
        if (declaredSize > 8_000_000) return json({ error: "Snapshot is too large." }, 413);
        const body = await readTextLimited(request, 8_000_000);
        if (body == null) return json({ error: "Snapshot is too large." }, 413);
        let parsed;
        try {
          parsed = JSON.parse(body);
        } catch {
          return json({ error: "Invalid JSON." }, 400);
        }
        if (parsed.version !== 1 || !Array.isArray(parsed.notebooks)) {
          return json({ error: "Invalid Studiquo snapshot." }, 400);
        }
        await env.STUDIQUO_DATA.put(`snapshot:${key}`, body);
        return json({ synced: true, exportedAt: parsed.exportedAt });
      }

      if (url.pathname === "/api/actions" && request.method === "GET") {
        return json(await env.STUDIQUO_DATA.get(`actions:${key}`, "json") ?? []);
      }

      if (url.pathname === "/api/actions" && request.method === "DELETE") {
        await env.STUDIQUO_DATA.delete(`actions:${key}`);
        return json({ cleared: true });
      }

      // Gemini proxy. Deliberately not gated on a synced snapshot the way
      // /mcp is — the AI features work on a fresh install, before the user
      // has ever run a sync.
      const ai = await handleAI(url, request, env, key, ctx);
      if (ai) return ai;

      return json({ error: "Not found" }, 404);
    }

      return json({ error: "Not found" }, 404);
    } catch (error) {
      console.error(JSON.stringify({ message: "request failed", error: error instanceof Error ? error.message : String(error) }));
      return json({ error: "Internal server error." }, 500);
    }
  }
};

// POST /api/auth/apple: exchanges a Sign in with Apple identityToken for a
// studiquo bearer token, in the same "<issued-at epoch>.<random>" format
// token.js already expects everywhere else.
async function handleAppleSignIn(request, env) {
  const allowed = await checkRateLimit(env, env.RATE_LIMIT_APPLE_AUTH, "apple-auth", clientKey(request), 5);
  if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);

  const declaredSize = Number(request.headers.get("content-length") ?? 0);
  if (declaredSize > 8_000) return json({ error: "Request body is too large." }, 413);
  const body = await readTextLimited(request, 8_000);
  if (body == null) return json({ error: "Request body is too large." }, 413);

  let parsed;
  try {
    parsed = JSON.parse(body);
  } catch {
    return json({ error: "Invalid JSON." }, 400);
  }

  const { identityToken, randomValue } = parsed ?? {};
  if (typeof identityToken !== "string" || !identityToken) {
    return json({ error: "identityToken is required." }, 400);
  }
  if (typeof randomValue !== "string" || randomValue.length < 16 || randomValue.length > 200) {
    return json({ error: "randomValue is required." }, 400);
  }

  let payload;
  try {
    payload = await verifyAppleIdentityToken(identityToken, env);
  } catch {
    return json({ error: "Invalid Apple identity token." }, 401);
  }

  const sub = payload.sub;
  if (typeof sub !== "string" || !sub) return json({ error: "Invalid Apple identity token." }, 401);

  // Email only ever arrives on a user's first authorization, so it's stored
  // once here and never overwritten by later sign-ins (which omit it).
  const accountKey = `account:${sub}`;
  const existingAccount = await env.STUDIQUO_DATA.get(accountKey, "json");
  const email = typeof payload.email === "string" ? payload.email : null;
  // Apple sends this as a string ("true"/"false") on some token shapes and a
  // real boolean on others — same defensive pattern as is_private_email
  // below.
  const emailVerified = payload.email_verified === true || payload.email_verified === "true";
  const emailIsPrivateRelay = payload.is_private_email === true || payload.is_private_email === "true";
  if (!existingAccount) {
    await env.STUDIQUO_DATA.put(accountKey, JSON.stringify({
      sub,
      email,
      emailIsPrivateRelay,
      createdAt: new Date().toISOString(),
    }));
  }
  // Only runs on a first authorization (later Apple sign-ins omit `email`
  // entirely), same as the account record above — an email seen once stays
  // linked even though Apple never sends it again. A private-relay address
  // is per-app and can never actually match the same person's Google/local
  // email, so it must not join the cross-provider link index (see
  // oauth-links.js's header comment).
  if (email && !emailIsPrivateRelay) {
    await linkVerifiedEmail(env, { provider: "apple", sub, email, emailVerified });
  }

  const token = await mintSession(env, sub, randomValue);
  if (!token) return json({ error: "Invalid randomValue." }, 400);
  return json({ token });
}

// POST /api/auth/google: exchanges a Google Sign-In idToken for a studiquo
// bearer token. Mirrors handleAppleSignIn above — same token format, same
// rate-limit shape, same account-record pattern — except Google resends
// `email`/`email_verified` on every sign-in (not just the first), so those
// are refreshed each time rather than written once.
async function handleGoogleSignIn(request, env) {
  const allowed = await checkRateLimit(env, env.RATE_LIMIT_GOOGLE_AUTH, "google-auth", clientKey(request), 5);
  if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);

  const declaredSize = Number(request.headers.get("content-length") ?? 0);
  if (declaredSize > 8_000) return json({ error: "Request body is too large." }, 413);
  const body = await readTextLimited(request, 8_000);
  if (body == null) return json({ error: "Request body is too large." }, 413);

  let parsed;
  try {
    parsed = JSON.parse(body);
  } catch {
    return json({ error: "Invalid JSON." }, 400);
  }

  const { idToken, randomValue } = parsed ?? {};
  if (typeof idToken !== "string" || !idToken) {
    return json({ error: "idToken is required." }, 400);
  }
  if (typeof randomValue !== "string" || randomValue.length < 16 || randomValue.length > 200) {
    return json({ error: "randomValue is required." }, 400);
  }

  let payload;
  try {
    payload = await verifyGoogleIdentityToken(idToken, env);
  } catch {
    return json({ error: "Invalid Google identity token." }, 401);
  }

  const sub = payload.sub;
  if (typeof sub !== "string" || !sub) return json({ error: "Invalid Google identity token." }, 401);

  const accountKey = `account:google:${sub}`;
  const existingAccount = await env.STUDIQUO_DATA.get(accountKey, "json");
  const email = typeof payload.email === "string" ? payload.email : null;
  const emailVerified = payload.email_verified === true;
  await env.STUDIQUO_DATA.put(accountKey, JSON.stringify({
    provider: "google",
    sub,
    email,
    emailVerified,
    createdAt: existingAccount?.createdAt ?? new Date().toISOString(),
  }));
  if (email) {
    await linkVerifiedEmail(env, { provider: "google", sub, email, emailVerified });
  }

  const token = await mintSession(env, `google:${sub}`, randomValue);
  if (!token) return json({ error: "Invalid randomValue." }, 400);

  return json({ token });
}

// POST /api/auth/email/send-code: emails a 6-digit verification code to the
// address a local email/password account was just created (or is being
// re-verified) with. Doesn't authenticate anything itself — it only proves
// the caller can read mail at that address, which is what lets
// confirm-code below link it alongside any Apple/Google account sharing it.
async function handleSendEmailVerification(request, env) {
  const allowed = await checkRateLimit(env, env.RATE_LIMIT_EMAIL_VERIFY_SEND, "email-verify-send", clientKey(request), 5);
  if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);

  const body = await readTextLimited(request, 2_000);
  if (body == null) return json({ error: "Request body is too large." }, 413);
  let parsed;
  try {
    parsed = JSON.parse(body);
  } catch {
    return json({ error: "Invalid JSON." }, 400);
  }

  const { email } = parsed ?? {};
  if (typeof email !== "string" || !email) return json({ error: "email is required." }, 400);

  try {
    await sendVerificationCode(env, email);
  } catch (error) {
    console.error(JSON.stringify({ message: "send-code failed", error: error instanceof Error ? error.message : String(error) }));
    return json({ error: "Could not send the verification email." }, 502);
  }
  return json({ sent: true });
}

// POST /api/auth/email/confirm-code: checks the code from that email
// against what's on file. Rate-limited by IP like the send step above, but
// confirmVerificationCode also enforces its own much tighter per-email
// attempt cap — this outer limit exists so one IP can't burn through many
// different email addresses' attempt budgets in a hurry.
//
// On a correct code, this also sets (or resets) the account's password —
// covering both initial signup and "forgot password" with the same
// endpoint, since proving control of the email is the same prerequisite
// either way — and mints a real session, same as Apple/Google do on their
// own exchange. `password` and `randomValue` are required for this reason:
// this is the only place a local account's password is ever set.
async function handleConfirmEmailVerification(request, env) {
  const allowed = await checkRateLimit(env, env.RATE_LIMIT_EMAIL_VERIFY_CONFIRM, "email-verify-confirm", clientKey(request), 10);
  if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);

  const body = await readTextLimited(request, 2_000);
  if (body == null) return json({ error: "Request body is too large." }, 413);
  let parsed;
  try {
    parsed = JSON.parse(body);
  } catch {
    return json({ error: "Invalid JSON." }, 400);
  }

  const { email, code, password, randomValue } = parsed ?? {};
  if (typeof email !== "string" || !email) return json({ error: "email is required." }, 400);
  if (typeof code !== "string" || !code) return json({ error: "code is required." }, 400);
  if (typeof password !== "string" || password.length < 8 || password.length > 1_024) {
    return json({ error: "password is required." }, 400);
  }
  if (typeof randomValue !== "string" || randomValue.length < 16 || randomValue.length > 200) {
    return json({ error: "randomValue is required." }, 400);
  }

  const result = await confirmVerificationCode(env, email, code);
  if (!result.verified) return json({ error: "Incorrect or expired code.", attemptsRemaining: result.attemptsRemaining }, 401);

  let normalizedEmail;
  try {
    normalizedEmail = email.trim().toLowerCase();
    await upsertLocalAccount(env, normalizedEmail, password);
  } catch {
    return json({ error: "Could not save the account." }, 400);
  }

  const token = await mintSession(env, `email:${normalizedEmail}`, randomValue);
  if (!token) return json({ error: "Invalid randomValue." }, 400);
  return json({ verified: true, token });
}

// POST /api/auth/local/login: verifies an email/password against the hash
// upsertLocalAccount stored, and mints a real session on success — the
// server-side counterpart to what AuthenticationStore.login() used to check
// entirely on-device. Rate-limited like every other unauthenticated
// exchange endpoint; there is no separate per-account lockout the way the
// old on-device check had one, since a flat per-IP limit is what every
// other sign-in path here already relies on.
async function handleLocalLogin(request, env) {
  const allowed = await checkRateLimit(env, env.RATE_LIMIT_LOCAL_LOGIN, "local-login", clientKey(request), 10);
  if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);

  const body = await readTextLimited(request, 2_000);
  if (body == null) return json({ error: "Request body is too large." }, 413);
  let parsed;
  try {
    parsed = JSON.parse(body);
  } catch {
    return json({ error: "Invalid JSON." }, 400);
  }

  const { email, password, randomValue } = parsed ?? {};
  if (typeof email !== "string" || !email) return json({ error: "email is required." }, 400);
  if (typeof password !== "string" || !password) return json({ error: "password is required." }, 400);
  if (typeof randomValue !== "string" || randomValue.length < 16 || randomValue.length > 200) {
    return json({ error: "randomValue is required." }, 400);
  }

  if (!(await verifyLocalAccount(env, email, password))) {
    return json({ error: "メールアドレスまたはパスワードが違います。" }, 401);
  }

  const token = await mintSession(env, `email:${email.trim().toLowerCase()}`, randomValue);
  if (!token) return json({ error: "Invalid randomValue." }, 400);
  return json({ token });
}
