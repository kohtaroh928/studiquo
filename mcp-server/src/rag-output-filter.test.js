import test from "node:test";
import assert from "node:assert/strict";
import { redactLinks, filterReply } from "./rag/output-filter.js";

// The filter runs once on the finished reply, so these tests need no stream cutting.
const SECRET = "SECRETDATA";
const BAD = /https?:|www\.|evil\.example/iu;

test("bare and markdown links are removed, readable text is kept", () => {
  assert.equal(redactLinks("説明です。[詳細](https://evil.example/?q=秘密)を見て"), "説明です。詳細を見て");
  assert.ok(!BAD.test(redactLinks("参照: https://evil.example/a?b=c と www.evil.example/x")));
  assert.equal(redactLinks("区間 [a, b] と f(x) の話"), "区間 [a, b] と f(x) の話");
  assert.equal(redactLinks("配列 [0](添字) はそのまま"), "配列 [0](添字) はそのまま");
});

test("links with any scheme, and images, are removed; plain brackets stay", () => {
  assert.equal(redactLinks("[a](javascript:alert(1))x"), "ax");
  for (const target of ["javascript:alert", "mailto:a@b.c", "tel:0312345678", "data:text/html,x", "//evil.example/x", "HTTPS://EVIL.example", "ftp://h/f"])
    assert.equal(redactLinks(`見て[リンク](${target})ね`), "見てリンクね", target);
  assert.equal(redactLinks("![図](https://evil.example/a.png)を見て"), "図を見て");
  assert.equal(redactLinks("要素 [0](添字) と [a, b] の区間"), "要素 [0](添字) と [a, b] の区間");
});

test("links the way the app reads them: nested labels, newlines, escapes and 'https:' without slashes", () => {
  for (const text of ["[a [b] c](https:e.com?d=1)", "[a [b] c](https:/e.com?d=1)", "[a\nb](https:e.com?d=1)", "[a \\] b](https:e.com?d=1)",
    "[a [b] c](HTTPS:E.COM?d=1)", "[[x](https://in.example)](https://out.example)", "[x](www.evil.example/p)"]) {
    const out = redactLinks(`前 ${text} 後`);
    assert.ok(!/e\.com|in\.example|out\.example|evil/iu.test(out), `${JSON.stringify(text)} -> ${JSON.stringify(out)}`);
    assert.ok(out.startsWith("前 ") && out.endsWith(" 後"), JSON.stringify(out));
  }
  assert.equal(redactLinks("https:e.com?d=1 を見て"), "（リンクは表示されません） を見て");
});

test("a URL ends where the Japanese sentence continues, and an address may hold non-ASCII", () => {
  assert.equal(redactLinks("https://example.com/を参照してください。"), "（リンクは表示されません）を参照してください。");
  assert.equal(redactLinks("詳細は https://example.com/a?b=c です"), "詳細は （リンクは表示されません） です");
  assert.equal(redactLinks("https://例え.com/a?d=1 を見て"), "（リンクは表示されません） を見て");
  assert.equal(redactLinks("先は https://e.com/日本語?d=1 です"), "先は （リンクは表示されません） です");
  assert.equal(redactLinks("https://例えば、これです"), "（リンクは表示されません）、これです");
});

test("words that merely start like an address are not mangled; a '$' before a space is not a math span", () => {
  assert.equal(redactLinks("www.という略語は、ドメインの先頭。"), "www.という略語は、ドメインの先頭。");
  assert.equal(redactLinks("ウェブ(www)の話"), "ウェブ(www)の話");
  assert.equal(redactLinks("詳細は https://x.com/a$ の価格は $5 です"), "詳細は （リンクは表示されません） の価格は $5 です");
  assert.equal(redactLinks("価格は$5と$10です"), "価格は$5と$10です");
});

test("internal identifiers are removed", () => {
  const hex = "a1b2c3d4".repeat(8);
  const out = redactLinks(`出典は sourceId: other-user-source と chunk_id: ${hex} と source id = "abc-123" です。通常の文章 abc123 は残る。`);
  assert.ok(!/other-user-source|a1b2c3d4|abc-123/.test(out), out);
  assert.ok(out.includes("通常の文章 abc123 は残る。"), out);
  for (const text of ["出典は sourceId: abc-chunk です。", "chunk_id = my-resource, 次へ"]) assert.ok(!/abc-|my-resource/.test(redactLinks(text)), text);
});

test("many brackets do not make the scan quadratic", () => {
  const started = Date.now();
  filterReply("[".repeat(50000));
  filterReply("[a](".repeat(5000));
  filterReply("[".repeat(40000) + "https://e.com/x");
  assert.ok(Date.now() - started < 1000, `${Date.now() - started} ms`);
});

