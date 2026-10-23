// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import assert from "node:assert/strict";
import test from "node:test";
import { handleAI } from "./ai.ts";
import worker from "./app.ts";
import { sha256Hex } from "./auth.ts";

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
  const { indexSource, accountKey } = await import("./rag/storage.ts");
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

import { qualityEnvironment, qualitySource } from './rag-quality-fixture.ts';
import { accountKey, indexSource } from './rag/storage.ts';
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

test("a chat with an attached note has its links removed too; a chat with neither keeps them", async () => {
  const original = globalThis.fetch;
  const pieces = ["共有ノートより。[詳", "細](https://evil", ".example/?q=x)を見て。"];
  globalThis.fetch = async () => new Response(sse(pieces));
  try {
    const withNote = await chat(env(), { messages: [{ role: "user", text: "要点は？" }], noteContext: "友達から共有されたノートの本文" });
    assert.equal(answerText(withNote.text), "共有ノートより。詳細を見て。");
    const without = await chat(env(), { messages: [{ role: "user", text: "要点は？" }] });
    assert.equal(answerText(without.text), pieces.join(""));
    const blank = await chat(env(), { messages: [{ role: "user", text: "要点は？" }], noteContext: "   " });
    assert.equal(answerText(blank.text), pieces.join(""));
  } finally { globalThis.fetch = original; }
});

test("a teen's finished reply is screened by moderation: a flagged reply gets a notice, a clean one and an adult's do not", async () => {
  const original = globalThis.fetch;
  let moderated = 0, flag = true;
  globalThis.fetch = async (url, options) => {
    if (String(url).includes("/moderations")) {
      moderated++;
      // Only the model's reply is flagged; the student's question is clean.
      const hit = flag && JSON.parse(options.body).input.some((t) => t.includes("不適切"));
      return new Response(JSON.stringify({ results: [{ categories: { violence: hit } }] }));
    }
    return new Response(sse(["不適切かもしれない回答です。"]));
  };
  try {
    const screened = env({ AI_MODERATION: undefined });
    const withNote = (headers) => chat(screened, { messages: [{ role: "user", text: "質問" }], noteContext: "共有ノートの本文" }, headers);
    const run = withNote;
    const teen = await run({ "X-Studiquo-Age": "teen" });
    assert.match(answerText(teen.text), /保護者や先生に相談/);
    assert.ok(moderated >= 2, "the question and the reply are both screened"); // input moderation + output moderation
    flag = false; moderated = 0;
    const clean = await run({ "X-Studiquo-Age": "teen" });
    assert.ok(!/保護者や先生/.test(answerText(clean.text)));
    flag = true; moderated = 0;
    const adult = await run({ "X-Studiquo-Age": "adult" });
    assert.ok(!/保護者や先生/.test(answerText(adult.text)));
    // A reply with no outside text in it (no note, no excerpts) is not screened a second time.
    moderated = 0;
    const plain = await chat(screened, { messages: [{ role: "user", text: "質問" }] }, { "X-Studiquo-Age": "teen" });
    assert.ok(!/保護者や先生/.test(answerText(plain.text)));
    assert.equal(moderated, 1, "only the student's question was screened");
  } finally { globalThis.fetch = original; }
});

test("the shadow grounding check logs counts for a document-based answer and never changes the answer", async () => {
  const original = globalThis.fetch, log = console.log, lines = [];
  globalThis.fetch = async () => new Response(sse(["電流計の価格は8000円です。"]));
  console.log = (...args) => { lines.push(args.join(" ")); };
  try {
    const qenv = qualityEnvironment(), environment = { ...env(), ...qenv };
    await indexSource(environment, await accountKey("canonical-owner"), qualitySource({ pages: [{ pageNumber: 1, text: "電流計の価格は5000円です。" }] }));
    environment.RAG_VECTORIZE.query = async () => ({ matches: [...qenv.vectors.values()].map((v) => ({ id: v.id, score: 0.6 })) });
    const result = await chat(environment, { messages: [{ role: "user", text: "電流計の価格を教えて" }], rag: { scope: { type: "library" } } }, { "X-Studiquo-RAG-Consent": "rag-openai-v1" });
    assert.equal(answerText(result.text), "電流計の価格は8000円です。"); // unchanged even though 8000 is not in the excerpt
    const event = lines.map((l) => { try { return JSON.parse(l); } catch { return null; } }).find((e) => e?.event === "rag_grounding");
    assert.deepEqual(event, { event: "rag_grounding", status: "grounded", checkedNumbers: 1, ungroundedNumbers: 1, checkedTokens: 0, ungroundedTokens: 0 });
  } finally { globalThis.fetch = original; console.log = log; }
});

