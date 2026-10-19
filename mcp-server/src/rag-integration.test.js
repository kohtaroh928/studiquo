import assert from "node:assert/strict";
import test from "node:test";
import { handleAI } from "./ai.js";
import worker from "./app.js";
import { sha256Hex } from "./auth.js";

test('missing requested detail emits insufficient without reference data; supported detail retains citation', async () => {
 const original = globalThis.fetch;
 const requests = [];
 globalThis.fetch = async (_url, options) => {
  requests.push(JSON.parse(options.body));
  return new Response('data: {"type":"response.output_text.delta","delta":"synthetic answer"}\n\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n');
 };
 try {
  for (const [text,expected] of [['電流計は直列につなぐ。','insufficient'],['電流計の価格は5000円。','grounded']]) {
   const environment = env(qualityEnvironment());
   await indexSource(environment,await accountKey('canonical-owner'),qualitySource({pages:[{pageNumber:1,text}]}));
   const result=await chat(environment,{messages:[{role:'user',text:'電流計の価格を教えて'}],rag:{scope:{kind:'library'}}},{'X-Studiquo-RAG-Consent':'rag-openai-v1'});
   const events=result.text.split('\n').filter(l=>l.startsWith('data:')).map(l=>JSON.parse(l.slice(5)));
   assert.equal(events[0].ragStatus,expected);
   const system=JSON.stringify(requests.at(-1).instructions);
   if(expected==='insufficient') {
    assert.ok(!events.some(e=>e.citations?.length));
    assert.doesNotMatch(system,/untrustedReferences|電流計は直列/);
    assert.match(system,/requested information in the retrieved excerpts/);
    assert.match(system,/not claim that the information is absent from the entire library/);
   } else {
    assert.equal(events.find(e=>e.citations)?.citations.length,1);
    assert.match(system,/5000円/);
   }
   assert.ok(events.some(e=>e.text==='synthetic answer'));
  }
 } finally { globalThis.fetch=original; }
});
function env(overrides = {}) {
  const values = new Map();
  return {
    OPENAI_LUNA_MODEL: "gpt-test-luna", AI_MODERATION: "off", OPENAI_API_KEY: "test-placeholder",
    STUDIQUO_DATA: {
      async get(k, type) {
        const v = values.get(k);
        return type === "json" && v ? JSON.parse(v) : (v ?? null);
      },
      async put(k, v) {
        values.set(k, v);
      },
    },
    RATE_COUNTER: {
      getByName() {
        return {
          async bump() { return true; },
          async take() { return {ok:true, windowEndsAt:1}; },
          async give() {},
        };
      },
    },
    ...overrides,
  };
}
async function chat(environment, body, headers = {}, plan = "standard") {
  const pending = [];
  const req = new Request("https://example.test/api/ai/chat", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
  const response = await handleAI(
    new URL(req.url),
    req,
    environment,
    "test-device",
    {
      waitUntil(p) {
        pending.push(p);
      },
    },
    { sub: "canonical-owner" },
    plan,
  );
  const text = await response.text();
  await Promise.all(pending);
  return { response, text };
}
test("RAG disabled preserves exact ordinary OpenAI request and SSE despite new client fields", async () => {
  const original = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async (_url, options) => {
    requests.push(JSON.parse(options.body));
    return new Response(
      'data: {"type":"response.output_text.delta","delta":"answer"}\n\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n',
    );
  };
  try {
    const environment = env({
      RAG_ENABLED: "false",
      AI: {
        run() {
          throw new Error("must not embed");
        },
      },
      RAG_VECTORIZE: {
        query() {
          throw new Error("must not search");
        },
      },
    });
    const ordinary = {
      messages: [{ role: "user", text: "日本史を説明して" }],
      noteContext: "selected material",
    };
    const a = await chat(environment, ordinary);
    const b = await chat(
      environment,
      { ...ordinary, rag: { scope: { kind: "library" } } },
      { "X-Studiquo-RAG-Consent": "rag-openai-v1" },
    );
    assert.deepEqual(requests[0], requests[1]);
    assert.equal(a.text, b.text);
    assert.equal(b.response.status, 200);
    assert.equal(b.text, 'data: {"text":"answer"}\n\n');
  } finally {
    globalThis.fetch = original;
  }
});
test("RAG enabled outage or missing consent falls back to ordinary chat without leaking error text", async () => {
  const original = globalThis.fetch;
  let count = 0;
  globalThis.fetch = async () => {
    count++;
    return new Response(
      'data: {"type":"response.output_text.delta","delta":"ordinary answer"}\n\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n',
    );
  };
  try {
    const environment = env({
      RAG_ENABLED: "true",
      ADMIN_DB: {
        prepare() {
          throw new Error("private document body");
        },
      },
      AI: {
        async run() {
          throw new Error("private prompt");
        },
      },
      RAG_VECTORIZE: {},
      RATE_LIMIT_RAG_SEARCH: {
        async limit() {
          return { success: true };
        },
      },
    });
    for (const headers of [{}, { "X-Studiquo-RAG-Consent": "rag-openai-v1" }]) {
      const result = await chat(
        environment,
        {
          messages: [{ role: "user", text: "explain chemistry" }],
          rag: { scope: { kind: "library" } },
        },
        headers,
      );
      assert.equal(result.response.status, 200);
      assert.match(result.text, /ordinary answer/);
      assert.doesNotMatch(result.text, /private|citations/);
    }
    assert.equal(count, 2);
  } finally {
    globalThis.fetch = original;
  }
});
async function signedEnv(overrides = {}) {
  const environment = env(overrides);
  const token = `${Math.floor(Date.now() / 1000)}.${"x".repeat(40)}`;
  await environment.STUDIQUO_DATA.put(
    `session:${await sha256Hex(token)}`,
    JSON.stringify({ sub: "alias-owner" }),
  );
  await environment.STUDIQUO_DATA.put(
    "identity-canonical:alias-owner",
    "canonical-owner",
  );
  return { environment, token };
}
test("RAG routes reject fabricated bearer and require separate storage consent", async () => {
  const { environment, token } = await signedEnv({
    RAG_ENABLED: "true",
    AI_PROVIDER_APPROVED: "true",
  });
  const make = (bearer) =>
    new Request("https://example.test/api/rag/index", {
      method: "POST",
      headers: { authorization: `Bearer ${bearer}` },
      body: JSON.stringify({ accountId: "other-owner" }),
    });
  assert.equal(
    (await worker.fetch(make(token + "fake"), environment, { waitUntil() {} }))
      .status,
    401,
  );
  assert.equal(
    (await worker.fetch(make(token), environment, { waitUntil() {} })).status,
    403,
  );
});
test("disabled status is authenticated and does not access RAG bindings", async () => {
  const { environment, token } = await signedEnv({
    RAG_ENABLED: "false",
    ADMIN_DB: {
      prepare() {
        throw new Error("should not read");
      },
    },
  });
  const response = await worker.fetch(
    new Request("https://example.test/api/rag/status", {
      headers: { authorization: `Bearer ${token}` },
    }),
    environment,
    { waitUntil() {} },
  );
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { enabled: false, sources: [] });
});

