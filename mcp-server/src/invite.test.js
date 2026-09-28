import assert from "node:assert/strict";
import test from "node:test";
import worker from "./app.js";

const noopCtx = { waitUntil() {} };

function request(path) {
  return new Request(`https://example.test${path}`);
}

test("GET /invite with a valid token serves an HTML page linking to the studiquo:// scheme", async () => {
  const response = await worker.fetch(request("/invite?token=ABCD1234"), {}, noopCtx);
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type"), /text\/html/);
  const text = await response.text();
  assert.match(text, /studiquo:\/\/friend\/add\?token=ABCD1234/);
});

test("GET /invite with a missing or malformed token is rejected with 400", async () => {
  const missing = await worker.fetch(request("/invite"), {}, noopCtx);
  assert.equal(missing.status, 400);

  const malformed = await worker.fetch(request("/invite?token=not valid!"), {}, noopCtx);
  assert.equal(malformed.status, 400);
});

test("GET /invite never crosses into an XSS payload injected through the token", async () => {
  const response = await worker.fetch(request(`/invite?token=${encodeURIComponent("<script>alert(1)</script>")}`), {}, noopCtx);
  assert.equal(response.status, 400);
});

test("the Apple App Site Association file declares a Universal Link for /invite alongside the existing passkey entry", async () => {
  const response = await worker.fetch(request("/.well-known/apple-app-site-association"), {}, noopCtx);
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.deepEqual(body.webcredentials, { apps: ["972G4VGUA6.com.yabuko.studiquo"] });
  const detail = body.applinks.details.find(d => d.appIDs.includes("972G4VGUA6.com.yabuko.studiquo"));
  assert.ok(detail, "expected an applinks detail entry for the app");
  assert.ok(detail.components.some(c => c["/"] === "/invite"), "expected /invite to be a Universal Link path");
});
