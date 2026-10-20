import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import * as z from "zod/v4";
import { handleAI, subscriptionRequiredResponse } from "./ai.ts";
import { accountCounterKey } from "./ai-credits.ts";
import { aiPrivacyRejection } from "./ai-privacy.ts";
import { getPlan, paywallEnabled } from "./entitlements.ts";
import { handleDocumentCollab } from "./document-collab.js";
import { handleLegal } from "./legal.js";
import { associationFile, handlePasskeys, revokePasskeysForAccount } from "./passkeys.ts";
import { libraryIdObjectName } from "./library-id.ts";
import { gatePasskeyAccount, requireRecentPasskey, resolveAccountKey } from "./passkey-policy.ts";
import { handleChat } from "./chat.js";
import { handleIssueReports } from "./issue-reports.js";
import { handleAppErrors } from "./app-errors.js";
import { handleAdminReports } from "./admin-reports.js";
import { handleModerationActions } from "./moderation-actions.js";
import { handleAnnouncements, handleAnnouncementsPage } from "./announcements.js";
import { handleAdminPage, handleAdminWebhook, handleUsageEvent, handleAdminStats } from "./admin.js";
import { handleInvitePage } from "./invite.js";
import { accessAllowed, isAccessGuardedPath, isCrossSiteWrite } from "./access.ts";
import { appGateRejection } from "./app-gate.ts";
import { handleAppAttest, appAttestGate } from "./app-attest.ts";
import { plainHttpResponse, withTransportHeaders } from "./transport.js";
import { disabledFeatures } from "./features.ts";
import { idTokenNonceRefused } from "./id-token-nonce.ts";
import { isRevoked, revoke } from "./revocation.ts";
import { isExpired, remainingValiditySeconds } from "./token.ts";
import { resolveChatUserKey } from "./chat-identity.ts";
import { realSession } from "./session.ts";
import { handleMCPOAuth, externalSession, issueOwnerCode, listConnections, revokeConnection, revokeAllConnections } from "./mcp-oauth.ts";
import { verifyAppleIdentityToken } from "./apple-auth.ts";
import { verifyGoogleIdentityToken } from "./google-auth.ts";
import { linkVerifiedEmail, identityKey } from "./oauth-links.ts";
import { sendVerificationCode, confirmVerificationCode } from "./email-verification.ts";
import { upsertLocalAccount, verifyLocalAccount, Argon2BusyError } from "./local-auth.ts";
import { startAccountDeletion } from "./account-deletion.js";
import { hasModerationMark, CHAT_SUSPENSION_PREFIX, mintSession, hasRealSession, revokeSessionsIssuedBefore, accountIsBeingDeleted, accountIsUnavailable } from "./session.ts";
import { checkRateLimit, clientKey } from "./rate-limit.ts";
import { beginLoginAttempt, finishLoginAttempt, abandonLoginAttempt } from "./login-throttle.ts";
import { isBreachedPassword } from "./pwned-passwords.ts";
import { recordLoginOutcome, noteSignInContext } from "./login-monitor.ts";
import { bearerToken, sha256Hex } from "./auth.ts";
import { json, readTextLimited, readJSONLimited, securityHeaders } from "./http.ts";
import { sealSnapshot, openSnapshot } from "./snapshot-crypto.ts";

function toolResult(value) {
  return {
    content: [{ type: "text", text: JSON.stringify(value, null, 2) }],
    structuredContent: { result: value }
  };
}

// The account-level snapshot copy (read by connected MCP apps) outlives any
// session, so it is given its own lifetime: 90 days after the last sync.
const ACCOUNT_SNAPSHOT_TTL_SECONDS = 90 * 24 * 60 * 60;

async function loadSnapshot(env, key) {
  const storageKey = `snapshot:${key}`;
  const text = await openSnapshot(env, storageKey, await env.STUDIQUO_DATA.get(storageKey));
  if (!text) throw new Error("No Studiquo data has been synced for this account yet.");
  return JSON.parse(text);
}

async function queueAction(env, key, action, ttlSeconds = null) {
  const storageKey = `actions:${key}`;
  const existing = await env.STUDIQUO_DATA.get(storageKey, "json");
  const actions = Array.isArray(existing) ? existing : [];
  if (actions.length >= 1_000) throw new Error("Too many pending actions. Sync the app before adding more.");
  actions.push(action);
  // Queued under a device token's hash: it expires with that token's session,
  // so account deletion can always account for it (see remainingValiditySeconds).
  await env.STUDIQUO_DATA.put(storageKey, JSON.stringify(actions), ttlSeconds ? { expirationTtl: ttlSeconds } : undefined);
}

