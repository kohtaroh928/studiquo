import test from "node:test";
import assert from "node:assert/strict";
import { groundingCheck } from "./rag/grounding-check.ts";

const shown = "電流計 AM-250 の価格は5,000円です。測定範囲は0.5 A。";

test("figures and model numbers that the excerpts contain are grounded", () => {
  const r = groundingCheck("AM-250の価格は5000円で、測定範囲は0.5Aです。", shown);
  assert.deepEqual(r, { checkedNumbers: 2, ungroundedNumbers: 0, checkedTokens: 1, ungroundedTokens: 0 });
});

test("figures and model numbers that appear nowhere are counted", () => {
  const r = groundingCheck("AM-999の価格は8000円で、保証は24か月です。", shown);
  assert.equal(r.ungroundedNumbers, 2); // 8000, 24 (the 999 inside AM-999 belongs to the model token)
  assert.equal(r.ungroundedTokens, 1);
});

test("fullwidth digits and thousands separators are compared by value", () => {
  assert.equal(groundingCheck("価格は５０００円", shown).ungroundedNumbers, 0);
  assert.equal(groundingCheck("価格は5,000円", shown).ungroundedNumbers, 0);
});

test("one-digit numbers and empty input are ignored", () => {
  assert.deepEqual(groundingCheck("3個あります", ""), { checkedNumbers: 0, ungroundedNumbers: 0, checkedTokens: 0, ungroundedTokens: 0 });
  assert.deepEqual(groundingCheck(undefined, undefined), { checkedNumbers: 0, ungroundedNumbers: 0, checkedTokens: 0, ungroundedTokens: 0 });
});
