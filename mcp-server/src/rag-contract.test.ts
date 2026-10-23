// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from "node:test";
import assert from "node:assert/strict";
import { retrieve } from "./rag/index.ts";
import { LIMITS, RELEVANCE, MODELS } from "./rag/limits.ts";
import { RAG_STATUSES, EMPTY_REASONS, EMPTY_DETAILS, emptyRetrieval, normalizeRetrieval } from "./rag/contract.ts";

const session = { sub: "contract-test-user" };
const bound = { RAG_ENABLED: "true", ADMIN_DB: {}, AI: {}, RAG_VECTORIZE: {},
  RATE_LIMIT_RAG_SEARCH: { limit: async () => ({ success: true }) } };

test("empty results keep the three-field shape and carry a log-only reason", async () => {
  const result = await retrieve({ RAG_ENABLED: "false" }, session, { query: "q" });
  assert.deepEqual(result, { context: "", citations: [] });
  assert.deepEqual(Object.keys(result), ["context", "citations"]);
  assert.equal(result.reason, "disabled");
  assert.ok(EMPTY_REASONS.includes(result.reason));
});

test("each empty result is a fresh object, so a caller's status never leaks", async () => {
  const a = await retrieve({ RAG_ENABLED: "false" }, session, { query: "q" });
  a.status = "fallback";
  const b = await retrieve({ RAG_ENABLED: "false" }, session, { query: "q" });
  assert.equal(b.status, undefined);
  assert.notEqual(a, b);
});

test("early exits report why", async () => {
  assert.equal((await retrieve({ RAG_ENABLED: "true" }, session, { query: "q" })).reason, "not_configured");
  assert.equal((await retrieve(bound, session, { query: "" })).reason, "invalid_query");
  assert.equal((await retrieve(bound, session, { query: "x".repeat(LIMITS.queryChars + 1) })).reason, "invalid_query");
  assert.equal((await retrieve(bound, session, { query: "q", rag: { scope: [] } })).reason, "invalid_scope");
  const limited = { ...bound, RATE_LIMIT_RAG_SEARCH: { limit: async () => ({ success: false }) } };
  assert.equal((await retrieve(limited, session, { query: "q" })).reason, "rate_limited");
});

test("a broken search path ends as an error reason and never throws", async () => {
  const result = await retrieve(bound, session, { query: "光合成の仕組み" });
  assert.equal(result.context, "");
  assert.deepEqual(result.citations, []);
  assert.ok(EMPTY_REASONS.includes(result.reason));
});

test("normalizeRetrieval enforces the contract shape", () => {
  for (const bad of [null, undefined, "x", {}, { context: 1, citations: [] }, { context: "", citations: null }]) {
    const fixed = normalizeRetrieval(bad);
    assert.equal(fixed.context, "");
    assert.deepEqual(fixed.citations, []);
    assert.equal(fixed.status, "fallback");
    assert.equal(fixed.reason, "error");
  }
  assert.equal(normalizeRetrieval({ context: "", citations: [] }).status, "fallback");
  assert.equal(normalizeRetrieval({ context: "", citations: [], status: "made-up" }).status, "fallback");
  for (const status of RAG_STATUSES) assert.equal(normalizeRetrieval({ context: "c", citations: [], status }).status, status);
  const kept = { context: "c", citations: [], status: "grounded" };
  Object.defineProperty(kept, "authorization", { value: { key: "k" } });
  assert.equal(normalizeRetrieval(kept), kept); // same object: revalidation still sees authorization
  assert.equal(kept.authorization.key, "k");
});

test("emptyRetrieval extra fields are enumerable, reason is not", () => {
  const r = emptyRetrieval("no_match", { status: "insufficient" });
  assert.deepEqual(Object.keys(r), ["context", "citations", "status"]);
  assert.equal(r.reason, "no_match");
});

// Changing a budget changes what the model sees. Update this table together
// with docs/RAG_PROMPT_CONTRACT.md and re-run the prompt comparison.
test("retrieval budgets match the documented contract", () => {
  assert.deepEqual({ ...LIMITS }, {
    queryChars: 4000, searchTopK: 20, fusedLimit: 120, candidateLimit: 15, referenceLimit: 5,
    excerptChars: 6000, contextChars: 24000, neighborRows: 3, reserveReads: 5,
    maxEmbeddingCalls: 3, maxRerankCalls: 1, retrievalTimeoutMs: 10000, rerankTimeoutMs: 2000, hydrateTimeoutMs: 2000,
    reserveReadTimeoutMs: 2000, finalAssemblyMs: 2200,
  });
  assert.deepEqual({ ...RELEVANCE }, {
    anchoredOverlap: 0.34, anchoredScore: 0.35, looseOverlap: 0.08, looseScore: 0.55,
    topRankScore: 0.72, topRank: 5,
  });
  assert.ok(Object.isFrozen(LIMITS) && Object.isFrozen(RELEVANCE));
});

// Cloudflare cannot pin these ids to a version. Changing one changes retrieval (and,
// for the embedding, the meaning of every stored vector), so it must be deliberate.
test("Workers AI model ids are named once and frozen", () => {
  assert.deepEqual({ ...MODELS }, { embedding: "@cf/baai/bge-m3", rerank: "@cf/baai/bge-reranker-base" });
  assert.ok(Object.isFrozen(MODELS));
});

test("emptyRetrieval can carry a log-only detail code that is not enumerable and not a free string", () => {
  const r = emptyRetrieval("no_match", { status: "insufficient" }, "no_candidates");
  assert.equal(r.detail, "no_candidates");
  assert.ok(EMPTY_DETAILS.includes(r.detail));
  assert.deepEqual(Object.keys(r), ["context", "citations", "status"]);
  assert.deepEqual({ ...r }, { context: "", citations: [], status: "insufficient" });
  assert.equal(emptyRetrieval("disabled").detail, undefined);
  assert.ok(Object.isFrozen(EMPTY_DETAILS));
});
