// Detection and notification around the email/password sign-in:
//
//   1. Metrics. Every login outcome is logged as one structured line (no
//      email, no IP — just outcome, country and ASN) so failure rate and
//      new-context success rate can be charted from Workers Logs. On top of
//      that, two per-hour counters raise a Slack alert (once per window) when
//      bad attempts or successful sign-ins from never-seen contexts spike —
//      the two signatures of a credential-stuffing run.
//   2. New-context notice. A successful sign-in from a country+network this
//      account hasn't signed in from lately emails the owner. The signal is
//      "country + ASN", not the raw IP, so a phone hopping between addresses
//      of one carrier doesn't generate mail.
//
// Nothing here may ever fail or slow a login: callers hand these promises to
// ctx.waitUntil, and every failure is only logged.
import { sha256Hex } from "./auth.js";
import { postSlackBlocks } from "./slack.js";

export const MONITOR = {
  windowSeconds: 3_600,
  // Wrong-password and wait-refused local logins per window before alerting.
  // Counted separately so hammering one account (all "throttled") can't be
  // used to set off, and thereby mask, the failure alert.
  failureAlert: 100,
  throttledAlert: 300,
  // Sign-ins turned away because password hashing was saturated (503). A few
  // are normal in a burst; many mean an attack on capacity, or that the
  // limit is too small for the real traffic.
  busyAlert: 50,
  // Successful sign-ins, per window, from a context an account with history
  // hadn't used. An account's very first recorded sign-in doesn't count — at
  // rollout that is every existing user.
  newContextSuccessAlert: 10,
  seenMaxContexts: 20,
  seenTtlSeconds: 90 * 86_400,
  // Notice mails per account per day, so a sign-in storm can't mail-bomb the owner.
  noticesPerDay: 3,
};

const RESEND_API_URL = "https://api.resend.com/emails";

/**
 * Pure: records `key` as seen at `now` in `state` ({ entries: { key: ms } }),
 * dropping entries older than `ttlSeconds` and keeping at most `maxEntries`
 * (oldest evicted). `wasEmpty` is true when nothing live was recorded before,
 * i.e. the account has no history to compare against.
 */
export function touchSeenContext(state, key, now, maxEntries, ttlSeconds) {
  const live = Object.entries(state?.entries ?? {}).filter(([, seenAt]) => now - seenAt < ttlSeconds * 1000);
  const entries = Object.fromEntries(live);
  const wasEmpty = live.length === 0;
  const isNew = !(key in entries);
  entries[key] = now;
  const kept = Object.entries(entries).sort((a, b) => b[1] - a[1]).slice(0, maxEntries);
  return { state: { entries: Object.fromEntries(kept) }, isNew, wasEmpty };
}

// The network's registered name is chosen by whoever owns the AS, and ends up
// in a mail to the account owner: keep it to one short printable line.
function cleanLabel(value) {
  return value.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]+/g, " ").trim().slice(0, 64);
}

/** Cloudflare's view of where the request came from, or null when it isn't available. */
export function requestContext(request) {
  const cf = request.cf;
  if (!cf || !cf.country || cf.asn === undefined || cf.asn === null) return null;
  return {
    key: `${cf.country}|${cf.asn}`,
    country: String(cf.country),
    region: typeof cf.region === "string" ? cf.region : "",
    network: typeof cf.asOrganization === "string" && cf.asOrganization ? cleanLabel(cf.asOrganization) : `AS${cf.asn}`,
    asn: cf.asn,
  };
}

async function countAndAlert(env, counterName, threshold, title, detail) {
  // Both counters are named for the clock hour they belong to, so "alert at
  // most once" lines up exactly with "count per hour" instead of drifting
  // with whenever each one's first bump happened.
  const hour = Math.floor(Date.now() / (MONITOR.windowSeconds * 1000));
  const withinThreshold = await env.RATE_COUNTER.getByName(`${counterName}:${hour}`).bump(threshold, MONITOR.windowSeconds);
  if (withinThreshold) return;
  // Over the line: only the first caller in this hour gets to post.
  const first = await env.RATE_COUNTER.getByName(`${counterName}:${hour}:alerted`).bump(1, MONITOR.windowSeconds);
  if (!first) return;
  await postSlackBlocks(env, [
    { type: "header", text: { type: "plain_text", text: title } },
    { type: "section", text: { type: "mrkdwn", text: detail } },
  ]);
}

/**
 * Logs one local-login outcome ("success" | "failure" | "throttled") and
 * feeds the spike alerts. Never throws.
 */
