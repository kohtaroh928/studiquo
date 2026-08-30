/**
 * Gemini proxy.
 *
 * The app never holds the Gemini key. It calls these endpoints with its own
 * device token, this Worker adds `GEMINI_API_KEY`, and the answer is passed
 * back. That is what lets the key be rotated, the model be swapped, and the
 * prompts be rewritten without shipping an app update.
 *
 * The endpoints are purpose-specific rather than a generic pass-through. A
 * generic proxy would let anyone holding a device token spend the project's
 * quota on anything at all; here the Worker owns the system prompt and the
 * response schema, and the app only supplies content.
 */

const API_ROOT = "https://generativelanguage.googleapis.com/v1beta/models";

/** Overridable with `wrangler` vars so a model change needs no code change. */
const DEFAULT_CHAT_MODEL = "gemini-3.5-flash";
const DEFAULT_GRADING_MODEL = "gemini-3.7-flash";

/**
 * Tried when the preferred model is busy.
 *
 * Marking wants the strongest model available, but the strongest one is also
 * the most contended — it answered every request with "experiencing high
 * demand" during testing. Falling back keeps a single tap on 採点する from
 * failing outright; the reply is merely from a slightly lesser model.
 */
const FALLBACK_MODEL = "gemini-3.5-flash";

/** Upstream statuses worth trying again rather than surfacing. */
const RETRYABLE = new Set([429, 500, 502, 503, 504]);

/** Soft daily caps per device, so one user cannot drain the shared quota. */
const DEFAULT_CHAT_LIMIT = 120;
const DEFAULT_GRADING_LIMIT = 20;

/**
 * Caps across every device combined.
 *
 * The per-device cap alone is not a defence: these endpoints accept any
 * 32-character bearer token without registration, so anyone can mint a fresh
 * token and reset their own counter. Until the app proves it is genuine (see
 * the App Attest note in the README), this ceiling is what actually bounds
 * the bill if the endpoint is discovered and abused.
 */
const DEFAULT_GLOBAL_CHAT_LIMIT = 1500;
const DEFAULT_GLOBAL_GRADING_LIMIT = 150;

function json(value, status = 200) {
  return Response.json(value, { status, headers: { "cache-control": "no-store" } });
}

function model(env, kind) {
  if (kind === "grading") return env.GEMINI_GRADING_MODEL || DEFAULT_GRADING_MODEL;
  return env.GEMINI_CHAT_MODEL || DEFAULT_CHAT_MODEL;
}

/**
 * A per-device, per-day counter.
 *
 * KV is eventually consistent, so this is a soft cap rather than an exact
 * one — a burst of simultaneous requests can slip a few over. That is fine
 * for its purpose, which is stopping sustained abuse rather than metering.
 */
async function bump(env, counterKey, limit) {
  const used = Number(await env.STUDIQUO_DATA.get(counterKey)) || 0;
  if (used >= limit) return false;
  // Expires on its own, so old counters never accumulate.
  await env.STUDIQUO_DATA.put(counterKey, String(used + 1), { expirationTtl: 172_800 });
  return true;
}

/** Per-device and whole-service caps. Both must pass. */
async function withinQuota(env, key, bucket, limit, globalLimit) {
  const day = new Date().toISOString().slice(0, 10);
  if (!(await bump(env, `ai:global:${bucket}:${day}`, globalLimit))) return false;
  return bump(env, `ai:${bucket}:${key}:${day}`, limit);
}

async function callGemini(env, { kind, systemInstruction, contents, responseSchema, stream }) {
  const key = env.GEMINI_API_KEY;
  if (!key) throw new Error("GEMINI_API_KEY is not configured on this Worker.");

  const method = stream ? "streamGenerateContent?alt=sse" : "generateContent";
  const body = {
    contents,
    systemInstruction: { parts: [{ text: systemInstruction }] },
    generationConfig: {
      // Marking is now streamed like chat is, so the budget follows what the
      // call is for rather than how it is transported: a full rubric plus
      // per-criterion comments does not fit in a chat-sized reply.
      maxOutputTokens: kind === "grading" ? 8192 : 4096,
      ...(responseSchema
        ? { responseMimeType: "application/json", responseSchema }
        : {}),
    },
  };
  const payload = JSON.stringify(body);

  // Preferred model first, then the fallback — skipped when they are the same.
  const preferred = model(env, kind);
  const fallback = env.GEMINI_FALLBACK_MODEL || FALLBACK_MODEL;
  const candidates = preferred === fallback ? [preferred] : [preferred, fallback];

  let last = null;
  for (const name of candidates) {
    for (let attempt = 0; attempt < 2; attempt++) {
      if (last) {
        // Release the body of the response being discarded, and back off a
        // little before asking again.
        await last.body?.cancel().catch(() => {});
        await new Promise(resolve => setTimeout(resolve, 400 * (attempt + 1)));
      }
      const response = await fetch(`${API_ROOT}/${name}:${method}`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          // Sent as a header rather than in the query string so the key never
          // lands in a URL, where it would show up in logs and error traces.
          "x-goog-api-key": key,
        },
        body: payload,
      });
      if (response.ok) return response;
      last = response;
      // A bad request or an unknown model will fail the same way every time;
      // only congestion is worth waiting out.
      if (!RETRYABLE.has(response.status)) return response;
    }
  }
  return last;
}

