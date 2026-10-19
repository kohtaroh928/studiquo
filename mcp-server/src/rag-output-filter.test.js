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

test("internal identifiers are removed, also when split across pieces", () => {
  const hex = "a1b2c3d4".repeat(8);
  const text = `出典は sourceId=other-user-source と chunk_id: ${hex} です。通常の文章 abc123 は残る。`;
  for (const size of [1, 2, 5, 11, 200]) {
    const out = stream(text.match(new RegExp(`[\\s\\S]{1,${size}}`, "gu")));
    assert.ok(!/other-user-source|a1b2c3d4/.test(out), `size ${size}: ${out}`);
    assert.ok(out.includes("通常の文章 abc123 は残る。"), `size ${size}: ${out}`);
  }
});

test("an internal id written as 'sourceId: value' is removed however the pieces fall", () => {
  const text = "出典は sourceId: other-user-source です。chunk_id: 0123abcd と source id = \"abc-123\" も。";
  for (const size of [1, 2, 3, 5, 7, 200]) {
    const out = stream(text.match(new RegExp(`[\\s\\S]{1,${size}}`, "gu")));
    assert.ok(!/other-user-source|0123abcd|abc-123/.test(out), `size ${size}: ${out}`);
    assert.ok(out.startsWith("出典は ") && out.includes("です。"), `size ${size}: ${out}`);
  }
});

test("links with any scheme, and images, are removed; plain brackets stay", () => {
  assert.equal(redactLinks("[a](javascript:alert)x"), "ax");
  for (const target of ["javascript:alert", "mailto:a@b.c", "tel:0312345678", "data:text/html,x", "//evil.example/x", "HTTPS://EVIL.example", "ftp://h/f"])
    assert.equal(redactLinks(`見て[リンク](${target})ね`), "見てリンクね", target);
  assert.equal(redactLinks("![図](https://evil.example/a.png)を見て"), "図を見て");
  assert.equal(redactLinks("要素 [0](添字) と [a, b] の区間"), "要素 [0](添字) と [a, b] の区間");
});

test("a URL ends where the Japanese sentence continues", () => {
  assert.equal(redactLinks("https://example.com/を参照してください。"), "（リンクは表示されません）を参照してください。");
  assert.equal(redactLinks("詳細は https://example.com/a?b=c です"), "詳細は （リンクは表示されません） です");
});

