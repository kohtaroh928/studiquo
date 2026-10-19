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

test("dates and number runs that only look like phone numbers are left alone", () => {
  for (const text of ["03-14-2023に開催", "05 10 100", "2023-10-20", "第03-12-2021版", "座標 12-34-5678", "0.5-1.2-3456"])
    assert.equal(redactPII(text).text, text, text);
  assert.equal(redactPII("03-1234-5678").total, 1);
  assert.equal(redactPII("0120-123-456").total, 1);
  assert.equal(redactPII("03 1234 5678").total, 1);
  assert.equal(redactPII("+81 90 1234 5678").total, 1);
});

test("full-width forms are masked and the text around them is untouched", () => {
  const text = "連絡: ０９０－１２３４－５６７８ / ａ＠ｂ.ｃｏｍ / ４１１１　１１１１　１１１１　１１１１ / マイナンバー：１２３４５６７８９０１２ です。Ａ組の５０００円。";
  const { text: out, counts } = redactPII(text);
  assert.equal(out, "連絡: [電話番号] / [メールアドレス] / [カード番号] / [個人番号] です。Ａ組の５０００円。");
  assert.deepEqual(counts, { key: 0, email: 1, phone: 1, myNumber: 1, card: 1 });
});

test("named secrets and bearer tokens are masked", () => {
  const out = redactPII("Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345\napi_key=Zx9-aaaa-bbbb-cccc\npassword: hunter2hunter2\nAIza" + "A".repeat(35) + "\nsk_live_" + "a1b2c3d4e5f6g7h8i9").text;
  for (const leaked of ["abcdefghijklmnopqrstuvwxyz012345", "Zx9-aaaa", "hunter2hunter2", "AIzaAAAA", "sk_live_a1b2"]) assert.ok(!out.includes(leaked), leaked);
  assert.equal(redactPII("このtokenは短い。password は大事。key: 値").total, 0);
});

test("dash-like separators, circled digits next to a number, and 03(1234)5678", () => {
  for (const text of ["090‐1234‐5678", "090‑1234‑5678", "090−1234−5678", "03–1234–5678", "03ー1234ー5678", "03(1234)5678", "①090-1234-5678"]) {
    const out = redactPII(text);
    assert.equal(out.total, 1, text);
    assert.ok(!/1234/.test(out.text), `${text} -> ${out.text}`);
  }
  assert.equal(redactPII("①090-1234-5678").text, "①[電話番号]");
  assert.equal(redactPII("03(14)2023").total, 0); // 8 digits: not a phone number
});

test("hostile input stays fast (no quadratic scans)", () => {
  const started = Date.now();
  for (const text of ["1".repeat(50000), "0-".repeat(20000), "-----BEGIN PRIVATE KEY-----" + "a".repeat(50000), "a".repeat(30000) + "@", "a@" + "b".repeat(30000), "-".repeat(50000)])
    redactPII(text);
  assert.ok(Date.now() - started < 1500, `${Date.now() - started} ms`);
});