function createServer(env, key, accountHash = null, source = "MCP", canWrite = true, canRead = true, actionTtlSeconds = null) {
  const server = new McpServer(
    { name: "studiquo", version: "0.2.0" },
    { instructions: "Access only the authenticated user's Studiquo data. Write tools queue materials for import when the iPad app next connects; pending does not mean imported." }
  );

  server.registerTool(
    "list_notebooks",
    {
      description: "List the authenticated user's Studiquo notebooks and pages.",
      inputSchema: z.object({})
    },
    async () => {
      if (!canRead) return { isError: true, content: [{ type: "text", text: "This Studiquo connection cannot read materials." }] };
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
      if (!canRead) return { isError: true, content: [{ type: "text", text: "This Studiquo connection cannot read materials." }] };
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
      if (!canRead) return { isError: true, content: [{ type: "text", text: "This Studiquo connection cannot read materials." }] };
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
      if (!canRead) return { isError: true, content: [{ type: "text", text: "This Studiquo connection cannot read materials." }] };
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
        folderPath: z.string().max(500).default(""),
        cards: z.array(z.object({
          question: z.string().min(1).max(4_000),
          answer: z.string().min(1).max(8_000)
        })).min(1).max(200)
      })
    },
    async ({ deckTitle, cards, folderPath }) => {
      if (!canWrite) return { isError: true, content: [{ type: "text", text: "This Studiquo connection is read-only." }] };
      if (accountHash) {
        if (folderPath) {
          const data = await loadSnapshot(env, key);
          if (!(data.folders ?? []).some(folder => folder.path === folderPath)) {
            return { isError: true, content: [{ type: "text", text: "That Studiquo folder does not exist. Run sync in the iPad app and choose a path from list_folders." }] };
          }
        }
        return toolResult(await env.MCP_INBOX.getByName(accountHash).enqueue(
          crypto.randomUUID(), "create_flashcards", { deckTitle, cards, folderPath }, source
        ));
      }
      await queueAction(env, key, { type: "create_flashcards", deckTitle, cards }, actionTtlSeconds);
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
      if (!canWrite) return { isError: true, content: [{ type: "text", text: "This Studiquo connection is read-only." }] };
      if (accountHash) {
        const result = await env.MCP_INBOX.getByName(accountHash).enqueue(crypto.randomUUID(), "add_calendar_event", input, source);
        return toolResult(result);
      }
      await queueAction(env, key, { type: "add_calendar_event", ...input }, actionTtlSeconds);
      return toolResult({ queued: true, title: input.title });
    }
  );

  const submit = async (kind, payload) => {
    if (!canWrite) return { isError: true, content: [{ type: "text", text: "This Studiquo connection is read-only." }] };
    if (!accountHash) throw new Error("Reconnect your Studiquo account before creating materials.");
    if (payload.folderPath) {
      const data = await loadSnapshot(env, key);
      if (!(data.folders ?? []).some(folder => folder.path === payload.folderPath)) {
        return { isError: true, content: [{ type: "text", text: "That Studiquo folder does not exist. Run sync in the iPad app and choose a path from list_folders." }] };
      }
    }
    return toolResult(await env.MCP_INBOX.getByName(accountHash).enqueue(crypto.randomUUID(), kind, payload, source));
  };

  server.registerTool("list_folders", {
    description: "List the user's Studiquo folders for choosing where a new item should be saved. An empty folderPath means Home.",
    inputSchema: z.object({}),
  }, async () => {
    if (!canRead) return { isError: true, content: [{ type: "text", text: "This Studiquo connection cannot read materials." }] };
    const data = await loadSnapshot(env, key);
    return toolResult(data.folders ?? []);
  });

  server.registerTool("create_document", {
    description: "Send a text document to Studiquo. It is imported when the user's iPad syncs; the returned pending ID is not proof of import.",
    inputSchema: z.object({ title: z.string().min(1).max(150), body: z.string().min(1).max(100_000), folderPath: z.string().max(500).default("") }),
  }, input => submit("create_document", input));

  server.registerTool("create_notebook", {
    description: "Send a text-based notebook to Studiquo for import. This creates editable pages, not handwriting strokes.",
    inputSchema: z.object({
      title: z.string().min(1).max(150), folderPath: z.string().max(500).default(""),
      pages: z.array(z.object({ title: z.string().max(200), text: z.string().max(2_000) })).min(1).max(100),
    }),
  }, input => submit("create_notebook", input));

  server.registerTool("get_import_status", {
    description: "Check whether a submitted Studiquo item is still pending or has been imported on the iPad.",
    inputSchema: z.object({ id: z.uuid() }),
  }, async ({ id }) => canRead
    ? toolResult(accountHash ? await env.MCP_INBOX.getByName(accountHash).status(id) : null)
    : { isError: true, content: [{ type: "text", text: "This Studiquo connection cannot read materials." }] });

  return server;
}

/**
 * Every other route in this Worker reads its body through `readJSONLimited`/
 * `readTextLimited`, capped well below what a legitimate request needs. This
 * one used to be the exception: the request went straight to the MCP SDK's
 * `WebStandardStreamableHTTPServerTransport`, which parses the body itself
 * with no size limit at all. Reachable only with a real, synced session, so
 * the risk was a rogue device burning Worker memory/CPU rather than an
 * unauthenticated one — but there's no reason this route alone should skip
 * the same defense-in-depth every other one gets.
 */
const MAX_MCP_BODY = 8_000_000;

// Every call to /mcp builds a server and runs a tool, and nothing else limited
// how often a connected client (or a stolen token) could do that. Counted per
// credential: the account for an app connected through OAuth, the token for one
// connected by hand.
const MCP_CALLS_PER_MINUTE = 120;

// The synced snapshot is up to 8MB and each upload writes it to KV twice; the
// app only uploads when the person taps the sync button.
const SNAPSHOT_UPLOADS_PER_HOUR = 30;

// Every AI request is refused or let through by the credit windows in
// ai-credits.js, but only after its body (up to 20MB) has been read. This
// bounds how many bodies one account can make the Worker read.
const AI_REQUESTS_PER_MINUTE = 60;

function tooManyRequests(seconds = 60) {
  return Response.json({ error: "Too many requests. Please slow down." }, { status: 429, headers: securityHeaders({ "retry-after": String(seconds) }) });
}

