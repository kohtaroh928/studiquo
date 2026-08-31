#!/usr/bin/env node
import { readFile, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import * as z from "zod/v4";

const snapshotPath = resolve(process.env.STUDIQUO_SNAPSHOT ?? "./studiquo-mcp-snapshot.json");
const actionsPath = resolve(process.env.STUDIQUO_ACTIONS ?? "./studiquo-mcp-actions.json");

async function snapshot() {
  if (!existsSync(snapshotPath)) throw new Error(`Studiquo snapshot not found: ${snapshotPath}. Export or sync it from Studiquo first.`);
  return JSON.parse(await readFile(snapshotPath, "utf8"));
}

async function appendAction(action) {
  let actions = [];
  if (existsSync(actionsPath)) {
    try { actions = JSON.parse(await readFile(actionsPath, "utf8")); } catch { actions = []; }
  }
  actions.push(action);
  await writeFile(actionsPath, JSON.stringify(actions, null, 2), "utf8");
}

function result(value) {
  return {
    content: [{ type: "text", text: JSON.stringify(value, null, 2) }],
    structuredContent: { result: value }
  };
}

const server = new McpServer(
  { name: "studiquo", version: "0.2.0" },
  { instructions: "Read Studiquo study data. Write tools only queue changes; the user imports them in Studiquo." }
);

server.registerTool("list_notebooks", {
  description: "List Studiquo notebooks and pages.",
  inputSchema: z.object({})
}, async () => {
  const data = await snapshot();
  return result(data.notebooks.map(notebook => ({
    id: notebook.id,
    title: notebook.title,
    pageCount: notebook.pages.length,
    pages: notebook.pages.map(page => ({ id: page.id, title: page.title }))
  })));
});

server.registerTool("search_notes", {
  description: "Search titles and OCR-recognized text in Studiquo notes.",
  inputSchema: z.object({ query: z.string().min(1), limit: z.number().int().min(1).max(100).default(20) })
}, async ({ query, limit }) => {
  const data = await snapshot();
  const needle = query.toLocaleLowerCase("ja");
  const matches = data.notebooks
    .flatMap(notebook => notebook.pages.flatMap(page => {
      const haystack = `${notebook.title}\n${page.title}\n${page.recognizedText ?? ""}`.toLocaleLowerCase("ja");
      return haystack.includes(needle)
        ? [{ notebookId: notebook.id, notebookTitle: notebook.title, pageId: page.id, pageTitle: page.title, recognizedText: page.recognizedText ?? "" }]
        : [];
    }))
    .slice(0, limit);
  return result(matches);
});

server.registerTool("list_flashcard_decks", {
  description: "List Studiquo flashcard decks and cards.",
  inputSchema: z.object({ includeCards: z.boolean().default(false) })
}, async ({ includeCards }) => {
  const data = await snapshot();
  return result(data.flashcardDecks.map(deck => includeCards ? deck : ({ id: deck.id, title: deck.title, cardCount: deck.cards.length })));
});

server.registerTool("list_calendar_events", {
  description: "List Studiquo calendar events.",
  inputSchema: z.object({ limit: z.number().int().min(1).max(200).default(80) })
}, async ({ limit }) => {
  const data = await snapshot();
  return result((data.calendarEvents ?? []).slice(0, limit));
});

server.registerTool("create_flashcards", {
  description: "Queue a flashcard deck for user import into Studiquo.",
  inputSchema: z.object({
    deckTitle: z.string().min(1).max(100),
    cards: z.array(z.object({ question: z.string().min(1), answer: z.string().min(1) })).min(1).max(200)
  })
}, async ({ deckTitle, cards }) => {
  await appendAction({ type: "create_flashcards", deckTitle, cards });
  return result({ queued: true, actionsPath, deckTitle, cardCount: cards.length });
});

server.registerTool("add_calendar_event", {
  description: "Queue a calendar event for user import into Studiquo. Dates must be ISO 8601.",
  inputSchema: z.object({
    title: z.string().min(1).max(150),
    startDate: z.iso.datetime(),
    endDate: z.iso.datetime(),
    kind: z.enum(["test", "classLesson", "other"]).default("other"),
    notes: z.string().max(2000).default("")
  })
}, async input => {
  await appendAction({ type: "add_calendar_event", ...input });
  return result({ queued: true, actionsPath, title: input.title });
});

await server.connect(new StdioServerTransport());
console.error(`Studiquo MCP ready. Snapshot: ${snapshotPath}`);