// Invariant: a reply built from untrusted input never keeps an http(s) address or a
// "www." address, whatever wrapper it sits in. The app only opens http and https links, so
// this is the property that matters; it does not depend on reproducing the app's Markdown
// parser exactly.
const TARGETS = [
  (n) => `https://e.com/?d=${SECRET.repeat(n)}`, (n) => `https:e.com?d=${SECRET.repeat(n)}`, (n) => `https:/e.com?d=${SECRET.repeat(n)}`,
  (n) => `https:\\\\e.com?d=${SECRET.repeat(n)}`, (n) => `HtTps:/e.com?d=${SECRET.repeat(n)}`, (n) => `https:%65.com?d=${SECRET.repeat(n)}`,
  (n) => `www.e.com/?d=${SECRET.repeat(n)}`, (n) => `https:例え.com?d=${SECRET.repeat(n)}`, (n) => `h\u200Bttps:\u200Be.com?d=${SECRET.repeat(n)}`,
  (n) => `h\u200Dt\u200Ctps:\uFE0Fe.com?d=${SECRET.repeat(n)}`, (n) => `h\u{E0041}ttps://e.com/?d=${SECRET.repeat(n)}`,
];
const WRAPPERS = [
  (t) => `[x](${t})`, (t) => `[a [b] c](${t})`, (t) => `![i](${t})`, (t) => `**[x](${t})**`, (t) => `[x](${t} "title")`, (t) => `[x]( ${t} )`,
  (t) => `[x](${t.replace("?d=", "?d=`a b`")})`, (t) => `[x](${t}$a b$)`, (t) => t, (t) => `<${t}>`, (t) => `[${"あ".repeat(590)}](${t})`,
  (t) => `\\\\[x](${t})`, (t) => `[x]\n(${t})`, (t) => (/^h/iu.test(t) ? `[a](h[](javascript:a)${t.slice(1)})` : t), (t) => `www.[a](javascript:alert(1))${t}`,
];

test("no http(s) or www address survives in any wrapper or target form, short or very long", () => {
  let checked = 0;
  for (const n of [1, 120]) for (const target of TARGETS) for (const wrap of WRAPPERS) {
    const text = `前 ${wrap(target(n))} 後。`;
    const out = filterReply(text);
    checked++;
    assert.ok(!out.includes(SECRET) && !/https?:|www\./iu.test(out), `n=${n}: ${JSON.stringify(text.slice(0, 80))} -> ${JSON.stringify(out.slice(0, 120))}`);
  }
  assert.ok(checked >= 300);
});

test("a link removed in the middle cannot rejoin its neighbours into a new one", () => {
  for (const text of ["[a](h[](javascript:a)ttps://e.com)", "[a](ht[tp](javascript:a)s://e.com)", "[a](www[](x:).e.com)", "www.[a](javascript:alert(1)).evil.com/x ok",
    "see www.[a](javascript:alert(1))evil.com ok", "http[a](javascript:0)s://evil.com"]) {
    const out = filterReply(text);
    assert.ok(!/https?:\/\/|www\.[a-z]/iu.test(out), `${JSON.stringify(text)} -> ${JSON.stringify(out)}`);
  }
});

test("a long unclosed '[注](' followed by Japanese prose does not delete the prose", () => {
  const prose = "これは通常の説明文です。".repeat(90);
  const text = `導入。[注](${prose} END`;
  assert.equal(filterReply(text), text);
});

test("text with nothing to remove comes back exactly as the model wrote it", () => {
  const samples = ["👨\u200D👩\u200D👧", "❤\uFE0F", "می\u200Cخواهم", "क्\u200Dष", "葛\u{E0100}飾", "🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}", "1\uFE0F\u20E3", "🏳\uFE0F\u200D🌈"];
  for (const sample of samples) {
    const text = `前 ${sample} 後。`;
    assert.equal(filterReply(text), text, JSON.stringify(sample));
  }
  const prose = "細胞は生物の基本単位です。区間 [0, 1) と a[i][j]、【資料】(p.3)、\\[ x^2 \\] を使う。www という語、http のプロトコル、https の話。".repeat(30);
  assert.equal(filterReply(prose), prose);
});

test("an invisible character cannot hide an address, and a reply that lost a link is the filtered view", () => {
  for (const hidden of ["\u200B", "\u200D", "\u200C", "\uFE0F", "\u{E0041}", "\u00AD", "\u2060", "\uFEFF", "\u202E"]) {
    const text = `[x](h${hidden}ttps:${hidden}//e.com/?d=SECRETDATA)と h${hidden}ttps://e.com/?d=SECRETDATA も 👨\u200D👩`;
    const out = filterReply(text);
    assert.ok(!out.includes("SECRETDATA") && !/https?:/iu.test(out), `${JSON.stringify(hidden)}: ${JSON.stringify(out)}`);
  }
});

test("browsers drop tabs and line breaks inside an address, so a split scheme and a leading backtick are still removed", () => {
  for (const text of ["https:`a.evil.com/x?d=SECRETDATA", "https:\ne.com/?d=SECRETDATA", "ht\ntps://e.com/?d=SECRETDATA", "https:\r\n//e.com/?d=SECRETDATA",
    "h\tttps://e.com/?d=SECRETDATA", "http\n:\n//e.com/?d=SECRETDATA", "HTTPS:\\\\e.com/?d=SECRETDATA", "[x](ht\ntps://e.com/?d=SECRETDATA)", "https:`a b`SECRETDATA", "https:$a.evil.com/?d=SECRETDATA"]) {
    const out = redactLinks(`前 ${text} 後`);
    assert.ok(!out.includes("SECRETDATA") && !/https?:|evil\.com|e\.com/iu.test(out), `${JSON.stringify(text)} -> ${JSON.stringify(out)}`);
    assert.ok(out.startsWith("前 ") && out.endsWith(" 後"), JSON.stringify(out));
  }
});