async function handleMCP(request, env) {
  const token = bearerToken(request);
  const external = token ? await externalSession(env, request) : null;
  if (!external && (!token || token.startsWith("mcp_"))) return Response.json({ error: "Connect your Studiquo account." }, { status: 401, headers: securityHeaders({ "WWW-Authenticate": `Bearer resource_metadata="${new URL(request.url).origin}/.well-known/oauth-protected-resource"` }) });
  if (!external && isExpired(token)) return json({ error: "This token has expired. Reconnect from Studiquo to get a new one." }, 401);
  if (!external && !(await hasRealSession(env, token))) return json({ error: "Reconnect from Studiquo to get a new token." }, 401);
  const deviceKey = external ? null : await sha256Hex(token);
  if (!external && await isRevoked(env, deviceKey)) return json({ error: "This token has been revoked. Reconnect from Studiquo to get a new one." }, 401);
  const accountHash = external ? await sha256Hex(`mcp-account:${external.sub}`) : null;
  const key = accountHash ?? deviceKey;
  if (!(await env.RATE_COUNTER.getByName(`mcp-call:${key}`).bump(MCP_CALLS_PER_MINUTE, 60))) return tooManyRequests();
  if (!external && !(await env.STUDIQUO_DATA.get(`snapshot:${key}`))) {
    return json({ error: "Run sync in Studiquo before connecting an AI client." }, 401);
  }
  if (request.method === "POST") {
    const text = await readTextLimited(request, MAX_MCP_BODY);
    if (text === null) return json({ error: "Request body too large." }, 413);
    const headers = new Headers(request.headers);
    headers.delete("content-length");
    request = new Request(request.url, { method: request.method, headers, body: text || undefined });
  }
  const client = external ? await env.STUDIQUO_DATA.get(`mcp:client:${external.clientId}`, "json") : null;
  const server = createServer(env, key, accountHash, client?.clientName ?? "MCP",
    !external || external.scope?.split(" ").includes("studiquo.write"),
    !external || external.scope?.split(" ").includes("studiquo.read"),
    external ? null : remainingValiditySeconds(token));
  const transport = new WebStandardStreamableHTTPServerTransport({
    sessionIdGenerator: undefined,
    enableJsonResponse: true,
  });
  await server.connect(transport);
  return transport.handleRequest(request);
}

