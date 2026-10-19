import test from "node:test";
import assert from "node:assert/strict";
import { stripInvisible } from "./rag/sanitize.js";

test("removes zero-width, bidi, tag and control characters and counts them", () => {
  const tag = String.fromCodePoint(0xe0041, 0xe0042);
  const { text, removed } = stripInvisible(`a​b‮c﻿d­e${tag}f\u0000g`);
  assert.equal(text, "abcdefg");
  assert.equal(removed, 7);
});

test("keeps what readable text needs: newline, tab, joiners, Japanese, emoji", () => {
  const sample = "細胞\n\t説明‌‍ 👨‍👩‍👧 ①";
  assert.deepEqual(stripInvisible(sample), { text: sample, removed: 0 });
});

test("tolerates non-strings", () => {
  assert.deepEqual(stripInvisible(undefined), { text: "", removed: 0 });
  assert.deepEqual(stripInvisible(12), { text: "12", removed: 0 });
});
