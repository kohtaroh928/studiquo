import test from "node:test";
import assert from "node:assert/strict";
import { stripInvisible } from "./rag/sanitize.js";

test("removes zero-width, bidi, tag and control characters and counts them", () => {
  const tag = String.fromCodePoint(0xe0041, 0xe0042);
  const { text, removed } = stripInvisible(`a​b‮c﻿d­e${tag}f\u0000g`);
  assert.equal(text, "abcdefg");
  assert.equal(removed, 7);
});

test("keeps what readable text needs: newline, tab, Japanese, emoji, variant forms, Arabic joiners", () => {
  const sample = "細胞\n\t説明 👨\u200D👩\u200D👧 ①❤\uFE0F 1\uFE0F\u20E3 葛\u{E0100}飾 م\u200Cن ①";
  assert.deepEqual(stripInvisible(sample), { text: sample, removed: 0 });
});

test("tolerates non-strings", () => {
  assert.deepEqual(stripInvisible(undefined), { text: "", removed: 0 });
  assert.deepEqual(stripInvisible(12), { text: "12", removed: 0 });
});

test("invisible fillers are removed", () => {
  const { text, removed } = stripInvisible("A\u3164B\u115FC\u2800D\u034FE\uFFA0F\u17B4G");
  assert.equal(text, "ABCDEFG");
  assert.equal(removed, 6);
});

test("variation selectors survive only where they mean something", () => {
  // after a Han character or an emoji: kept
  for (const ok of ["葛\u{E0100}飾", "渡\uFE00辺", "❤\uFE0F", "1\uFE0F\u20E3", "☺\uFE0E"])
    assert.deepEqual(stripInvisible(ok), { text: ok, removed: 0 }, JSON.stringify(ok));
  // after a letter, in a run, or Mongolian: removed
  assert.equal(stripInvisible("a\uFE0Fb\u{E0100}c").text, "abc");
  assert.equal(stripInvisible("❤\uFE0F\uFE0F").text, "❤");
  assert.equal(stripInvisible("葛\u{E0100}\u{E0101}飾").text, "葛飾");
  assert.equal(stripInvisible("a\u180Bb").text, "ab");
});

test("a joiner between ordinary letters is removed, one inside an emoji or an Arabic word stays", () => {
  assert.equal(stripInvisible("h\u200De\u200Cl\u200Dl\u200Co").text, "hello");
  assert.equal(stripInvisible("a\u200D\u200C\u200D\u200Cb").text, "ab");
  for (const ok of ["👨\u200D👩\u200D👧", "❤\uFE0F\u200D🔥", "م\u200Cن", "क\u200Dष"])
    assert.deepEqual(stripInvisible(ok), { text: ok, removed: 0 }, JSON.stringify(ok));
});

test("special spaces become a plain space, the ideographic space stays", () => {
  assert.equal(stripInvisible("a\u00A0b\u2003c\u202Fd\u205Fe").text, "a b c d e");
  assert.equal(stripInvisible("あ\u3000い").text, "あ\u3000い");
});