/** Pulls the text out of a non-streaming Gemini response. */
function textOf(payload) {
  const parts = payload?.candidates?.[0]?.content?.parts ?? [];
  return parts.map(part => part.text ?? "").join("");
}

async function readError(response) {
  const text = await response.text();
  try {
    return JSON.parse(text)?.error?.message ?? text.slice(0, 300);
  } catch {
    return text.slice(0, 300);
  }
}

// MARK: Chat

const CHAT_SYSTEM = `あなたは学習アプリ「Studiquo」に組み込まれた学習パートナーです。相手は勉強中の学生です。

- 答えだけを渡さず、考え方の筋道を示してから答えに導いてください。
- 相手が解いている途中なら、次の一手をひとつだけ示すこと。
- 用語は定義してから使うこと。
- わからないことは推測せず、わからないと言うこと。
- 返答は日本語で、簡潔に。長い前置きは書かないこと。`;

/**
 * Streams a reply as SSE. The upstream SSE is re-emitted as plain
 * `data: {"text": "..."}` lines so the app has one small shape to parse
 * instead of Gemini's full candidate envelope.
 */
async function handleChat(request, env, key, ctx) {
  const payload = await request.json().catch(() => null);
  const turns = Array.isArray(payload?.messages) ? payload.messages : [];
  if (turns.length === 0) return json({ error: "messages is required." }, 400);
  const requestedImages = Array.isArray(payload?.images)
    ? payload.images.map(image => String(image ?? "")).filter(Boolean).slice(0, 4)
    : [];
  const images = requestedImages.filter(isPNGBase64);
  const requiresImage = payload?.requiresImage === true;
  if (requestedImages.length !== images.length) {
    return json({ error: "切り抜き画像の形式が正しくありません。もう一度切り抜いてください。" }, 400);
  }
  if (requiresImage && images.length === 0) {
    return json({ error: "切り抜き画像がAIサーバーに届いていません。もう一度切り抜いてください。" }, 400);
  }

  if (!(await withinQuota(
    env, key, "chat",
    Number(env.CHAT_DAILY_LIMIT) || DEFAULT_CHAT_LIMIT,
    Number(env.GLOBAL_CHAT_DAILY_LIMIT) || DEFAULT_GLOBAL_CHAT_LIMIT
  ))) {
    return json({ error: "今日のAI利用回数の上限に達しました。明日また使えます。" }, 429);
  }

  console.log(JSON.stringify({
    message: "AI chat request accepted",
    imageCount: images.length,
    imageBytesApprox: images.reduce((total, image) => total + Math.floor(image.length * 0.75), 0),
    requiresImage,
  }));

  let system = CHAT_SYSTEM;
  const context = String(payload?.noteContext ?? "").trim();
  if (context) {
    system += `\n\n参考として、学生がいま開いているノートの本文を渡します。質問がこの内容に関係する場合はこれを踏まえて答えてください。関係しない場合は無視してください。\n\n<note>\n${context.slice(0, 8000)}\n</note>`;
  }

  const recentTurns = turns.slice(-20);
  const contents = recentTurns.map((turn, index) => {
    const parts = [{ text: String(turn.text ?? "") }];
    if (images.length && index === recentTurns.length - 1 && turn.role !== "assistant") {
      images.forEach((image, imageIndex) => {
        parts.push({ text: `次の画像はユーザーがノートから切り抜いて添付した画像です（${imageIndex + 1}枚目）。この画像も必ず読んで回答してください。` });
        parts.push({ inlineData: { mimeType: "image/png", data: image } });
      });
    }
    return {
    // Gemini calls the assistant "model"; the app speaks in user/assistant.
    role: turn.role === "assistant" ? "model" : "user",
      parts,
    };
  });

  const upstream = await callGemini(env, {
    kind: "chat",
    systemInstruction: system,
    contents,
    stream: true,
  });
  if (!upstream.ok || !upstream.body) {
    return json({ error: await readError(upstream) }, upstream.status || 502);
  }

  // Pumped through a TransformStream rather than a hand-rolled `pull`
  // source. The previous version kept its partial-line buffer on the
  // underlying-source object (`this.buffer`), which the runtime does not
  // reliably bind — the request hung instead of returning, and the Workers
  // runtime cancelled it. Here the buffer is an ordinary local and the
  // response is returned immediately while the pump runs behind it.
  const { readable, writable } = new TransformStream();

  const pump = (async () => {
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();
    const writer = writable.getWriter();
    let buffer = "";
    let clientGone = false;

    // Every write is guarded. Once the app has the answer it closes the
    // connection, and a write into a stream nobody is reading rejects — the
    // unguarded version then threw again inside its own error handler and
    // left `close()` unsettled, which is what the runtime reported as a hung
    // request. Losing the reader is a normal way for this to end, not a fault.
    const send = async text => {
      if (clientGone) return;
      try {
        await writer.write(encoder.encode(`data: ${JSON.stringify({ text })}\n\n`));
      } catch {
        clientGone = true;
      }
    };

    try {
      for await (const chunk of upstream.body) {
        if (clientGone) break;
        buffer += decoder.decode(chunk, { stream: true });
        // A chunk can split mid-line, so only whole `data:` lines are parsed
        // and the remainder is carried into the next read.
        const lines = buffer.split("\n");
        buffer = lines.pop() ?? "";
        for (const line of lines) {
          if (!line.startsWith("data:")) continue;
          const raw = line.slice(5).trim();
          if (!raw || raw === "[DONE]") continue;
          let text = "";
          try {
            text = textOf(JSON.parse(raw));
          } catch {
            // A partial or unexpected event is skipped rather than failing
            // the whole reply.
            continue;
          }
          if (text) await send(text);
        }
      }
    } catch (error) {
      await send(`\n\n（通信が中断しました: ${error?.message ?? "unknown"}）`);
    } finally {
      // Never allowed to reject: an unsettled close is exactly what hung the
      // request before.
      try {
        await writer.close();
      } catch {
        // Already closed or errored by the client going away.
      }
    }
  })();
  ctx.waitUntil(pump);

  return new Response(readable, {
    headers: {
      "content-type": "text/event-stream",
      "cache-control": "no-store",
      "x-studiquo-images-received": String(images.length),
    },
  });
}