const handler = {
  async fetch(request, env, ctx) {
    try {
      const url = new URL(request.url);
      if (url.pathname === "/health") {
        // Stopped features are listed so a typo in DISABLED_FEATURES shows here.
        const stopped = [...disabledFeatures(env)];
        return json({ ok: true, service: "studiquo-mcp", ...(stopped.length ? { disabledFeatures: stopped } : {}) });
      }
      const gate = appGateRejection(request, env, url);
      if (gate) return gate;
      // /api/admin/* is not reliably behind Cloudflare Access at the edge, so
      // verify the Access login here, once, for every admin route.
      if (isAccessGuardedPath(url.pathname)) {
        // The login may be a cookie, so a write another site's page triggered
        // must not be taken for the owner's own action (access.js).
        if (isCrossSiteWrite(request, url)) return json({ error: "Forbidden." }, 403);
        if (!(await accessAllowed(request, env))) return json({ error: "Forbidden." }, 403);
      }
      const oauth = await handleMCPOAuth(url, request, env, ctx);
      if (oauth) return oauth;
      if (url.pathname === "/.well-known/apple-app-site-association") return associationFile();
      const invitePage = handleInvitePage(url);
      if (invitePage) return invitePage;

      const legal = handleLegal(url);
      if (legal) return legal;

      // App Attest (src/app-attest.js): the two routes that register an app
      // instance, then the check on the AI and sign-in routes. Off unless
      // APP_ATTEST_MODE is set. Before the passkey routes, which sign people in too.
      if (url.pathname.startsWith("/api/")) {
        const attest = await handleAppAttest(url, request, env);
        if (attest) return attest;
        const attestRefusal = await appAttestGate(request, env, url);
        if (attestRefusal) return attestRefusal;
      }
      const passkeys = await handlePasskeys(url, request, env);
      if (passkeys) return passkeys;
      const chat = await handleChat(url, request, env, ctx);
      if (chat) return chat;
      const issueReports = await handleIssueReports(url, request, env);
      if (issueReports) return issueReports;
      const announcementsPage = handleAnnouncementsPage(url);
      if (announcementsPage) return announcementsPage;
      const announcements = await handleAnnouncements(url, request, env);
      if (announcements) return announcements;
      const adminPage = handleAdminPage(url);
      if (adminPage) return adminPage;
      const adminWebhook = await handleAdminWebhook(url, request, env);
      if (adminWebhook) return adminWebhook;
      const adminStats = await handleAdminStats(url, request, env);
      if (adminStats) return adminStats;
      const moderationActions = await handleModerationActions(url, request, env);
      if (moderationActions) return moderationActions;
      const adminReports = await handleAdminReports(url, request, env);
      if (adminReports) return adminReports;
      const appErrors = await handleAppErrors(url, request, env);
      if (appErrors) return appErrors;
      const usageEvent = await handleUsageEvent(url, request, env);
      if (usageEvent) return usageEvent;

    if (url.pathname === "/mcp") {
      return handleMCP(request, env);
    }

    if (url.pathname.startsWith("/api/")) {
      // Sign in with Apple / Google both mint their own token, so — unlike
      // every other /api/* route — they must run before the bearer-token
      // gate below.
      if (url.pathname === "/api/auth/apple" && request.method === "POST") {
        return handleAppleSignIn(request, env, ctx);
      }
      if (url.pathname === "/api/auth/google" && request.method === "POST") {
        return handleGoogleSignIn(request, env, ctx);
      }
      if (url.pathname === "/api/auth/email/send-code" && request.method === "POST") {
        return handleSendEmailVerification(request, env);
      }
      if (url.pathname === "/api/auth/email/confirm-code" && request.method === "POST") {
        return handleConfirmEmailVerification(request, env, ctx);
      }
      if (url.pathname === "/api/auth/local/login" && request.method === "POST") {
        return handleLocalLogin(request, env, ctx);
      }

      const token = bearerToken(request);
      if (!token) return json({ error: "A valid bearer token is required." }, 401);
      if (isExpired(token)) return json({ error: "This token has expired. Reconnect from Studiquo to get a new one." }, 401);
      // Leaving stays possible for a suspended account (App Store requirement).
      const mayBeSuspended = url.pathname === "/api/account" && request.method === "DELETE";
      if (!(await hasRealSession(env, token, { allowSuspended: mayBeSuspended }))) return json({ error: "Reconnect from Studiquo to get a new token." }, 401);
      const key = await sha256Hex(token);
      if (await isRevoked(env, key)) return json({ error: "This token has been revoked. Reconnect from Studiquo to get a new one." }, 401);

      if (url.pathname === "/api/session/revoke" && request.method === "POST") {
        await revoke(env, key);
        return json({ revoked: true });
      }

      const session = await realSession(env, token, { allowSuspended: mayBeSuspended });
      if (url.pathname === "/api/session/refresh" && request.method === "POST") {
        return handleSessionRefresh(request, env, token, session);
      }
      const accountHash = session ? await sha256Hex(`mcp-account:${session.sub}`) : null;
      // A stable, opaque id for the person's account, so the app can keep one
      // library per account on a device (it is the same whichever sign-in
      // method is used, because it follows the account's canonical identity).
      // Random, kept per account (UserRegistry.libraryID): it says nothing about
      // the account and cannot be worked out from an e-mail address.
      if (url.pathname === "/api/account/library-id" && request.method === "GET") {
        if (!session) return json({ error: "Sign in again." }, 401);
        const canonical = await resolveAccountKey(env, session.sub);
        if (!env.USER_REGISTRY) return json({ error: "Not available." }, 503);
        const registry = env.USER_REGISTRY.getByName(libraryIdObjectName(await sha256Hex(canonical)));
        let libraryID;
        try {
          libraryID = await registry.libraryID();
          // A deletion may have started after the session was checked and erased
          // this id before it was asked for: the id just made would outlive the
          // account (and a new sign-up would get it back). Take it away again.
          if (await accountIsUnavailable(env, session.sub)) {
            await registry.eraseLibraryID();
            return json({ error: "Sign in again." }, 401);
          }
        } catch {
          return json({ error: "Not available." }, 503);
        }
        return json({ libraryID });
      }
      if (url.pathname === "/api/account" && request.method === "DELETE") {
        if (!session) return json({ error: "Sign in again." }, 401);
        const needsPasskey = await requireRecentPasskey(env, token, session, "delete-account");
        if (needsPasskey) return needsPasskey;
        const body = await readJSONLimited(request, 1_000);
        if (body?.confirmation !== "DELETE") return json({ error: "Confirmation is required." }, 400);
        const result = await startAccountDeletion(env, session.sub);
        return json(result, result.cleanupPending || result.externalDeletionPending ? 202 : 200);
      }
      if (url.pathname === "/api/mcp/pairing-code" && request.method === "POST") {
        if (!session) return json({ error: "Sign in again." }, 401);
        const needsPasskey = await requireRecentPasskey(env, token, session, "approve-app");
        if (needsPasskey) return needsPasskey;
        if (!(await checkRateLimit(env.RATE_LIMIT_MCP_PAIR, accountHash))) return json({ error: "Too many attempts." }, 429);
        const body = await readJSONLimited(request, 1000);
        const issued = await issueOwnerCode(env, session.sub, String(body?.kind ?? ""));
        return issued ? json(issued) : json({ error: "Unknown kind." }, 400);
      }
      if (url.pathname === "/api/mcp/connections" && request.method === "GET") {
        return session ? json(await listConnections(env, session.sub)) : json({ error: "Sign in again." }, 401);
      }
      if (url.pathname.startsWith("/api/mcp/connections/") && request.method === "DELETE") {
        return session ? json({ revoked: await revokeConnection(env, session.sub, url.pathname.split("/").pop()) }) : json({ error: "Sign in again." }, 401);
      }
      if (url.pathname === "/api/mcp/inbox" && request.method === "GET") {
        return accountHash ? json(await env.MCP_INBOX.getByName(accountHash).list()) : json({ error: "Sign in again." }, 401);
      }
      if (url.pathname.startsWith("/api/mcp/inbox/") && request.method === "POST") {
        const id = url.pathname.split("/").pop();
        if (!accountHash || !/^[0-9a-f-]{36}$/.test(id)) return json({ error: "Invalid request." }, 400);
        return json(await env.MCP_INBOX.getByName(accountHash).acknowledge(id));
      }

      if (url.pathname === "/api/snapshot" && request.method === "PUT") {
        if (!(await env.RATE_COUNTER.getByName(`snapshot-upload:${key}`).bump(SNAPSHOT_UPLOADS_PER_HOUR, 3_600))) return tooManyRequests(600);
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
        // Under the token's hash, so it expires with the token's session. The
        // account-level copy below lives 90 days past the last sync (or until
        // the account is deleted).
        // Each copy is sealed under its own key name, so one cannot be moved
        // to another key and still open (see snapshot-crypto.js).
        try {
          await env.STUDIQUO_DATA.put(`snapshot:${key}`, await sealSnapshot(env, `snapshot:${key}`, body), { expirationTtl: remainingValiditySeconds(token) });
          // Re-written on every sync, so this only lets go of the copy of an
          // account that has stopped syncing.
          if (accountHash) await env.STUDIQUO_DATA.put(`snapshot:${accountHash}`, await sealSnapshot(env, `snapshot:${accountHash}`, body), { expirationTtl: ACCOUNT_SNAPSHOT_TTL_SECONDS });
        } catch (error) {
          console.error(JSON.stringify({ message: "snapshot could not be stored", error: error instanceof Error ? error.message : String(error) }));
          return json({ error: "The snapshot could not be stored." }, 503);
        }
        return json({ synced: true, exportedAt: parsed.exportedAt });
      }

      if (url.pathname === "/api/actions" && request.method === "GET") {
        return json(await env.STUDIQUO_DATA.get(`actions:${key}`, "json") ?? []);
      }

      if (url.pathname === "/api/actions" && request.method === "DELETE") {
        await env.STUDIQUO_DATA.delete(`actions:${key}`);
        return json({ cleared: true });
      }

      // The plan the app should act on. The app can see purchases through
      // RevenueCat but not the server-only legacy-account grant, so it asks
      // here; `paywallRequired` stays false until PAYWALL_ENABLED is set.
      if (url.pathname === "/api/plan" && request.method === "GET") {
        const plan = session ? await getPlan(env, [session.sub, session.originalSub]) : "standard";
        return json({ plan, paywallRequired: paywallEnabled(env) });
      }

      // AI proxy (Gemini/Anthropic/OpenAI, gated and rate-limited by plan).
      // Deliberately not gated on a synced snapshot the way /mcp is — the AI
      // features work on a fresh install, before the user has ever run a
      // sync. The plan is resolved here, once, right before the one route
      // that needs it — not for every /api/* request above — since it costs
      // a D1 read (entitlements.js's getPlan) that every other route here
      // has no use for.
      if (url.pathname.startsWith("/api/ai/")) {
        // Cheapest refusals first, so that none of them costs a body read: the
        // per-account request budget, then an account with no plan to spend.
        if (request.method === "POST") {
          const account = await accountCounterKey(session?.sub, key);
          if (!(await env.RATE_COUNTER.getByName(`ai-request:${account}`).bump(AI_REQUESTS_PER_MINUTE, 60))) return tooManyRequests();
        }
        const plan = session ? await getPlan(env, [session.sub, session.originalSub]) : "standard";
        const subscriptionRequired = subscriptionRequiredResponse(plan, url, request);
        if (subscriptionRequired) return subscriptionRequired;
        const privacyFailure = await aiPrivacyRejection(request, env);
        if (privacyFailure) return privacyFailure;
        const ai = await handleAI(url, request, env, key, ctx, session, plan);
        if (ai) return ai;
      }

      // A room's members are recorded by account, not by session: the token's
      // hash changes on every sign-in, and invitations are addressed to the
      // friend code's account key (the same key chat uses).
      // Resolved only for these routes: it is a Durable Object call.
      // Turning chat off for someone turns off sharing documents with friends too.
      if (url.pathname.startsWith("/api/document/") && session && await hasModerationMark(env, session, CHAT_SUSPENSION_PREFIX)) {
        return json({ error: "Chat is unavailable for this account.", code: "chat_suspended" }, 403);
      }
      const documentUserKey = url.pathname.startsWith("/api/document/") ? await resolveChatUserKey(env, session?.sub, key) : key;
      const documentCollab = await handleDocumentCollab(url, request, env, documentUserKey, ctx);
      if (documentCollab) return documentCollab;

      return json({ error: "Not found" }, 404);
    }

      return json({ error: "Not found" }, 404);
    } catch (error) {
      console.error(JSON.stringify({ message: "request failed", error: error instanceof Error ? error.message : String(error) }));
      return json({ error: "Internal server error." }, 500);
    }
  }
};