test("canonical chat adds retrieved context to OpenAI and emits exact structured citation", async () => {
  const { DatabaseSync } = await import("node:sqlite");
  const { readFileSync } = await import("node:fs");
  const { indexSource, accountKey } = await import("./rag/storage.js");
  const db = new DatabaseSync(":memory:");
  db.exec(
    readFileSync(
      new URL("../migrations/0006_rag.sql", import.meta.url),
      "utf8",
    ),
  );

  db.exec(readFileSync(new URL("../migrations/0007_rag_context.sql", import.meta.url), "utf8"));  const prepare = (sql, args = []) => ({
    bind(...next) {
      return prepare(sql, next);
    },
    async first() {
      return db.prepare(sql).get(...args) ?? null;
    },
    async all() {
      return { results: db.prepare(sql).all(...args) };
    },
    async run() {
      return { meta: db.prepare(sql).run(...args) };
    },
  });
  const vectors = new Map();
  const environment = env({
    RAG_ENABLED: "true",
    ADMIN_DB: {
      prepare,
      async batch(statements) {
        const result = [];
        for (const statement of statements) result.push(await statement.run());
        return result;
      },
    },
    AI: {
      async run(model, input) {
        return model.includes("reranker")
          ? { response: input.contexts.map((_, id) => ({ id, score: 1 })) }
          : { data: input.text.map(() => Array(1024).fill(0.1)) };
      },
    },
    RAG_VECTORIZE: {
      async upsert(items) {
        for (const item of items) vectors.set(item.id, item);
      },
      async deleteByIds(ids) {
        for (const id of ids) vectors.delete(id);
      },
      async query(_, options) {
        assert.equal(
          options.filter.accountKey,
          await accountKey("canonical-owner"),
        );
        assert.equal(options.filter.pageNumber, 2);
        return {
          matches: [...vectors.values()]
            .filter((v) => v.metadata.pageNumber === 2)
            .map((v) => ({ id: v.id })),
        };
      },
    },
    RATE_LIMIT_RAG_SEARCH: {
      async limit() {
        return { success: true };
      },
    },
  });
  await indexSource(environment, await accountKey("canonical-owner"), {
    sourceId: "source-fixture",
    title: "Synthetic biology",
    kind: "notebook",
    sourceHash: "c".repeat(64),
    totalPages: 2,
    pages: [
      { pageNumber: 1, text: "別のページ" },
      { pageNumber: 2, text: "細胞の構造。Synthetic biology reference." },
    ],
  });
  const original = globalThis.fetch;
  let gemini;
  globalThis.fetch = async (_url, options) => {
    gemini = JSON.parse(options.body);
    return new Response(
      'data: {"type":"response.output_text.delta","delta":"answer"}\n\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n',
    );
  };
  try {
    const result = await chat(
      environment,
      {
        accountId: "attacker-requested-owner",
        messages: [{ role: "user", text: "細胞" }],
        rag: {
          scope: { kind: "page", sourceId: "source-fixture", pageNumber: 2 },
        },
      },
      { "X-Studiquo-RAG-Consent": "rag-openai-v1" },
    );
    const events = result.text
      .split("\n")
      .filter((l) => l.startsWith("data:"))
      .map((l) => JSON.parse(l.slice(5)));
    assert.equal(events[0].ragStatus, "grounded");
    const citationEvent = events.find(e => e.citations);
    assert.equal(citationEvent.citations.length, 1);
    assert.deepEqual(citationEvent.citations[0], {
      sourceId: "source-fixture",
      title: "Synthetic biology",
      pageNumber: 2,
      chunkId: [...vectors.values()].find((v) => v.metadata.pageNumber === 2)
        .id,
    });
    assert.equal(events.find(e => e.text)?.text, "answer");
    assert.match(JSON.stringify(gemini.instructions), /UNTRUSTED/);
    assert.match(
      JSON.stringify(gemini.instructions),
      /Synthetic biology reference/,
    );
    assert.doesNotMatch(
      JSON.stringify(gemini.instructions),
      /別のページ|attacker-requested-owner/,
    );
  } finally {
    globalThis.fetch = original;
    db.close();
  }
});