function isPNGBase64(value) {
  return value.length >= 64
    && value.length <= 12_000_000
    && value.startsWith("iVBORw0KGgo")
    && /^[A-Za-z0-9+/]+={0,2}$/.test(value);
}

// MARK: Proof marking

const RUBRIC_SYSTEM = `あなたは数学の証明を採点する教員です。これから問題を渡します（文章のこともあれば、問題集を撮影・切り抜いた画像のこともあります）。模範解答は渡されないこともあります。学生の答案はまだ見せません。この段階では採点基準（ルーブリック）だけを作ってください。

- 模範解答がある場合はそれを論証のステップに分け、各ステップを1つの基準にすること。
- 模範解答がない場合は、その問題を正しく証明するために必要な論証のステップを自分で組み立て、それを基準にすること。
- 画像に複数の問題が写っている場合は、最初の1問だけを対象にすること。
- 各基準には「その点を得るために答案が満たさなければならない条件」を具体的に書くこと。
- 配点の合計は100点にすること。
- 表記の丁寧さより、論理の正しさに配点を厚くすること。
- 基準は4〜8個に収めること。`;

const RUBRIC_SCHEMA = {
  type: "OBJECT",
  properties: {
    criteria: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: {
          name: { type: "STRING" },
          maxPoints: { type: "INTEGER" },
          requirement: { type: "STRING" },
        },
        required: ["name", "maxPoints", "requirement"],
      },
    },
  },
  required: ["criteria"],
};