test("a forced cut never splits a surrogate pair", () => {
  const r = linkRedactor();
  const text = "a".repeat(599) + "😀" + "b".repeat(10);
  const out = r.push(text) + r.flush();
  assert.equal(out, text);
  assert.ok(!/[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/u.test(out));
});

const pieces = (text, size) => text.match(new RegExp(`[\\s\\S]{1,${size}}`, "gu"));

test("links the way the app reads them: nested labels, newlines, escapes and 'https:' without slashes", () => {
  const stillLinks = [
    "[a [b] c](https:e.com?d=1)", "[a [b] c](https:/e.com?d=1)", "[a\nb](https:e.com?d=1)", "[a \\] b](https:e.com?d=1)",
    "[a [b] c](HTTPS:E.COM?d=1)", "[[x](https://in.example)](https://out.example)", "[x](www.evil.example/p)",
  ];
  for (const text of stillLinks) {
    const out = redactLinks(`前 ${text} 後`);
    assert.ok(!/e\.com|in\.example|out\.example|evil/iu.test(out), `${JSON.stringify(text)} -> ${JSON.stringify(out)}`);
    assert.ok(out.startsWith("前 ") && out.endsWith(" 後"), JSON.stringify(out));
    for (const size of [1, 2, 3, 7]) {
      const streamed = stream(pieces(`前 ${text} 後`, size));
      assert.ok(!/e\.com|in\.example|out\.example|evil/iu.test(streamed), `size ${size}: ${JSON.stringify(streamed)}`);
    }
  }
  assert.equal(redactLinks("https:e.com?d=1 を見て"), "（リンクは表示されません） を見て");
  assert.equal(redactLinks("[a](javascript:alert(1))x"), "ax");
});

test("brackets that are not links are left alone, also across pieces", () => {
  const text = "区間 [0, 1) と a[i](2) と [注: 参照] の話。\\[escaped](https://x.example) は括弧のまま。";
  assert.equal(redactLinks("区間 [0, 1) と a[i](2) と [注: 参照] の話。"), "区間 [0, 1) と a[i](2) と [注: 参照] の話。");
  for (const size of [1, 4, 9]) {
    const out = stream(pieces("区間 [0, 1) と a[i](2) と [注: 参照] の話。", size));
    assert.equal(out, "区間 [0, 1) と a[i](2) と [注: 参照] の話。", `size ${size}`);
  }
  assert.ok(!text.includes("undefined"));
});

test("many brackets do not make the scan quadratic", () => {
  const started = Date.now();
  redactLinks("[".repeat(50000));
  redactLinks("[a](".repeat(5000));
  assert.ok(Date.now() - started < 1000, `${Date.now() - started} ms`);
});

test("a value that itself ends in 'source' or 'chunk' is removed whole, however the pieces fall", () => {
  for (const text of ["出典は sourceId: other-user-source です。", "出典は sourceId: abc-chunk です。", "chunk_id = my-resource, 次へ"]) {
    for (const size of [1, 2, 3, 5]) {
      const out = stream(pieces(text, size));
      assert.ok(!/other-user|abc-|my-resource|-source|-chunk/.test(out), `size ${size}: ${JSON.stringify(out)}`);
    }
  }
});

test("URLs with a non-ASCII host or path are removed without eating the sentence", () => {
  assert.equal(redactLinks("https://例え.com/a?d=1 を見て"), "（リンクは表示されません） を見て");
  assert.equal(redactLinks("先は https://e.com/日本語?d=1 です"), "先は （リンクは表示されません） です");
  assert.equal(redactLinks("https://例えば、これです"), "（リンクは表示されません）、これです");
  assert.equal(redactLinks("https://example.com/を参照してください。"), "（リンクは表示されません）を参照してください。");
});

// Invariant: a reply built from untrusted input never keeps an http(s) address or a
// "www." address, whatever wrapper it sits in and however the stream is cut. The app only
// opens http and https links, so this is the property that matters; it does not depend on
// reproducing the app's Markdown parser exactly.
const SECRET = "SECRETDATA";
const TARGETS = [
  (n) => `https://e.com/?d=${SECRET.repeat(n)}`, (n) => `https:e.com?d=${SECRET.repeat(n)}`, (n) => `https:/e.com?d=${SECRET.repeat(n)}`,
  (n) => `https:\\\\e.com?d=${SECRET.repeat(n)}`, (n) => `HtTps:/e.com?d=${SECRET.repeat(n)}`, (n) => `https:%65.com?d=${SECRET.repeat(n)}`,
  (n) => `www.e.com/?d=${SECRET.repeat(n)}`, (n) => `https:例え.com?d=${SECRET.repeat(n)}`, (n) => `h​ttps:​e.com?d=${SECRET.repeat(n)}`,
];
const WRAPPERS = [
  (t) => `[x](${t})`, (t) => `[a [b] c](${t})`, (t) => `![i](${t})`, (t) => `**[x](${t})**`, (t) => `[x](${t} "title")`, (t) => `[x]( ${t} )`,
  (t) => `[x](${t.replace("?d=", "?d=`a b`")})`, (t) => `[x](${t}$a b$)`, (t) => t, (t) => `<${t}>`, (t) => `[${"あ".repeat(590)}](${t})`,
  (t) => `\\\\[x](${t})`, (t) => `[x]\n(${t})`,
];

test("no http(s) or www address survives in any wrapper, target form or stream cut", () => {
  const sizes = [1, 2, 3, 7, 40, 599, 600, 601, 5000];
  let checked = 0;
  for (const n of [1, 120]) for (const target of TARGETS) for (const wrap of WRAPPERS) {
    const text = `前 ${wrap(target(n))} 後。`;
    for (const size of sizes) {
      const out = stream(pieces(text, size));
      checked++;
      assert.ok(!out.includes(SECRET) && !/https?:|www\./iu.test(out), `n=${n} size=${size}: ${JSON.stringify(text.slice(0, 80))} -> ${JSON.stringify(out.slice(0, 120))}`);
    }
  }
  assert.ok(checked > 2000);
});

test("ordinary prose is unchanged whatever the cut (including very long text)", () => {
  const prose = "細胞は生物の基本単位です。区間 [0, 1) と a[i][j]、【資料】(p.3)、\\[ x^2 \\] を使う。www という語、http のプロトコル、https の話。".repeat(30);
  for (const size of [1, 2, 3, 7, 40, 599, 601, 5000]) assert.equal(stream(pieces(prose, size)), prose, `size ${size}`);
});

test("output does not depend on how the stream was cut (a tiny parenthesis case)", () => {
  for (const text of ["[a](javascript:alert(1))x", "[a](https://(evil))x"]) {
    const whole = stream([text]);
    for (const size of [1, 2, 3, 5]) assert.equal(stream(pieces(text, size)), whole, `${JSON.stringify(text)} size ${size}`);
  }
});

test("an escaped backslash before a link does not hide it from the stream", () => {
  const text = "前 \\\\[a](https:/e.com/x) 後";
  for (const size of [1, 2, 3, 7]) assert.ok(!/e\.com/.test(stream(pieces(text, size))), `size ${size}`);
});

test("words that merely start like an address are not mangled", () => {
  assert.equal(redactLinks("www.という略語は、ドメインの先頭。"), "www.という略語は、ドメインの先頭。");
  assert.equal(redactLinks("ウェブ(www)の話"), "ウェブ(www)の話");
});
