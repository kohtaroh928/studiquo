import test from "node:test";
import assert from "node:assert/strict";
import { redactPII } from "./rag/redact-pii.js";

test("identifiers and secrets are masked and counted", () => {
  const key = "sk-" + "a1B2c3D4e5F6g7H8i9J0k1L2";
  const text = [
    "連絡先は taro.yamada+gakkou@example.co.jp です。",
    "電話 03-1234-5678 / 090-1234-5678 / 09012345678 / +81-3-1234-5678",
    "カード 4111 1111 1111 1111 と 4242-4242-4242-4242",
    "マイナンバー: 1234 5678 9012",
    `鍵 ${key}`,
    "-----BEGIN PRIVATE KEY-----\nMIIabc\n-----END PRIVATE KEY-----",
  ].join("\n");
  const { text: out, counts, total } = redactPII(text);
  for (const leaked of ["taro.yamada", "03-1234-5678", "090-1234-5678", "09012345678", "4111", "4242", "1234 5678 9012", key, "MIIabc"])
    assert.ok(!out.includes(leaked), leaked);
  assert.deepEqual(counts, { key: 2, email: 1, phone: 4, myNumber: 1, card: 2 });
  assert.equal(total, 10);
});

test("study content is left alone", () => {
  for (const text of [
    "2026年10月20日に5000円の電流計を3個買った。",
    "円周率は3.14159265358979。光速は299792458 m/s。",
    "答案番号 1234567890123456 は問題の例(Luhnを満たさない)。",
    "電圧は100V、抵抗は20Ω、電流は5A。式 E = mc^2。",
    "第1章 1.2.3 節。ページ 12-34。",
  ]) assert.deepEqual(redactPII(text), { text, total: 0, counts: { key: 0, email: 0, phone: 0, myNumber: 0, card: 0 } }, text);
});

test("tolerates non-strings", () => {
  assert.equal(redactPII(undefined).text, "");
});
