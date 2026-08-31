import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import * as z from "zod/v4";
import { handleAI } from "./ai.js";
import { associationFile, handlePasskeys } from "./passkeys.js";
import { handleChat } from "./chat.js";
export { ChatRoom } from "./chat-room.js";

function json(value, status = 200) {
  return Response.json(value, { status, headers: securityHeaders() });
}

function securityHeaders(extra = {}) {
  return {
    "cache-control": "no-store",
    "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
    "referrer-policy": "no-referrer",
    "x-content-type-options": "nosniff",
    ...extra,
  };
}

function bearer(request) {
  const value = request.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(value);
  return match?.[1]?.trim() || null;
}

async function userKey(token) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
}

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
  const token = bearer(request);
  if (!token || token.length < 32 || token.length > 256) return json({ error: "A valid bearer token is required." }, 401);
  const key = await userKey(token);
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
      const token = bearer(request);
      if (!token || token.length < 32 || token.length > 256) return json({ error: "A valid bearer token is required." }, 401);
      const key = await userKey(token);

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

async function readTextLimited(request, maximumBytes) {
  if (!request.body) return "";
  const reader = request.body.getReader();
  const decoder = new TextDecoder();
  let received = 0;
  let result = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) return result + decoder.decode();
    received += value.byteLength;
    if (received > maximumBytes) {
      await reader.cancel();
      return null;
    }
    result += decoder.decode(value, { stream: true });
  }
}
