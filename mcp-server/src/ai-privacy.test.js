import assert from "node:assert/strict";
import test from "node:test";
import { aiPrivacyRejection, ragPrivacyRejection, AI_CONSENT_VERSION } from "./ai-privacy.js";

const APPROVED = { AI_PROVIDER_APPROVED: "true" };

function request(body = {}, consent = AI_CONSENT_VERSION, path = "chat", age = "adult") {
  const headers = { "Content-Type": "application/json", "X-Studiquo-AI-Consent": consent };
  if (age) headers["X-Studiquo-Age"] = age;
  return new Request(`https://example.test/api/ai/${path}`, { method: "POST", headers, body: JSON.stringify(body) });
}
test("approval is opt-in and an old consent cannot enable requests", async () => {
  assert.equal((await aiPrivacyRejection(request(), {})).status, 503);
  assert.equal((await aiPrivacyRejection(request(), { AI_PROVIDER_APPROVED: true })).status, 503);
  assert.equal((await aiPrivacyRejection(request({}, ""), APPROVED)).status, 403);
  assert.equal((await aiPrivacyRejection(request({}, "google-v2"), APPROVED)).status, 403);
});
test("a request without a confirmed age band is refused; adult and teen pass", async () => {
  assert.equal((await aiPrivacyRejection(request({}, AI_CONSENT_VERSION, "chat", ""), APPROVED)).status, 403);
  assert.equal((await aiPrivacyRejection(request({}, AI_CONSENT_VERSION, "chat", "child"), APPROVED)).status, 403);
  assert.equal(await aiPrivacyRejection(request({}, AI_CONSENT_VERSION, "chat", "teen"), APPROVED), null);
  assert.equal(await aiPrivacyRejection(request({}, AI_CONSENT_VERSION, "chat", "adult"), APPROVED), null);
});
test("all AI functions reject unlisted providers and invalid JSON", async () => {
  for (const path of ["chat", "rubric", "grade", "review"]) {
    assert.equal((await aiPrivacyRejection(request({ model: "gemini-3.5-flash-lite" }, AI_CONSENT_VERSION, path), APPROVED)).status, 403);
    assert.equal((await aiPrivacyRejection(request({ model: "claude-sonnet-5-5" }, AI_CONSENT_VERSION, path), APPROVED)).status, 403);
  }
  assert.equal((await aiPrivacyRejection(request([]), APPROVED)).status, 400);
});
test("approved OpenAI requests remain readable by the actual handler", async () => {
  const input = request({ model: "openai-luna", messages: [{ role: "user", text: "test" }] });
  assert.equal(await aiPrivacyRejection(input, APPROVED), null);
  assert.equal((await input.json()).messages[0].text, "test");
});
test("an empty or padded model name is treated like the handler treats it", async () => {
  assert.equal(await aiPrivacyRejection(request({ model: "" }), APPROVED), null);
  assert.equal(await aiPrivacyRejection(request({ model: " openai-luna " }), APPROVED), null);
  assert.equal((await aiPrivacyRejection(request({ model: 5 }), APPROVED)).status, 403);
});

for(const [path,body] of [['/api/rag/index',{}],['/api/rag/documents/prepare',{}],['/api/rag/consent',{enabled:true}],['/api/rag/documents/synthetic/state',{state:'eligible'}]]) {
 test(`RAG send enabling ${path} requires renewed provider consent and age`,async()=>{
  const create=(rag='rag-openai-v1',ai='openai-v1',age='adult')=>new Request('https://example.test'+path,{method:'POST',headers:{'X-Studiquo-RAG-Consent':rag,'X-Studiquo-AI-Consent':ai,'X-Studiquo-Age':age},body:JSON.stringify(body)});
  assert.equal(await ragPrivacyRejection(create(),APPROVED,path),null);
  assert.equal((await ragPrivacyRejection(create('rag-v1'),APPROVED,path)).status,403);
  assert.equal((await ragPrivacyRejection(create('rag-openai-v1','google-v2'),APPROVED,path)).status,403);
  assert.equal((await ragPrivacyRejection(create('rag-openai-v1','openai-v1',''),APPROVED,path)).status,403);
 });
}
test('RAG revoke, lock, cleanup and delete remain accessible without provider consent',async()=>{
 for(const [path,method,body] of [['/api/rag/consent','POST',{enabled:false}],['/api/rag/documents/synthetic/state','POST',{state:'locked'}],['/api/rag/cleanup','POST',{}],['/api/rag/sources/synthetic','DELETE',null]]) {
  const req=new Request('https://example.test'+path,{method,...(body?{body:JSON.stringify(body)}:{})});
  assert.equal(await ragPrivacyRejection(req,{},path),null);
 }
});