/**
 * Exchanges a still-valid token for a new one that starts a fresh 90 days, so
 * a person who keeps using the app is not signed out on the day the original
 * token turns 90. The new token belongs to the same identity the old session
 * was minted for (not the canonical account it resolves to), and the old token
 * is left to expire on its own: revoking it here would sign the person out if
 * the response were lost before the app stored the new token.
 *
 * The synced snapshot and queued actions are kept under a hash of the token,
 * so they are copied to the new token; without that, the MCP endpoint would
 * answer "run sync" until the app next synced. A client that was given the old
 * token by hand keeps working until that token expires, but sees no newer
 * syncs, which the app now makes under the new token.
 *
 * Each token can be exchanged once, and afterwards it only lives for
 * REFRESH_OLD_TOKEN_GRACE_SECONDS more: long enough to recover when the
 * response was lost, short enough that a token the person has since replaced
 * (and signed out of) does not stay usable for months. Without the one-time
 * mark a single token could mint tokens without limit, each with its own
 * per-token AI quota.
 *
 * The login is sliding: whoever holds a valid token can keep exchanging it, and
 * resetting the password or deleting the account ends every session. There is
 * deliberately no absolute lifetime.
 */
const REFRESH_MIN_AGE_SECONDS = 7 * 24 * 60 * 60;
// A login that is exchanged again and again used to last for ever. Each new
// token now remembers when the login it descends from began, and a login older
// than this is no longer renewed: the token it holds runs out (at most 90 days
// later) and the person signs in again. Adjustable with SESSION_MAX_DAYS.
const DEFAULT_SESSION_MAX_DAYS = 365;
const REFRESH_OLD_TOKEN_GRACE_SECONDS = 14 * 24 * 60 * 60;

async function handleSessionRefresh(request, env, token, session) {
  if (!session) return json({ error: "Sign in again." }, 401);
  const parsed = await readJSONLimited(request, 1_000);
  const issuedAt = Number(token.slice(0, token.indexOf(".")));
  if (Date.now() / 1000 - issuedAt < REFRESH_MIN_AGE_SECONDS) return json({ refreshed: false });
  const oldKey = await sha256Hex(token);
  if (await env.STUDIQUO_DATA.get(`session-refreshed:${oldKey}`)) return json({ refreshed: false });
  const originMs = session.originIssuedAtMs ?? session.issuedAtMs ?? issuedAt * 1000;
  const maxDays = Number(env.SESSION_MAX_DAYS) > 0 ? Number(env.SESSION_MAX_DAYS) : DEFAULT_SESSION_MAX_DAYS;
  if (Date.now() - originMs > maxDays * 24 * 60 * 60 * 1000) return json({ refreshed: false, reason: "session_too_old" });
  const refreshed = await mintSession(env, session.originalSub ?? session.sub, undefined, { originIssuedAtMs: originMs });
  if (!refreshed) return json({ error: "Signing in is not available for this account right now." }, 400);
  const newKey = await sha256Hex(refreshed);
  const oldRemaining = remainingValiditySeconds(token);
  await env.STUDIQUO_DATA.put(`session-refreshed:${oldKey}`, "1", { expirationTtl: oldRemaining });
  const oldSession = await env.STUDIQUO_DATA.get(`session:${oldKey}`);
  if (oldSession) {
    await env.STUDIQUO_DATA.put(`session:${oldKey}`, oldSession, { expirationTtl: Math.min(oldRemaining, REFRESH_OLD_TOKEN_GRACE_SECONDS) });
  }
  const ttl = remainingValiditySeconds(refreshed);
  for (const prefix of ["snapshot", "actions"]) {
    const value = await env.STUDIQUO_DATA.get(`${prefix}:${oldKey}`);
    if (value) await env.STUDIQUO_DATA.put(`${prefix}:${newKey}`, value, { expirationTtl: ttl });
  }
  return json({ refreshed: true, token: refreshed });
}

