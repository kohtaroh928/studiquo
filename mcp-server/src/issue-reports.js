// Lets a signed-in user report an in-app problem straight from the home
// screen's megaphone button. Every report is stored in KV for a later look,
// and — when SLACK_ISSUE_REPORT_WEBHOOK_URL is configured — also posted to
// Slack immediately, the way TestFlight's shake-to-report or Instabug's
// floating button surface a report to the people watching for it.
//
// The optional screenshot is opt-in on the client (off by default, previewed
// to the reporter before anything is sent — see ReportIssueSheet in the app)
// since it can capture a friend's chat message or private note content.
// Once sent, it's served back from GET .../screenshot at an unguessable,
// unauthenticated URL purely so Slack's own link-preview fetch — which
// carries no bearer token — can render it inline. The random report id is
// the only thing standing between a viewer and the image, the same trust
// model as any other unlisted share link.
import { isRevoked } from "./revocation.js";
import { isExpired } from "./token.js";
import { checkRateLimit } from "./rate-limit.js";
import { bearerToken, sha256Hex } from "./auth.js";
import { json, readJSONLimited } from "./http.js";
import { realSession } from "./session.js";

const MAX_DESCRIPTION_LENGTH = 2_000;
// A JPEG/PNG screenshot base64-encoded is ~33% larger than its raw bytes;
// this bounds the decoded size the same way MAX_AVATAR_BYTES bounds a
// profile photo in chat.js.
const MAX_SCREENSHOT_BYTES = 3_000_000;
const MAX_UPLOAD_BODY = 4_200_000;
const ALLOWED_SCREENSHOT_CONTENT_TYPES = new Set(["image/jpeg", "image/png"]);
// Reports are kept long enough to review at leisure without becoming a
// permanent record — matches the bearer token's own validity window
// (MCPCloudCredentials.validityPeriod in ContentView.swift) so nothing here
// outlives the session that filed it by much.
const REPORT_TTL_SECONDS = 90 * 24 * 60 * 60;

function truncate(value, max) {
  return typeof value === "string" ? value.slice(0, max) : "";
}

async function postToSlack(env, report, screenshotURL) {
  const webhookURL = env.SLACK_ISSUE_REPORT_WEBHOOK_URL;
  if (!webhookURL) return;
  const context = [
    report.appVersion && `v${report.appVersion}`,
    report.osVersion && `iOS ${report.osVersion}`,
    report.deviceModel,
    report.language,
  ].filter(Boolean).join(" ・ ");
  const blocks = [
    { type: "header", text: { type: "plain_text", text: "📣 studiquo エラー報告", emoji: true } },
    { type: "section", text: { type: "mrkdwn", text: report.description } },
    { type: "context", elements: [{ type: "mrkdwn", text: context || "端末情報なし" }] },
  ];
  if (screenshotURL) {
    blocks.push({ type: "image", image_url: screenshotURL, alt_text: "報告時のスクリーンショット" });
  }
  try {
    await fetch(webhookURL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ blocks }),
    });
  } catch (error) {
    // Slack being unreachable must never fail the report itself — it's
    // already durably stored in KV by the time this runs.
    console.error(JSON.stringify({ message: "issue report slack notify failed", error: error instanceof Error ? error.message : String(error) }));
  }
}

export async function handleIssueReports(url, request, env) {
  if (!url.pathname.startsWith("/api/issue-reports")) return null;

  // Unauthenticated on purpose — see the file header. Only reachable by
  // guessing (or being handed) a specific report's random id.
  const screenshotMatch = /^\/api\/issue-reports\/([0-9a-f-]{36})\/screenshot$/.exec(url.pathname);
  if (screenshotMatch && request.method === "GET") {
    const screenshot = await env.STUDIQUO_DATA.get(`issue-report-screenshot:${screenshotMatch[1]}`, "json");
    if (!screenshot) return json({ error: "Not found" }, 404);
    const bytes = Uint8Array.from(atob(screenshot.data), c => c.charCodeAt(0));
    return new Response(bytes, {
      status: 200,
      headers: { "content-type": screenshot.contentType, "cache-control": "private, max-age=300" },
    });
  }

  if (url.pathname !== "/api/issue-reports" || request.method !== "POST") return null;

  const token = bearerToken(request);
  if (!token) return json({ error: "Authentication required." }, 401);
  if (isExpired(token)) return json({ error: "This token has expired. Reconnect from Studiquo to get a new one." }, 401);
  const session = await realSession(env, token);
  if (!session) return json({ error: "Reconnect from Studiquo to get a new token." }, 401);
  const key = await sha256Hex(token);
  if (await isRevoked(env, key)) return json({ error: "This token has been revoked. Reconnect from Studiquo to get a new one." }, 401);

  // Occasional-action budget like RATE_LIMIT_CHAT_FRIEND_ADD's in chat.js —
  // reporting isn't something a genuine user does rapidly, so a burst is
  // itself worth capping rather than something normal use would ever hit.
  const allowed = await checkRateLimit(env.RATE_LIMIT_ISSUE_REPORT, key);
  if (!allowed) return json({ error: "Too many reports. Please slow down." }, 429);

  const body = await readJSONLimited(request, MAX_UPLOAD_BODY);
  if (!body) return json({ error: "Invalid request." }, 400);

  const description = truncate(body.description, MAX_DESCRIPTION_LENGTH).trim();
  if (!description) return json({ error: "description is required." }, 400);

  let screenshot = null;
  if (body.screenshot && typeof body.screenshot === "object") {
    const contentType = String(body.screenshot.contentType ?? "");
    const data = String(body.screenshot.data ?? "");
    if (!ALLOWED_SCREENSHOT_CONTENT_TYPES.has(contentType) || !data) {
      return json({ error: "Invalid screenshot." }, 400);
    }
    if (Math.floor(data.length * 3 / 4) > MAX_SCREENSHOT_BYTES) {
      return json({ error: "Invalid screenshot." }, 400);
    }
    screenshot = { contentType, data };
  }

  const id = crypto.randomUUID();
  const report = {
    id,
    reporterKey: key,
    description,
    appVersion: truncate(body.appVersion, 40),
    osVersion: truncate(body.osVersion, 40),
    deviceModel: truncate(body.deviceModel, 60),
    language: truncate(body.language, 20),
    hasScreenshot: Boolean(screenshot),
    createdAt: Date.now(),
  };

  await env.STUDIQUO_DATA.put(`issue-report:${id}`, JSON.stringify(report), { expirationTtl: REPORT_TTL_SECONDS });
  if (screenshot) {
    await env.STUDIQUO_DATA.put(`issue-report-screenshot:${id}`, JSON.stringify(screenshot), { expirationTtl: REPORT_TTL_SECONDS });
  }

  const screenshotURL = screenshot ? `${url.origin}/api/issue-reports/${id}/screenshot` : null;
  await postToSlack(env, report, screenshotURL);

  return json({ reported: true, id });
}
