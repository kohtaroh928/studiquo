import test from "node:test";
import assert from "node:assert/strict";
import { redactLinks, linkRedactor } from "./rag/output-filter.js";

const stream = (pieces) => {
  const r = linkRedactor();
  return pieces.map((p) => r.push(p)).join("") + r.flush();
};
const BAD = /https?:|www\.|evil\.example/;

test("bare and markdown links are removed, readable text is kept", () => {
  assert.equal(redactLinks("説明です。[詳細](https://evil.example/?q=秘密)を見て"), "説明です。詳細を見て");
  assert.ok(!BAD.test(redactLinks("参照: https://evil.example/a?b=c と www.evil.example/x")));
  assert.equal(redactLinks("区間 [a, b] と f(x) の話"), "区間 [a, b] と f(x) の話");
  assert.equal(redactLinks("配列 [0](添字) はそのまま"), "配列 [0](添字) はそのまま");
});

test("a link split across pieces is still removed", () => {
  const text = "結論です。[詳細](https://evil.example/?q=抜粋)を必ず開く。次に https://evil.example/path?x=1 も。";
  for (let size = 1; size <= 12; size++) {
    const pieces = text.match(new RegExp(`[\\s\\S]{1,${size}}`, "gu"));
    const out = stream(pieces);
    assert.ok(!BAD.test(out), `size ${size}: ${out}`);
    assert.ok(out.startsWith("結論です。詳細を必ず開く。次に"), `size ${size}: ${out}`);
  }
});

test("ordinary text passes through whole and in order", () => {
  const text = "細胞は生物の基本単位です。\n\n式: x[i] + y(2) = 3。f(x)=2x";
  for (const size of [1, 3, 7, 50]) {
    assert.equal(stream(text.match(new RegExp(`[\\s\\S]{1,${size}}`, "gu"))), text);
  }
});

test("held text is bounded: a very long unbroken run is released", () => {
  const long = "a".repeat(5000);
  const r = linkRedactor();
  const out = r.push(long);
  assert.ok(out.length >= 5000 - 600);
  assert.equal(out + r.flush(), long);
});