test("whatever follows 'https:' after ONE line break is part of the address, as the browser reads it", () => {
  // The reviewers' cases: the browser drops the line break, so each is "https:" + the rest.
  for (const rest of ["$e.com", "-e.com", "_e.com", "~e.com", "%65.com", "@e.com", ".e.com", "[e].com", "&e.com", "!e.com", "*e.com", "例え.com", "`a.evil.com", "/e.com", "e.com"]) {
    for (const gap of ["\n", "\t", "\r\n", "\t\n\t"]) {
      const text = `前 https:${gap}${rest}/?d=SECRETDATA 後`;
      const out = redactLinks(text);
      assert.ok(!out.includes("SECRETDATA") && !/https?:/iu.test(out), `${JSON.stringify(text)} -> ${JSON.stringify(out)}`);
      assert.ok(out.startsWith("前 ") && out.endsWith(" 後"), JSON.stringify(out));
    }
  }
});

test("a blank line, a heading, a fence or a list marker after 'https:' is not swallowed; a word that starts like an address still is", () => {
  for (const text of ["スキームは https:\n\n次の段落", "https:\n\n## 見出し", "https:\n\n```js\nx\n```", "https:\n\n- 項目", "使うのは http:\r\n\r\n次"]) {
    assert.equal(redactLinks(text), text, JSON.stringify(text));
  }
  // Past a blank line the browser still joins "https:" and what follows when it is copied and pasted.
  for (const text of ["https:\n\n//e.com", "https:\r\n\r\n//e.com", "https:\n\n/e.com", "https:\n\ne.com", "https:\n\n\\\\e.com", "https:\n\n\t/\n/e.com", "https:\n/\n/e.com"]) {
    const out = redactLinks(`前 ${text}/?d=SECRETDATA 後`);
    assert.ok(!out.includes("SECRETDATA") && !/https?:|e\.com/iu.test(out), `${JSON.stringify(text)} -> ${JSON.stringify(out)}`);
    assert.ok(out.startsWith("前 ") && out.endsWith(" 後"), JSON.stringify(out));
  }
});

test("a line that ends in 'https:' takes the first word of the next line, a bare 'https:' before a space does not", () => {
  assert.equal(redactLinks("URL は https:\nHTTP です"), "URL は （リンクは表示されません） です");
  assert.equal(redactLinks("- http: は平文"), "- http: は平文");
  assert.equal(redactLinks("使うのは https: だけ"), "使うのは https: だけ");
});

test("a scheme written in backticks as a word in a sentence is a description and stays; with an address after it, it does not", () => {
  for (const text of ["プロトコルは `https:` です", "URLは `https:` で始まります。`code` です", "`http:` と `https:` の違い", "`ftp:` ではなく `https:`", "`https:`。次の文"]) {
    assert.equal(redactLinks(text), text, text);
  }
  for (const text of ["`https:`//e.com/?d=SECRETDATA", "`https:`e.com/?d=SECRETDATA", "`https:`\\e.com/?d=SECRETDATA", "[x](`https:`//e.com/?d=SECRETDATA)"]) {
    const out = redactLinks(`前 ${text} 後`);
    assert.ok(!out.includes("SECRETDATA") && !/https?:/iu.test(out), `${JSON.stringify(text)} -> ${JSON.stringify(out)}`);
  }
});

test("a scheme in backticks takes the address after it, however the break or separator is written", () => {
  for (const tail of ["\n//evil.com", "\t//evil.com", "\n$e.com", ".evil.com", ";//evil.com", ",//evil.com", ":evil.com", "!evil.com", "\r\n例え.com", "\n\t/evil.com"]) {
    const out = redactLinks(`前 \`https:\`${tail}/?d=SECRETDATA 後`);
    assert.ok(!out.includes("SECRETDATA") && !/https?:|evil|e\.com|例え/iu.test(out), `${JSON.stringify(tail)} -> ${JSON.stringify(out)}`);
    assert.ok(out.startsWith("前 ") && out.endsWith(" 後"), JSON.stringify(out));
  }
  for (const tail of ["\n\n//evil.com", "\r\r//evil.com", "\n\n\n//evil.com", "\n\n/evil.com", "\n\nevil.com", "\n\n/\n/evil.com"]) {
    const out = redactLinks(`前 \`https:\`${tail} 後`);
    assert.ok(!/https?:|evil/iu.test(out), `${JSON.stringify(tail)} -> ${JSON.stringify(out)}`);
  }
  for (const text of ["使うのは `https:`\n\n次の段落", "`https:`\n\n- 項目", "`https:`\n", "`https:`", "`https:` と `http:`"]) assert.equal(redactLinks(text), text, JSON.stringify(text));
});
