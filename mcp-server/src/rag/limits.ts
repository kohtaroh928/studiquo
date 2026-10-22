// Every retrieval budget in one place. Values are unchanged from the earlier
// inline literals; this file only names them. Sizes are UTF-16 code units
// (JavaScript string length), not tokens. docs/RAG_PROMPT_CONTRACT.md lists them.
export const LIMITS = Object.freeze({
  queryChars: 4000,           // longest accepted question
  searchTopK: 20,             // hits per branch (vector, keyword)
  fusedLimit: 120,            // RRF output kept before diversity selection
  candidateLimit: 15,         // candidates sent to the reranker
  referenceLimit: 5,          // excerpts shown to the model
  excerptChars: 6000,         // one excerpt (page-local neighbors joined)
  contextChars: 24000,        // all excerpts together
  neighborRows: 3,            // chunk plus its previous/next neighbor
  reserveReads: 5,            // extra page reads for missing evidence
  maxEmbeddingCalls: 3,       // Workers AI embeddings per question (one per search query)
  maxRerankCalls: 1,          // Workers AI reranks per question
  retrievalTimeoutMs: 10000,  // whole retrieval
  rerankTimeoutMs: 2000,
  hydrateTimeoutMs: 2000,
  reserveReadTimeoutMs: 2000,
  finalAssemblyMs: 2200,      // time that must remain before a reserve read
});

// Vector-score and lexical-overlap cut-offs that decide whether a candidate
// is relevant at all (see relevanceEvidence).
export const RELEVANCE = Object.freeze({
  anchoredOverlap: 0.34, anchoredScore: 0.35,
  looseOverlap: 0.08, looseScore: 0.55,
  topRankScore: 0.72, topRank: 5,
});

// The answerability judge (rag/judge.ts, docs/RAG_SEMANTIC_JUDGE_DESIGN.md). One extra Workers AI call after the
// excerpts are final. `RAG_JUDGE` is off by default; thresholds are provisional, from a probe that was not held out.
export const JUDGE = Object.freeze({
  model: "@cf/cloudflare/clef-flash",  // Cloudflare's decision model: returns a probability, never free text
  calls: 1,                            // judge calls per question
  timeoutMs: 2000,                     // same as the reranker
  minRemainingMs: 3000,                // skip when less time than this is left in the retrieval budget
  excerptChars: 3000,                  // one excerpt sent to the judge
  totalChars: 9000,                    // all excerpts sent to the judge (the model reads ~24k tokens)
  stopBelow: 0.25,                     // single-subject question: no excerpt is shown below this probability
  partialBelow: 0.5,                   // below this the answer is marked partial (comparisons never go further)
});

// Workers AI models. Cloudflare serves these ids without a version, so a silent change
// on its side cannot be pinned here; the ids are named once, frozen by a test, and the
// embedding id is part of every stored vector's meaning (a change needs a re-index).
export const MODELS = Object.freeze({
  embedding: "@cf/baai/bge-m3",
  rerank: "@cf/baai/bge-reranker-base",
});