test("unsupported provider selection is rejected before retrieval", async () => {
  const original = globalThis.fetch;
  let retrieved = 0;
  const requests = [];
  globalThis.fetch = async (_url, options) => {
    requests.push(JSON.parse(options.body));
    return new Response('data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"answer"}}\n\n');
  };
  try {
    const environment = env({
      RAG_ENABLED: "true", ANTHROPIC_API_KEY: "test-placeholder",
      AI: { run() { retrieved++; throw new Error("must not embed"); } },
      ADMIN_DB: { prepare() { retrieved++; throw new Error("must not search"); } },
      RAG_VECTORIZE: {},
      RATE_LIMIT_RAG_SEARCH: { async limit() { retrieved++; return { success: true }; } },
    });
    const ordinary = { messages: [{ role: "user", text: "説明して" }], model: "claude-haiku-4-5-20251001" };
    const a = await chat(environment, ordinary, {}, "plus");
    const b = await chat(environment, { ...ordinary, rag: { scope: { kind: "library" } } },
      { "X-Studiquo-RAG-Consent": "rag-openai-v1" }, "plus");
    assert.equal(a.response.status, 403);
    assert.equal(b.response.status, 403);
    assert.equal(requests.length, 0);
    assert.equal(retrieved, 0);
  } finally { globalThis.fetch = original; }
});

