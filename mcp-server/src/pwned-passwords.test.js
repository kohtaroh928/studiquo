import assert from "node:assert/strict";
import test from "node:test";
import { isBreachedPassword } from "./pwned-passwords.js";

// SHA-1("password") = 5BAA61E4C9B93F3F0682250B6CF8331B7EE68FD8
const PREFIX = "5BAA6";
const SUFFIX = "1E4C9B93F3F0682250B6CF8331B7EE68FD8";

function fakeHibp(body, { status = 200 } = {}) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    return new Response(body, { status });
  };
  return { fetchImpl, calls };
}

function silenceErrors(run) {
  const original = console.error;
  console.error = () => {};
  return run().finally(() => { console.error = original; });
}

test("a password whose hash suffix is in the returned range is breached", async () => {
  const { fetchImpl } = fakeHibp(`0018A45C4D1DEF81644B54AB7F969B88D65:3\r\n${SUFFIX}:10434004\r\n011053FD0102E94D6AE2F8B83D76FAF94F6:1`);
  assert.equal(await isBreachedPassword("password", fetchImpl), true);
});

test("a password whose suffix is absent is not breached", async () => {
  const { fetchImpl } = fakeHibp("0018A45C4D1DEF81644B54AB7F969B88D65:3\r\n011053FD0102E94D6AE2F8B83D76FAF94F6:1");
  assert.equal(await isBreachedPassword("password", fetchImpl), false);
});

test("only the 5-character hash prefix is sent, and padding is requested", async () => {
  const { fetchImpl, calls } = fakeHibp("");
  await isBreachedPassword("password", fetchImpl);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, `https://api.pwnedpasswords.com/range/${PREFIX}`);
  assert.equal(calls[0].init.headers["Add-Padding"], "true");
  assert.ok(!calls[0].url.includes(SUFFIX));
  assert.ok(!JSON.stringify(calls[0].init.headers).includes("password"));
});

test("a padding entry (count 0) with a matching suffix is not a match", async () => {
  const { fetchImpl } = fakeHibp(`${SUFFIX}:0\r\nAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:0`);
  assert.equal(await isBreachedPassword("password", fetchImpl), false);
});

test("lookup is exact: a longer or partial suffix does not match", async () => {
  const { fetchImpl } = fakeHibp(`${SUFFIX.slice(0, -1)}:5\r\n${SUFFIX}0:5`);
  assert.equal(await isBreachedPassword("password", fetchImpl), false);
});

test("an HIBP error status is skipped rather than blocking the caller", () => silenceErrors(async () => {
  const { fetchImpl } = fakeHibp("oops", { status: 503 });
  assert.equal(await isBreachedPassword("password", fetchImpl), false);
}));

test("a network failure or timeout is skipped rather than blocking the caller", () => silenceErrors(async () => {
  assert.equal(await isBreachedPassword("password", async () => { throw new Error("network down"); }), false);
  assert.equal(await isBreachedPassword("password", async () => { throw new DOMException("timed out", "TimeoutError"); }), false);
}));

test("a skipped check is logged without the password or its hash", async () => {
  const lines = [];
  const original = console.error;
  console.error = line => lines.push(String(line));
  try {
    await isBreachedPassword("password", async () => { throw new Error("network down"); });
  } finally {
    console.error = original;
  }
  assert.equal(lines.length, 1);
  assert.ok(!/password|5BAA6|1E4C9B/i.test(lines[0].replace("pwned-passwords", "")));
});