// POST /api/auth/apple: exchanges a Sign in with Apple identityToken for a
// studiquo bearer token, in the same "<issued-at epoch>.<random>" format
// token.js already expects everywhere else.
async function handleAppleSignIn(request, env, ctx) {
  const allowed = await checkRateLimit(env.RATE_LIMIT_APPLE_AUTH, clientKey(request));
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

  const { identityToken, nonce } = parsed ?? {};
  if (typeof identityToken !== "string" || !identityToken) {
    return json({ error: "identityToken is required." }, 400);
  }

  let payload;
  try {
    payload = await verifyAppleIdentityToken(identityToken, env);
  } catch {
    return json({ error: "Invalid Apple identity token." }, 401);
  }
  // The token must have been made for this very sign-in (id-token-nonce.js).
  if (await idTokenNonceRefused(env, payload, nonce, "apple")) return json({ error: "Invalid Apple identity token." }, 401);

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
      emailVerified,
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
  let identityKey = sub;
  const accountEmail = email ?? existingAccount?.email;
  const accountEmailVerified = email ? emailVerified : existingAccount?.emailVerified === true;
  const accountUsesPrivateRelay = email ? emailIsPrivateRelay : existingAccount?.emailIsPrivateRelay === true;
  if (accountEmail && accountEmailVerified && !accountUsesPrivateRelay) {
    const link = await linkVerifiedEmail(env, {
      provider: "apple", sub, email: accountEmail, emailVerified: true,
    });
    identityKey = link.canonicalIdentityKey ?? identityKey;
  }

  // An account with a passkey signs in with that instead (passkey-policy.js).
  const passkeyGate = await gatePasskeyAccount(env, identityKey, accountEmail && accountEmailVerified && !accountUsesPrivateRelay ? accountEmail : null, { notify: work => inBackground(ctx, work) });
  if (passkeyGate) return passkeyGate;
  const token = await mintSession(env, identityKey);
  if (!token) return json({ error: "Signing in is not available for this account right now." }, 400);
  return json({ token });
}

// POST /api/auth/google: exchanges a Google Sign-In idToken for a studiquo
// bearer token. Mirrors handleAppleSignIn above — same token format, same
// rate-limit shape, same account-record pattern — except Google resends
// `email`/`email_verified` on every sign-in (not just the first), so those
// are refreshed each time rather than written once.
async function handleGoogleSignIn(request, env, ctx) {
  const allowed = await checkRateLimit(env.RATE_LIMIT_GOOGLE_AUTH, clientKey(request));
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

  const { idToken, nonce } = parsed ?? {};
  if (typeof idToken !== "string" || !idToken) {
    return json({ error: "idToken is required." }, 400);
  }

  let payload;
  try {
    payload = await verifyGoogleIdentityToken(idToken, env);
  } catch {
    return json({ error: "Invalid Google identity token." }, 401);
  }
  if (await idTokenNonceRefused(env, payload, nonce, "google")) return json({ error: "Invalid Google identity token." }, 401);

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
  let identityKey = `google:${sub}`;
  if (email) {
    const link = await linkVerifiedEmail(env, { provider: "google", sub, email, emailVerified });
    identityKey = link.canonicalIdentityKey ?? identityKey;
  }

  // An account with a passkey signs in with that instead (passkey-policy.js).
  const passkeyGate = await gatePasskeyAccount(env, identityKey, email && emailVerified ? email : null, { notify: work => inBackground(ctx, work) });
  if (passkeyGate) return passkeyGate;
  const token = await mintSession(env, identityKey);
  if (!token) return json({ error: "Signing in is not available for this account right now." }, 400);

  return json({ token });
}

// Per-email budget for the two email-code endpoints. The per-IP Cloudflare
// limits above only slow one address down; a botnet can still spread
// guesses at one mailbox across many IPs, and every send-code call hands
// out a fresh code with a fresh attempt count (email-verification.js), so
// resending alone would otherwise reset the guessing budget indefinitely.
// This counts per address no matter which IP asks, and is deliberately a
// fixed window (it starts at the first attempt, per RateCounter) rather than
// a lockout: it clears itself after an hour, so it never leaves a victim's
// login blocked indefinitely. The cost is that someone who knows the
// address can burn its budget to stall that address's signup / password
// reset for the rest of the window.
const EMAIL_CODE_WINDOW_SECONDS = 3_600;
const EMAIL_SEND_LIMIT_PER_WINDOW = 5;
const EMAIL_CONFIRM_LIMIT_PER_WINDOW = 10;

async function withinEmailCodeBudget(env, action, email, limit) {
  const emailHash = await sha256Hex(email.trim().toLowerCase());
  return env.RATE_COUNTER.getByName(`email-code-${action}:${emailHash}`).bump(limit, EMAIL_CODE_WINDOW_SECONDS);
}

// Monitoring must never delay or fail a sign-in: run it after the response
// where the runtime allows, and in any case swallow its errors.
function inBackground(ctx, work) {
  if (typeof ctx?.waitUntil === "function") ctx.waitUntil(work);
  return work;
}