test("RAG_CONTEXT_AS_INPUT: a retry whose references were revoked sends no excerpt in the input", async () => {
  const { callOpenAIChat } = await import("./openai.ts");
  const original = globalThis.fetch, bodies = [];
  let status = 503;
  globalThis.fetch = async (_url, options) => {
    bodies.push(JSON.parse(options.body));
    const response = new Response(status === 503 ? "busy" : sse(["回答"]), { status });
    status = 200; // the second attempt succeeds
    return response;
  };
  try {
    let attempt = 0;
    await callOpenAIChat({ AI_RETRY_BASE_MS: 0 }, {
      model: "gpt-test", systemInstruction: "base", turns: [{ role: "user", text: "質問" }], apiKey: "test-placeholder",
      beforeDispatch: async () => (++attempt === 1
        ? { instructions: "base", reference: "UNTRUSTED retrieved reference data 資料の抜粋" }
        : "base"), // revalidation failed: references revoked
    });
    assert.equal(bodies.length, 2);
    assert.equal(bodies[0].input.length, 2);
    assert.match(JSON.stringify(bodies[0].input), /資料の抜粋/);
    assert.equal(bodies[1].input.length, 1, "the revoked excerpt must not be resent");
    assert.ok(!JSON.stringify(bodies[1]).includes("資料の抜粋"));
  } finally { globalThis.fetch = original; }
});

test("links are still removed when the final re-check empties the references after they were sent", async () => {
  const original = globalThis.fetch;
  const qenv = qualityEnvironment(), environment = { ...env(), ...qenv };
  globalThis.fetch = async () => {
    // The source is deleted while the model is answering: the final re-check fails.
    qenv.ADMIN_DB.db.exec("UPDATE rag_sources SET deleted=1");
    return new Response(sse(["電流計は5000円です。[詳細](https://evil.example/?q=x)"]));
  };
  try {
    await indexSource(environment, await accountKey("canonical-owner"), qualitySource({ pages: [{ pageNumber: 1, text: "電流計の価格は5000円です。" }] }));
    environment.RAG_VECTORIZE.query = async () => ({ matches: [...qenv.vectors.values()].map((v) => ({ id: v.id, score: 0.6 })) });
    const result = await chat(environment, { messages: [{ role: "user", text: "電流計の価格を教えて" }], rag: { scope: { type: "library" } } }, { "X-Studiquo-RAG-Consent": "rag-openai-v1" });
    assert.ok(!/evil\.example/.test(answerText(result.text)), answerText(result.text));
    assert.ok(!result.text.includes('"citations"'), "the citation is still dropped when the source is gone");
  } finally { globalThis.fetch = original; }
});

const textEvents = (text) => text.split("\n").filter((l) => l.startsWith("data:")).map((l) => JSON.parse(l.slice(5))).filter((e) => typeof e.text === "string");

test("a reply built from an attached note arrives as one finished text; an ordinary reply still streams in pieces", async () => {
  const original = globalThis.fetch;
  const pieces = ["共有ノートより。[詳", "細](https://evil", ".example/?q=x)を", "見て。"];
  globalThis.fetch = async () => new Response(sse(pieces));
  try {
    const held = await chat(env(), { messages: [{ role: "user", text: "要点は？" }], noteContext: "友達から共有されたノートの本文" });
    assert.deepEqual(textEvents(held.text).map((e) => e.text), ["共有ノートより。詳細を見て。"], "held, filtered once, sent once");
    const streamed = await chat(env(), { messages: [{ role: "user", text: "要点は？" }] });
    assert.deepEqual(textEvents(streamed.text).map((e) => e.text), pieces, "no outside text: streamed as it arrives");
  } finally { globalThis.fetch = original; }
});