const GRADE_SYSTEM = `あなたは数学の証明を採点する教員です。学生の答案は、手書きを撮影した画像で渡されることも、文字で入力されることもあります。

採点の手順:
1. まず答案を読み、論証のステップに分けて理解すること。
2. 渡された採点基準の各項目について、答案が条件を満たしているか判定し、部分点を決めること。
3. 誤りを見つけたら、その種類を分類すること。
   - logical_gap: 前のステップから次のステップへの根拠が不足している
   - counterexample: 主張が偽で、反例が存在する
   - definition_error: 定義や定理の使い方が誤っている
   - calculation_error: 論理は正しいが計算が誤っている
   - unjustified_assumption: 証明すべきことを仮定している、条件を勝手に足している
   - presentation: 内容は正しいが記述が不明瞭

重要な原則:
- 模範解答と違う道筋でも、論理が正しければ満点にすること。
- 読み取れない箇所は推測で減点せず、その旨を excerpt に書くこと。
- excerpt には学生自身が書いた表現を短く引用すること。
- suggestion は「次にどう直すか」を1文で書くこと。
- verdict は2文以内で、まず良い点、次に最大の課題を述べること。
- 日本語で書くこと。`;

const GRADE_SCHEMA = {
  type: "OBJECT",
  properties: {
    score: { type: "INTEGER" },
    maxScore: { type: "INTEGER" },
    verdict: { type: "STRING" },
    criteria: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: {
          name: { type: "STRING" },
          earnedPoints: { type: "INTEGER" },
          maxPoints: { type: "INTEGER" },
          comment: { type: "STRING" },
        },
        required: ["name", "earnedPoints", "maxPoints", "comment"],
      },
    },
    issues: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: {
          step: { type: "INTEGER" },
          kindRawValue: {
            type: "STRING",
            enum: [
              "logical_gap",
              "counterexample",
              "definition_error",
              "calculation_error",
              "unjustified_assumption",
              "presentation",
            ],
          },
          excerpt: { type: "STRING" },
          explanation: { type: "STRING" },
          suggestion: { type: "STRING" },
        },
        required: ["step", "kindRawValue", "excerpt", "explanation", "suggestion"],
      },
    },
  },
  required: ["score", "maxScore", "verdict", "criteria", "issues"],
};

async function handleRubric(request, env, key, ctx) {
  if (!(await withinQuota(
    env, key, "grade",
    Number(env.GRADING_DAILY_LIMIT) || DEFAULT_GRADING_LIMIT,
    Number(env.GLOBAL_GRADING_DAILY_LIMIT) || DEFAULT_GLOBAL_GRADING_LIMIT
  ))) {
    return json({ error: "今日の添削回数の上限に達しました。明日また使えます。" }, 429);
  }
  const payload = await request.json().catch(() => null);
  const question = String(payload?.question ?? "").trim();
  const modelAnswer = String(payload?.modelAnswer ?? "").trim();
  const questionImage = String(payload?.questionImageBase64 ?? "");
  // Either a picture of the exercise or a typed model answer is enough to
  // build a scheme from; with neither there is nothing to mark against.
  if (!questionImage && !modelAnswer) {
    return json({ error: "questionImageBase64 or modelAnswer is required." }, 400);
  }

  const parts = [];
  if (questionImage) parts.push({ inlineData: { mimeType: "image/png", data: questionImage } });
  parts.push({
    text: [
      `<問題>\n${question || (questionImage ? "（画像を参照）" : "")}\n</問題>`,
      modelAnswer ? `<模範解答>\n${modelAnswer}\n</模範解答>` : "<模範解答>（なし。問題から必要な論証を自分で組み立てること）</模範解答>",
    ].join("\n\n"),
  });

  return streamJSON(env, {
    kind: "grading",
    systemInstruction: RUBRIC_SYSTEM,
    contents: [{ role: "user", parts }],
    responseSchema: RUBRIC_SCHEMA,
    failureMessage: "採点基準を読み取れませんでした。",
  }, ctx);
}

/**
 * Runs one structured-output call and returns it as SSE.
 *
 * Not because the app wants the answer progressively — it needs the whole
 * JSON — but because reasoning over an image takes long enough that a plain
 * response hit Cloudflare's 100-second ceiling and came back as a 524. An
 * event stream has no such ceiling as long as bytes keep moving, so a
 * heartbeat goes out while waiting and the finished result arrives as the
 * last event. It also gives the app something real to show a student who is
 * watching a spinner.
 */