// POST /api/auth/email/send-code: emails a 6-digit verification code to the
// address a local email/password account was just created (or is being
// re-verified) with. Doesn't authenticate anything itself — it only proves
// the caller can read mail at that address, which is what lets
// confirm-code below link it alongside any Apple/Google account sharing it.
async function handleSendEmailVerification(request, env) {
  const allowed = await checkRateLimit(env.RATE_LIMIT_EMAIL_VERIFY_SEND, clientKey(request));
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

  if (!(await withinEmailCodeBudget(env, "send", email, EMAIL_SEND_LIMIT_PER_WINDOW))) {
    return json({ error: "Too many attempts. Please try again later." }, 429);
  }

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
// own exchange. `password` is required for this reason:
// this is the only place a local account's password is ever set.
async function handleConfirmEmailVerification(request, env, ctx) {
  const allowed = await checkRateLimit(env.RATE_LIMIT_EMAIL_VERIFY_CONFIRM, clientKey(request));
  if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);

  const body = await readTextLimited(request, 2_000);
  if (body == null) return json({ error: "Request body is too large." }, 413);
  let parsed;
  try {
    parsed = JSON.parse(body);
  } catch {
    return json({ error: "Invalid JSON." }, 400);
  }

  const { email, code, password } = parsed ?? {};
  if (typeof email !== "string" || !email) return json({ error: "email is required." }, 400);
  if (typeof code !== "string" || !code) return json({ error: "code is required." }, 400);
  if (typeof password !== "string" || password.length < 8 || password.length > 1_024) {
    return json({ error: "password is required." }, 400);
  }

  // Checked before the code is: a refused password costs the caller no code
  // attempt and leaves the emailed code valid, so they can just pick another.
  // Only the password's SHA-1 prefix goes to HIBP (pwned-passwords.js).
  if (await isBreachedPassword(password, typeof env.PWNED_PASSWORDS_FETCH === "function" ? env.PWNED_PASSWORDS_FETCH : fetch)) {
    return json({
      error: "このパスワードは過去の情報漏えいで見つかっています。別のパスワードを設定してください。",
      code: "password_breached",
    }, 400);
  }

  // Counts every attempt, correct or not, and runs before the code is
  // checked: once spent, even the right code is refused, so the budget can't
  // be probed past its limit.
  if (!(await withinEmailCodeBudget(env, "confirm", email, EMAIL_CONFIRM_LIMIT_PER_WINDOW))) {
    return json({ error: "Too many attempts. Please try again later." }, 429);
  }

  const result = await confirmVerificationCode(env, email, code);
  if (!result.verified) return json({ error: "Incorrect or expired code.", attemptsRemaining: result.attemptsRemaining }, 401);

  let normalizedEmail;
  let replacedPassword;
  try {
    normalizedEmail = email.trim().toLowerCase();
    // A password that already existed is being replaced: a reset. Adding the
    // first one to an account that signs in another way is not.
    replacedPassword = (await env.STUDIQUO_DATA.get(`account:local:${normalizedEmail}`)) !== null;
  } catch {
    return json({ error: "Could not save the account." }, 400);
  }

  const link = await linkVerifiedEmail(env, {
    provider: "email", sub: normalizedEmail, email: normalizedEmail, emailVerified: true,
  });
  const accountKey = link.canonicalIdentityKey ?? `email:${normalizedEmail}`;
  // An account with a passkey does not accept a code that could have been
  // relayed by a look-alike site, neither to sign in nor to reset the password
  // (which would sign in): checked before anything is changed.
  const passkeyGate = await gatePasskeyAccount(env, accountKey, normalizedEmail, { notify: work => inBackground(ctx, work) });
  if (passkeyGate) return passkeyGate;
  // A passkey registered for any address of this account signs in as the
  // account, so all of them go with a reset (see revokePasskeysForAccount).
  const accountEmails = [normalizedEmail, ...(link.linkedIdentities ?? []).map(identityKey).filter(key => key.startsWith("email:")).map(key => key.slice("email:".length))];
  // Nothing is stored for an account whose deletion is still running: the
  // password would be saved and then the sign-in below refused with a message
  // that says nothing about why. Say so, before anything changes.
  if (await accountIsBeingDeleted(env, accountKey)) {
    return json({ error: "このアカウントは削除の処理中です。しばらくしてからもう一度お試しください。", code: "account_deleting" }, 409);
  }
  if (replacedPassword) {
    // A reset signs out whoever held the old password — the new session below
    // is minted after the cut-off — and so disconnects the apps (MCP) they
    // may have connected, which hold their own tokens (an app approved before
    // sign-in methods were linked sits under one of the linked identities).
    //
    // This happens BEFORE the new password is stored. If it cannot be
    // completed the request fails and nothing has changed: the old password
    // still works, so the owner simply asks for a new code. Done after, a
    // failure here would leave the new password in place while the stolen
    // session (the very thing a reset is for) stayed alive.
    // The steps run in order (sign-out, apps, passkeys); one that fails stops the
    // reset, but the ones before it have been done and stay done.
    try {
      await revokeSessionsIssuedBefore(env, accountKey);
      await revokeAllConnections(env, [accountKey, ...(link.linkedIdentities ?? []).map(identityKey)]);
      await revokePasskeysForAccount(env, { accountKey, emails: accountEmails });
    } catch {
      return json({ error: "Could not complete the password reset. Please try again." }, 503);
    }
  }
  try {
    await upsertLocalAccount(env, normalizedEmail, password);
  } catch {
    // Not a problem with the request (its password was validated above): the
    // store was busy or unavailable. Retryable, so not a 400.
    return json({ error: "Could not save the account. Please try again." }, 503);
  }
  if (replacedPassword) {
    // Storing the password takes a while (a deliberately slow hash). Someone
    // who still knew the OLD password could have signed in during it, after the
    // first cut-off but before the old password stopped working, and would
    // otherwise keep that session. A second pass now that the old password is
    // gone closes that window. Best effort: the first pass already did the
    // work that must not be skipped.
    try {
      await revokeSessionsIssuedBefore(env, accountKey);
      await revokeAllConnections(env, [accountKey, ...(link.linkedIdentities ?? []).map(identityKey)]);
    } catch {
      console.warn("password reset: second sign-out pass failed");
    }
    // Passkeys are removed on their own, and tried a few times: unlike a
    // session, one does not expire, so a pass that only the sessions' failure
    // skipped would leave a way in that lasts. This is the pass that removes a
    // passkey registered while the new password was being stored.
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        await revokePasskeysForAccount(env, { accountKey, emails: accountEmails });
        break;
      } catch {
        if (attempt === 3) console.warn("password reset: second passkey pass failed");
      }
    }
  }
  const token = await mintSession(env, accountKey);
  if (!token) return json({ error: "Signing in is not available for this account right now." }, 400);
  // The owner just proved they hold this mailbox from here, so this is the
  // baseline context: remember it without sending a notice.
  inBackground(ctx, noteSignInContext(env, request, normalizedEmail, { notify: false }));
  return json({ verified: true, token });
}

