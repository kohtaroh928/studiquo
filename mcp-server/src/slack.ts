// Posts a Block Kit message to the operators' Slack channel when
// SLACK_ISSUE_REPORT_WEBHOOK_URL is configured. Shared by the hand-written
// problem reports (issue-reports.ts) and the automatic error reports
// (app-errors.ts). Slack being unreachable must never fail the request that
// triggered it: whatever it announces is already stored by the time this
// runs, so a failure is only logged.
import type { Env } from "./env.ts";
import { environmentTag } from "./environment.ts";

// On a non-production deployment every message says so: the header (or a
// leading line when there is none) and the plain-text fallback that shows in
// notifications. Production's payload is left exactly as it was.
export function markedPayload(env: Env, blocks: unknown[]): { blocks: unknown[]; text?: string } {
  const tag = environmentTag(env);
  if (!tag) return { blocks };
  const [first, ...rest] = blocks as any[];
  const notice = { type: "context", elements: [{ type: "mrkdwn", text: `*[${tag}]* ${tag}環境(テスト用)からの通知です。本番ではありません` }] };
  if (first?.type === "header" && typeof first.text?.text === "string") {
    return { blocks: [{ ...first, text: { ...first.text, text: `[${tag}] ${first.text.text}` } }, notice, ...rest], text: `[${tag}] ${first.text.text}` };
  }
  return { blocks: [notice, ...blocks], text: `[${tag}] studiquo通知` };
}

export async function postSlackBlocks(env: Env, blocks: unknown[]): Promise<void> {
  const webhookURL = env.SLACK_ISSUE_REPORT_WEBHOOK_URL;
  if (!webhookURL) return;
  try {
    await fetch(webhookURL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(markedPayload(env, blocks)),
    });
  } catch (error) {
    console.error(JSON.stringify({ message: "slack notify failed", error: error instanceof Error ? error.message : String(error) }));
  }
}