function streamJSON(env, { kind, systemInstruction, contents, responseSchema, failureMessage }, ctx) {
  const { readable, writable } = new TransformStream();

  const pump = (async () => {
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();
    const writer = writable.getWriter();
    let clientGone = false;

    const emit = async event => {
      if (clientGone) return;
      try {
        await writer.write(encoder.encode(`data: ${JSON.stringify(event)}\n\n`));
      } catch {
        clientGone = true; // The app went away; stop trying to talk to it.
      }
    };

    try {
      // The upstream call is streamed even though the app needs the whole
      // JSON at once. A plain request for it kept coming back 524: reading an
      // image and reasoning about it takes minutes, and a connection that
      // quiet for that long gets cut at both ends — the client's and the
      // Worker's. Streaming keeps bytes moving on both, and the pieces are
      // simply concatenated here.
      const upstream = await callGemini(env, {
        kind,
        systemInstruction,
        contents,
        responseSchema,
        stream: true,
      });

      if (!upstream.ok) {
        await emit({ error: `[${upstream.status}] ${await readError(upstream)}` });
      } else {
        let buffer = "";
        let assembled = "";
        for await (const chunk of upstream.body) {
          buffer += decoder.decode(chunk, { stream: true });
          const lines = buffer.split("\n");
          buffer = lines.pop() ?? "";
          for (const line of lines) {
            if (!line.startsWith("data:")) continue;
            const raw = line.slice(5).trim();
            if (!raw || raw === "[DONE]") continue;
            try {
              assembled += textOf(JSON.parse(raw));
            } catch {
              continue;
            }
          }
          // Doubles as the keep-alive: every piece of upstream progress is
          // one more reason for the client's connection to stay open.
          await emit({ phase: "working", received: assembled.length });
        }
        try {
          await emit({ result: JSON.parse(assembled) });
        } catch {
          await emit({ error: failureMessage });
        }
      }
    } catch (error) {
      await emit({ error: error?.message ?? failureMessage });
    } finally {
      try {
        await writer.close();
      } catch {
        // Already closed by the client going away.
      }
    }
  })();
  ctx.waitUntil(pump);

  return new Response(readable, {
    headers: { "content-type": "text/event-stream", "cache-control": "no-store" },
  });
}

async function handleGrade(request, env, key, ctx) {
  if (!(await withinQuota(
    env, key, "grade",
    Number(env.GRADING_DAILY_LIMIT) || DEFAULT_GRADING_LIMIT,
    Number(env.GLOBAL_GRADING_DAILY_LIMIT) || DEFAULT_GLOBAL_GRADING_LIMIT
  ))) {
    return json({ error: "今日の添削回数の上限に達しました。明日また使えます。" }, 429);
  }
  const payload = await request.json().catch(() => null);
  const question = String(payload?.question ?? "").trim();
  const answerText = String(payload?.answerText ?? "").trim();
  const image = String(payload?.imageBase64 ?? "");
  const questionImage = String(payload?.questionImageBase64 ?? "");
  const criteria = Array.isArray(payload?.criteria) ? payload.criteria : [];
  // The answer may be a photograph of handwriting or typed out in the chat.
  if (!image && !answerText) {
    return json({ error: "imageBase64 or answerText is required." }, 400);
  }
  if (criteria.length === 0) return json({ error: "criteria is required." }, 400);

  const rubricText = criteria
    .map(item => `・${item.name}（${item.maxPoints}点）: ${item.requirement}`)
    .join("\n");

  // The question goes in first so the model reads what was asked before it
  // reads the attempt, in the order a marker would.
  const parts = [];
  if (questionImage) {
    parts.push({ text: "次の画像は問題です。" });
    parts.push({ inlineData: { mimeType: "image/png", data: questionImage } });
  }
  if (image) {
    parts.push({ text: "次の画像は学生の答案です。" });
    parts.push({ inlineData: { mimeType: "image/png", data: image } });
  }
  parts.push({
    text: [
      `<問題>\n${question || (questionImage ? "（画像を参照）" : "")}\n</問題>`,
      `<答案>\n${answerText || "（画像を参照）"}\n</答案>`,
      `<採点基準>\n${rubricText}\n</採点基準>`,
      "上の基準で、答案を採点してください。",
    ].join("\n\n"),
  });

  return streamJSON(env, {
    kind: "grading",
    systemInstruction: GRADE_SYSTEM,
    contents: [{ role: "user", parts }],
    responseSchema: GRADE_SCHEMA,
    failureMessage: "採点結果を読み取れませんでした。",
  }, ctx);
}

/** Returns a `Response`, or `null` when the path is not an AI route. */
export async function handleAI(url, request, env, key, ctx) {
  if (request.method !== "POST") return null;
  let handler;
  switch (url.pathname) {
    case "/api/ai/chat": handler = handleChat; break;
    case "/api/ai/rubric": handler = handleRubric; break;
    case "/api/ai/grade": handler = handleGrade; break;
    default: return null;
  }
  try {
    return await handler(request, env, key, ctx);
  } catch (error) {
    // Without this, a missing GEMINI_API_KEY surfaced as a bare 500 with no
    // hint of the cause.
    return json({ error: error?.message ?? "AI request failed." }, 500);
  }
}
