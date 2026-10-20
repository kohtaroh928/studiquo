// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from "node:test";
import assert from "node:assert/strict";
import { buildResponsesBody, extractDeltaText } from "./openai.ts";

test("request body uses Responses API fields and does not store the conversation", () => {
  const body = buildResponsesBody({
    model: "gpt-test",
    systemInstruction: "system prompt",
    turns: [
      { role: "user", text: "q1" },
      { role: "assistant", text: "a1" },
      { role: "user", text: "q2" },
    ],
    images: ["AAAA"],
  });
  assert.equal(body.model, "gpt-test");
  assert.equal(body.instructions, "system prompt");
  assert.equal(body.store, false);
  assert.equal(body.stream, true);
  assert.equal(body.max_output_tokens, 8192);
  assert.equal("messages" in body, false);
  assert.equal("max_tokens" in body, false);
  assert.equal("previous_response_id" in body, false);
  assert.deepEqual(body.input[1], { role: "assistant", content: "a1" });
});

test("images are attached to the last user turn only", () => {
  const body = buildResponsesBody({
    model: "m",
    systemInstruction: "s",
    turns: [{ role: "user", text: "first" }, { role: "assistant", text: "a" }, { role: "user", text: "last" }],
    images: ["AAAA"],
  });
  assert.equal(body.input[0].content.length, 1);
  assert.deepEqual(body.input[2].content[0], { type: "input_text", text: "last" });
  assert.deepEqual(body.input[2].content[1], { type: "input_image", image_url: "data:image/png;base64,AAAA", detail: "auto" });
});

test("extractDeltaText returns only output_text deltas", () => {
  assert.equal(extractDeltaText({ type: "response.output_text.delta", delta: "やっ" }), "やっ");
  assert.equal(extractDeltaText({ type: "response.output_text.done", text: "full" }), "");
  assert.equal(extractDeltaText({ type: "response.created" }), "");
  assert.equal(extractDeltaText({ choices: [{ delta: { content: "old" } }] }), "");
  assert.equal(extractDeltaText(null), "");
});

import { toStrictJSONSchema } from "./openai.ts";
test("toStrictJSONSchema lower-cases types, requires every property and forbids extras, keeping enums", () => {
  const out = toStrictJSONSchema({
    type: "OBJECT",
    properties: { kind: { type: "STRING", enum: ["a", "b"] }, items: { type: "ARRAY", items: { type: "OBJECT", properties: { n: { type: "INTEGER" } } } } },
  });
  assert.deepEqual(out.required, ["kind", "items"]);
  assert.equal(out.additionalProperties, false);
  assert.deepEqual(out.properties.kind, { type: "string", enum: ["a", "b"] });
  assert.equal(out.properties.items.items.additionalProperties, false);
  assert.deepEqual(out.properties.items.items.required, ["n"]);
});
test('beforeDispatch refreshes instructions on initial call and every retry',async()=>{
 const {callOpenAIChat}=await import('./openai.ts');const original=globalThis.fetch;const sent=[];let checks=0;
 globalThis.fetch=async(_url,options)=>{sent.push(JSON.parse(options.body));return new Response('',{status:sent.length===1?503:200});};
 try {
  await callOpenAIChat({OPENAI_API_KEY:'synthetic-key',AI_RETRY_BASE_MS:0},{model:'synthetic',systemInstruction:'stale context',turns:[{role:'user',text:'question'}],beforeDispatch:async()=>++checks===1?'authorized context':'ordinary system'});
  assert.equal(checks,2);assert.equal(sent[0].instructions,'authorized context');assert.equal(sent[1].instructions,'ordinary system');assert.equal(sent[0].store,false);
 }finally{globalThis.fetch=original;}
});