test("a held reply that is cut off keeps what arrived (filtered), then says it did not finish", async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async () => new Response(
    ['共有ノートより。[詳細](https://evil.example/?q=x)を見て。'].map((delta) => `data: ${JSON.stringify({ type: "response.output_text.delta", delta })}\n\n`).join("") +
    'data: {"type":"response.failed","response":{"status":"failed"}}\n\n');
  try {
    const result = await chat(env(), { messages: [{ role: "user", text: "要点は？" }], noteContext: "共有ノートの本文" });
    const texts = textEvents(result.text).map((e) => e.text);
    assert.equal(texts[0], "共有ノートより。詳細を見て。");
    assert.match(texts.at(-1), /AIが回答を完了できませんでした/);
    assert.ok(!/evil\.example/.test(result.text));
  } finally { globalThis.fetch = original; }
});

test("while a held reply is being written, a comment line keeps the connection alive; the app ignores it", async () => {
  const { mock } = await import("node:test");
  mock.timers.enable({ apis: ["setInterval"] });
  const original = globalThis.fetch;
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  globalThis.fetch = async () => new Response(new ReadableStream({
    async start(controller) {
      await gate;
      controller.enqueue(new TextEncoder().encode(sse(["共有ノートより。"])));
      controller.close();
    },
  }));
  try {
    const pending = chat(env(), { messages: [{ role: "user", text: "要点は？" }], noteContext: "共有ノートの本文" });
    const settle = async () => { for (let i = 0; i < 30; i++) await new Promise((resolve) => setImmediate(resolve)); };
    await settle(); // the request reaches the point where it waits for the model
    mock.timers.tick(15000);
    await settle();
    release();
    const result = await pending;
    assert.ok(result.text.includes(": keepalive\n\n"), "a comment line was sent while waiting");
    assert.equal(answerText(result.text), "共有ノートより。");
    // the app reads only lines that start with "data:"
    assert.ok(result.text.split("\n").filter((l) => l && !l.startsWith("data:")).every((l) => l.startsWith(":")));
  } finally { globalThis.fetch = original; mock.timers.reset(); }
});

test("a held reply cut off by a broken connection still shows what arrived, filtered, then says it was interrupted", async () => {
  const original = globalThis.fetch;
  // The first read delivers part of the reply, the second one fails (a connection reset).
  let reads = 0;
  globalThis.fetch = async () => new Response(new ReadableStream({
    pull(controller) {
      if (reads++ === 0) controller.enqueue(new TextEncoder().encode(sse(["共有ノートより。[詳細](https://evil.example/?q=x)を見て。"]).split("data: {\"type\":\"response.completed\"")[0]));
      else controller.error(new Error("connection reset"));
    },
  }));
  try {
    const result = await chat(env(), { messages: [{ role: "user", text: "要点は？" }], noteContext: "共有ノートの本文" });
    const texts = textEvents(result.text).map((e) => e.text);
    assert.equal(texts[0], "共有ノートより。詳細を見て。");
    assert.match(texts.at(-1), /通信が中断しました/);
    assert.equal(texts.length, 2, "the held text is sent once, not twice");
    assert.ok(!/evil\.example/.test(result.text));
  } finally { globalThis.fetch = original; }
});