export async function recordLoginOutcome(env, request, outcome, { newContext = false, firstSeen = false } = {}) {
  try {
    const context = requestContext(request);
    console.log(JSON.stringify({
      event: "local_login",
      outcome,
      newContext,
      firstSeen,
      country: context?.country ?? null,
      asn: context?.asn ?? null,
    }));
    if (outcome === "failure") {
      await countAndAlert(
        env, "login-metric:failure", MONITOR.failureAlert,
        "ログイン失敗が急増しています",
        `この1時間で、パスワード違いのログインが${MONITOR.failureAlert}件を超えました。クレデンシャルスタッフィングの可能性があります。Workers Logsで event=local_login を確認してください。`
      );
    } else if (outcome === "throttled") {
      await countAndAlert(
        env, "login-metric:throttled", MONITOR.throttledAlert,
        "ログインの待機が多発しています",
        `この1時間で、待機中として断られたログインが${MONITOR.throttledAlert}件を超えました。特定のアカウントやネットワークが執拗に試されている可能性があります。`
      );
    } else if (outcome === "busy") {
      await countAndAlert(
        env, "login-metric:busy", MONITOR.busyAlert,
        "ログインがハッシュ処理の混雑で断られています",
        `この1時間で、パスワードのハッシュ処理の混雑によって断られたログインが${MONITOR.busyAlert}件を超えました。容量を狙った攻撃か、同時実行の上限が実際の利用に対して小さい可能性があります。Workers Logsで event=local_login outcome=busy を確認してください。`
      );
    } else if (outcome === "success" && newContext) {
      await countAndAlert(
        env, "login-metric:new-context", MONITOR.newContextSuccessAlert,
        "未知の環境からのログイン成功が急増しています",
        `この1時間で、履歴のあるアカウントへの初めての国・ネットワークからのログイン成功が${MONITOR.newContextSuccessAlert}件を超えました。漏えいした認証情報で突破されている可能性があります。`
      );
    }
  } catch (error) {
    console.error(JSON.stringify({ message: "login metrics failed", error: error instanceof Error ? error.message : String(error) }));
  }
}

async function sendSignInNotice(env, email, context, when) {
  const place = [context.country, context.region].filter(Boolean).join(" / ");
  const jst = new Date(when.getTime() + 9 * 3_600_000).toISOString().replace("T", " ").slice(0, 16);
  const response = await fetch(RESEND_API_URL, {
    method: "POST",
    headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, "content-type": "application/json" },
    body: JSON.stringify({
      from: env.RESEND_FROM_EMAIL ?? "Studiquo <onboarding@resend.dev>",
      to: email,
      subject: "Studiquoに新しい環境からログインがありました",
      text: [
        "お使いのStudiquoアカウントに、これまでと異なる環境からログインがありました。",
        "",
        `日時(日本時間): ${jst}`,
        `場所: ${place}`,
        `ネットワーク: ${context.network}`,
        "",
        "ご本人の場合は、このメールは無視してください。",
        "心当たりがない場合は、Studiquoのログイン画面から「パスワードを忘れた場合」で、すぐにパスワードを再設定してください。",
      ].join("\n"),
    }),
  });
  if (!response.ok) throw new Error(`Resend responded ${response.status}`);
}

/**
 * Remembers the country+network this sign-in came from for `email`, and —
 * when `notify` is set and it's one the account hasn't used lately — emails
 * the owner. Returns `{ newContext, firstSeen }` for the metrics. Never throws.
 */
export async function noteSignInContext(env, request, email, { notify }) {
  try {
    const context = requestContext(request);
    if (!context) return { newContext: false, firstSeen: false };
    const emailHash = await sha256Hex(email.trim().toLowerCase());
    const seen = await env.RATE_COUNTER.getByName(`login-seen:${emailHash}`)
      .seenContext(context.key, { maxEntries: MONITOR.seenMaxContexts, ttlSeconds: MONITOR.seenTtlSeconds });
    if (!seen.isNew) return { newContext: false, firstSeen: false };
    // Nothing on record before this sign-in means there is no history to be
    // "new" against: it still gets the notice (a dormant account being
    // taken over looks exactly like this), but it isn't counted as a spike.
    const notified = notify && env.RESEND_API_KEY
      && (await env.RATE_COUNTER.getByName(`login-notice:${emailHash}`).bump(MONITOR.noticesPerDay, 86_400));
    if (notified) {
      try {
        await sendSignInNotice(env, email.trim().toLowerCase(), context, new Date());
      } catch (error) {
        // The context is still recorded; the owner just isn't told.
        console.error(JSON.stringify({ message: "sign-in notice failed", error: error instanceof Error ? error.message : String(error) }));
      }
    }
    return { newContext: !seen.wasEmpty, firstSeen: seen.wasEmpty };
  } catch (error) {
    console.error(JSON.stringify({ message: "sign-in notice failed", error: error instanceof Error ? error.message : String(error) }));
    return { newContext: false, firstSeen: false };
  }
}
