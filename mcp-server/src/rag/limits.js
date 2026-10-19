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