test('the retrieval log line carries the status, reason and check code, and none of the question or document text', async () => {
  const original = globalThis.fetch;
  const log = console.log;
  const lines: string[] = [];
  globalThis.fetch = async () => new Response('data: {"type":"response.output_text.delta","delta":"x"}\n\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n');
  const numbered = (...texts: string[]) => texts.map((text, i) => ({ pageNumber: i + 1, text }));
  const cases: [string, any[], any][] = [
    ['電流計の価格を教えて', numbered('電流計は直列につなぐ。'), { status: 'insufficient', reason: 'insufficient', detail: 'requirements', termAbsentKept: null }],
    ['気象予報士試験の合格率は何%ですか。', numbered('気象予報士試験は国家資格である。'), { status: 'insufficient', reason: 'insufficient', detail: 'quantity', termAbsentKept: null }],
    ['TensorFlowで台風の進路を予測する方法を教えてください。', numbered('気温の単位は摂氏である。', '台風は熱帯の海上で発生する低気圧である。台風の進路は偏西風の影響を受ける。'), { detail: 'term_latin', termAbsentKept: null }],
    ['ridgeとはどのような場所のことですか。', numbered('リッジは高気圧性の曲率をもつ、等高度線が極側に張り出した場所である。', '気温の単位は摂氏である。'), { status: 'grounded', reason: null, detail: null, termAbsentKept: true }],
  ];
  try {
    for (const [query, pages, expected] of cases) {
      const environment = env(qualityEnvironment());
      await indexSource(environment, await accountKey('canonical-owner'), qualitySource({ totalPages: pages.length, pages }));
      lines.length = 0;
      console.log = (line: any) => { lines.push(String(line)); };
      await chat(environment, { messages: [{ role: 'user', text: query }], rag: { scope: { kind: 'library' } } }, { 'X-Studiquo-RAG-Consent': 'rag-openai-v1' });
      console.log = log;
      const entry = lines.map(l => { try { return JSON.parse(l); } catch { return null; } }).find(e => e?.event === 'rag_retrieval');
      assert.ok(entry, query);
      for (const [key, value] of Object.entries(expected)) assert.equal(entry[key], value, `${key} for ${query}`);
      const text = lines.join('\n');
      for (const secret of ['電流計', '合格率', 'TensorFlow', 'ridge', 'リッジ', '摂氏', '台風']) assert.ok(!text.includes(secret), secret);
    }
  } finally { console.log = log; globalThis.fetch = original; }
});


test("RAG reserves actual revalidated references before dispatch, retries once charged, and refunds failures", async () => {
  const original = globalThis.fetch;
  try {
    for (const mode of ["ok", "retry", "refuse", "failure"]) {
      const qenv = qualityEnvironment(), used = new Map();
      const environment = { ...env(), ...qenv, AI_RETRY_BASE_MS: 0, RATE_COUNTER: { getByName(name) { return {
        async take(limit, seconds, amount = 1) {
          if (mode === "refuse" && name.startsWith("ai:cr:5h2:") && (used.get(name) || 0) >= 1) return { ok: false };
          const next = (used.get(name) || 0) + amount;
          if (next > limit) return { ok: false };
          used.set(name, next); return { ok: true, windowEndsAt: 1 };
        },
        async give(amount) { used.set(name, (used.get(name) || 0) - amount); },
      }; } } };
      await indexSource(environment, await accountKey("canonical-owner"), qualitySource());
      environment.RAG_VECTORIZE.query = async () => ({ matches: [...qenv.vectors.values()].map(v => ({ id: v.id, score: 0.6 })) });
      let calls = 0;
      globalThis.fetch = async () => { calls++; return mode === "failure" || (mode === "retry" && calls === 1) ? new Response("error", {status: 503}) : new Response(sse(["回答"])); };
      const result = await chat(environment, { messages: [{ role: "assistant", text: "x".repeat(3980) }, { role: "user", text: "光合成とは？" }], noteContext: "x".repeat(8000), rag: { scope: { type: "library" } } }, { "X-Studiquo-RAG-Consent": "rag-openai-v1" });
      if (mode === "refuse") { assert.equal(result.response.status, 429); assert.equal(calls, 0); }
      else if (mode === "failure") assert.equal(result.response.status, 503);
      else { assert.equal(result.response.status, 200); assert.equal(calls, mode === "retry" ? 2 : 1); }
      if (mode === "refuse" || mode === "failure") assert.ok([...used.values()].every(v => v === 0));
      else {
        assert.equal([...used].find(([n]) => n.startsWith("ai:cr:min:"))[1], 1);
        const five = [...used].find(([n]) => n.startsWith("ai:cr:5h2:"))[1];
        assert.ok(five > 1);
        assert.equal([...used].find(([n]) => n.startsWith("ai:cr:wk:"))[1], five);
        assert.equal(used.get("ai:global:standard"), five);
      }
    }
  } finally { globalThis.fetch = original; }
});