// POST /api/auth/local/login: verifies an email/password against the hash
// upsertLocalAccount stored, and mints a real session on success — the
// server-side counterpart to what AuthenticationStore.login() used to check
// entirely on-device. Rate-limited per IP like every other unauthenticated
// exchange endpoint, plus an escalating wait (never a hard lock) keyed by
// account, IP+account and ASN so a distributed credential-stuffing run
// can't just rotate IPs.
async function handleLocalLogin(request, env, ctx) {
  const allowed = await checkRateLimit(env.RATE_LIMIT_LOCAL_LOGIN, clientKey(request));
  if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);

  const body = await readTextLimited(request, 2_000);
  if (body == null) return json({ error: "Request body is too large." }, 413);
  let parsed;
  try {
    parsed = JSON.parse(body);
  } catch {
    return json({ error: "Invalid JSON." }, 400);
  }

  const { email, password } = parsed ?? {};
  if (typeof email !== "string" || !email) return json({ error: "email is required." }, 400);
  if (typeof password !== "string" || !password) return json({ error: "password is required." }, 400);

  // Not a deliverable address: refuse without creating throttle state for it.
  if (email.length > 254) return json({ error: "メールアドレスまたはパスワードが違います。" }, 401);

  // Escalating wait per account / IP+account / ASN (login-throttle.js). The
  // attempt is counted before the password is checked, atomically with the
  // wait check, so a burst of parallel requests can't all get a guess in.
  // While a wait runs the password isn't checked at all, so a correct guess
  // can't get through mid-wait either.
  const attempt = await beginLoginAttempt(env, request, email);
  if (attempt.waitSeconds > 0) {
    inBackground(ctx, recordLoginOutcome(env, request, "throttled"));
    return Response.json(
      { error: "Too many attempts. Please try again later.", retryAfterSeconds: attempt.waitSeconds },
      { status: 429, headers: securityHeaders({ "retry-after": String(attempt.waitSeconds) }) }
    );
  }

  let verified;
  try {
    // A client already known to this account may use the reserved part of the
    // hashing queue, so a flood of unfamiliar sign-ins can't shut out the
    // people who are simply coming back from their usual network.
    // (Without the Cloudflare-set client address every request shares one
    // "unknown" client, which must never be treated as a known one.)
    verified = await verifyLocalAccount(env, email, password, { priority: attempt.trusted && clientKey(request) !== "unknown" });
  } catch (error) {
    if (!(error instanceof Argon2BusyError)) throw error;
    // The hashing queue is full: nothing was checked, so none of this counts
    // against the person (or the account), and they are asked to try again.
    // Best effort: failing to hand the attempt back must not turn a polite
    // "try again" into an error.
    try {
      await abandonLoginAttempt(attempt);
    } catch (refundError) {
      console.error(JSON.stringify({ message: "could not hand back a refused sign-in attempt", error: refundError instanceof Error ? refundError.message : String(refundError) }));
    }
    inBackground(ctx, recordLoginOutcome(env, request, "busy"));
    return Response.json(
      { error: "The server is busy. Please try again in a moment." },
      { status: 503, headers: securityHeaders({ "retry-after": "2" }) }
    );
  }
  if (!verified) {
    await finishLoginAttempt(attempt, false);
    inBackground(ctx, recordLoginOutcome(env, request, "failure"));
    return json({ error: "メールアドレスまたはパスワードが違います。" }, 401);
  }
  await finishLoginAttempt(attempt, true);

  const normalizedEmail = email.trim().toLowerCase();
  const link = await linkVerifiedEmail(env, {
    provider: "email", sub: normalizedEmail, email: normalizedEmail, emailVerified: true,
  });
  // The password was right, but a password can be relayed by a look-alike
  // site: an account with a passkey signs in with that instead.
  const passkeyGate = await gatePasskeyAccount(env, link.canonicalIdentityKey ?? `email:${normalizedEmail}`, normalizedEmail, { notify: work => inBackground(ctx, work) });
  if (passkeyGate) return passkeyGate;
  const token = await mintSession(env, link.canonicalIdentityKey ?? `email:${normalizedEmail}`);
  if (!token) return json({ error: "Signing in is not available for this account right now." }, 400);
  // A sign-in from a country+network this account hasn't used lately emails
  // the owner (login-monitor.js); the outcome also feeds the spike alerts.
  inBackground(ctx, (async () => {
    const { newContext, firstSeen } = await noteSignInContext(env, request, normalizedEmail, { notify: true });
    await recordLoginOutcome(env, request, "success", { newContext, firstSeen });
  })());
  return json({ token });
}

// Every response gets the transport headers, and plain-http requests are answered
// before the handler reads anything (transport.js).
export default {
  ...handler,
  async fetch(request, env, ctx) {
    const plain = plainHttpResponse(request, new URL(request.url));
    if (plain) return plain;
    return withTransportHeaders(await handler.fetch(request, env, ctx));
  },
};