import { qualityEnvironment, qualitySource } from './rag-quality-fixture.js';
import { accountKey, indexSource } from './rag/storage.js';
test('RAG SSE evidence states and OpenAI instructions reflect supported, partial and general answers', async () => {
  const original=globalThis.fetch;const prompts=[];
  globalThis.fetch=async(_url,options)=>{prompts.push(JSON.parse(options.body));return new Response('data: {"type":"response.output_text.delta","delta":"answer"}\n\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n');};
  try {
    const qenv=qualityEnvironment();const environment={...env(),...qenv};
    await indexSource(environment,await accountKey('canonical-owner'),qualitySource());
    environment.RAG_VECTORIZE.query=async()=>({matches:[...qenv.vectors.values()].map(v=>({id:v.id,score:0.6}))});
    for (const [question,status,pattern] of [
      ['光合成とは？','grounded',/claims they actually support/],
      ['光合成と量子色力学の違い','partial',/full comparison cannot be grounded/],
      ['暗号通貨の株価','fallback',/Studiquo/],
      ['これのしくみを説明して','clarification',/Ask the user which topic/],
    ]) {
      const result=await chat(environment,{messages:[{role:'user',text:question}],rag:{scope:{type:'library'}}},{'X-Studiquo-RAG-Consent':'rag-openai-v1'});
      assert.ok(result.text.includes(JSON.stringify({ragStatus:status})),status);
      assert.match(JSON.stringify(prompts.at(-1).instructions),pattern);
      if(['insufficient','clarification','fallback'].includes(status))assert.doesNotMatch(result.text,/"citations"/);
    }
  } finally {globalThis.fetch=original;}
});

function sse(pieces) {
  return pieces.map((delta) => `data: ${JSON.stringify({ type: "response.output_text.delta", delta })}\n\n`).join("") +
    'data: {"type":"response.completed","response":{"status":"completed"}}\n\n';
}
const answerText = (text) => text.split("\n").filter((l) => l.startsWith("data:")).map((l) => JSON.parse(l.slice(5))).map((e) => e.text ?? "").join("");

test("an answer built from documents has its links removed even when split across stream pieces; ordinary chat keeps them", async () => {
  const original = globalThis.fetch;
  const pieces = ["光合成は葉で起きます。[詳", "細](https://evil", ".example/?q=抜粋)", "を開いてください。"];
  globalThis.fetch = async () => new Response(sse(pieces));
  try {
    const qenv = qualityEnvironment(), environment = { ...env(), ...qenv };
    await indexSource(environment, await accountKey("canonical-owner"), qualitySource());
    environment.RAG_VECTORIZE.query = async () => ({ matches: [...qenv.vectors.values()].map((v) => ({ id: v.id, score: 0.6 })) });
    const rag = await chat(environment, { messages: [{ role: "user", text: "光合成とは？" }], rag: { scope: { type: "library" } } }, { "X-Studiquo-RAG-Consent": "rag-openai-v1" });
    assert.ok(rag.text.includes('"grounded"'));
    assert.equal(answerText(rag.text), "光合成は葉で起きます。詳細を開いてください。");
    const plain = await chat(env(), { messages: [{ role: "user", text: "光合成とは？" }] });
    assert.equal(answerText(plain.text), pieces.join(""));
  } finally { globalThis.fetch = original; }
});

test("RAG_CONTEXT_AS_INPUT moves the excerpts out of the instructions into a separate input item; default is unchanged", async () => {
  const original = globalThis.fetch;
  const bodies = [];
  globalThis.fetch = async (_url, options) => { bodies.push(JSON.parse(options.body)); return new Response(sse(["回答"])); };
  try {
    for (const flag of [undefined, "true"]) {
      const qenv = qualityEnvironment(), environment = { ...env(), ...qenv, ...(flag ? { RAG_CONTEXT_AS_INPUT: flag } : {}) };
      await indexSource(environment, await accountKey("canonical-owner"), qualitySource());
      environment.RAG_VECTORIZE.query = async () => ({ matches: [...qenv.vectors.values()].map((v) => ({ id: v.id, score: 0.6 })) });
      await chat(environment, { messages: [{ role: "user", text: "光合成とは？" }], rag: { scope: { type: "library" } } }, { "X-Studiquo-RAG-Consent": "rag-openai-v1" });
      const body = bodies.at(-1);
      const inInstructions = body.instructions.includes("UNTRUSTED retrieved reference data"); // the policy text alone also names untrustedReferences
      const inputs = body.input.map((m) => JSON.stringify(m.content));
      if (!flag) {
        assert.ok(inInstructions);
        assert.equal(body.input.length, 1);
      } else {
        assert.ok(!inInstructions, "excerpts must not be in the instructions");
        assert.match(body.instructions, /claims they actually support/); // the answer policy stays in the instructions
        assert.equal(body.input.length, 2);
        assert.match(inputs[0], /UNTRUSTED retrieved reference data/);
        assert.match(inputs[1], /光合成とは/); // the student's own turn stays last
        assert.equal(body.input[0].role, "user");
      }
    }
  } finally { globalThis.fetch = original; }
});
