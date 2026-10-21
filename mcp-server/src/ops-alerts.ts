// Slack alerts for things the operators should hear about without watching
// the logs. Same manner as the sign-in alerts (login-monitor.ts): a counter
// per clock hour, one post per hour at most, and nothing in the message that
// identifies a person. A failure to alert is only logged: whatever raised the
// alert has already been handled by the caller.
import { postSlackBlocks } from "./slack.ts";
import type { Env } from "./env.ts";

export const ALERT_WINDOW_SECONDS = 3_600;

/** KV key the hourly cron writes on every run; /health reports its age so an outside monitor can notice a stopped schedule. */
export const CRON_HEARTBEAT_KEY = "ops:cron-last-run";

/**
 * Counts one event under `counterName` for this clock hour. Once more than
 * `threshold` events have happened in the hour, the first caller posts
 * `title` and `detail` to Slack; later ones stay quiet until the next hour.
 * `threshold` 0 means the first event of the hour alerts.
 */
export async function countAndAlert(env: Env, counterName: string, threshold: number, title: string, detail: string) {
  const hour = Math.floor(Date.now() / (ALERT_WINDOW_SECONDS * 1000));
  const withinThreshold = await env.RATE_COUNTER.getByName(`${counterName}:${hour}`).bump(threshold, ALERT_WINDOW_SECONDS);
  if (withinThreshold) return;
  const first = await env.RATE_COUNTER.getByName(`${counterName}:${hour}:alerted`).bump(1, ALERT_WINDOW_SECONDS);
  if (!first) return;
  await postSlackBlocks(env, [
    { type: "header", text: { type: "plain_text", text: title } },
    { type: "section", text: { type: "mrkdwn", text: detail } },
  ]);
}

/** countAndAlert that never throws and never makes the caller wait on Slack beyond the call itself. */
export async function noteForAlert(env: Env, counterName: string, threshold: number, title: string, detail: string) {
  try {
    await countAndAlert(env, counterName, threshold, title, detail);
  } catch (error) {
    console.error(JSON.stringify({ message: "ops alert failed", counter: counterName, error: error instanceof Error ? error.message : String(error) }));
  }
}

/** Raises one of the OPS_ALERTS below. Never throws. */
export function raiseAlert(env: Env, alert: { counter: string; threshold: number; title: string; detail: string }) {
  return noteForAlert(env, alert.counter, alert.threshold, alert.title, alert.detail);
}

/** The alerts that exist beyond the sign-in ones, with their thresholds, for docs/MONITORING.md and the tests. */
export const OPS_ALERTS = {
  serverError: { counter: "ops:5xx", threshold: 20, title: "サーバーエラー(500)が急増しています", detail: "この1時間で、リクエストが予期しない例外で失敗した件数が20件を超えました。Workers Logsで message=\"request failed\" を確認してください。" },
  aiUpstream: { counter: "ops:ai-upstream", threshold: 30, title: "AIプロバイダーのエラーが急増しています", detail: "この1時間で、AIプロバイダーが500番台で応答した、または呼び出しが失敗した件数が30件を超えました。Workers Logsで message=\"AI upstream refused\" / \"AI request failed\" を確認し、プロバイダーの障害情報を見てください。" },
  snapshotStore: { counter: "ops:snapshot-store", threshold: 5, title: "スナップショットの保存が失敗しています", detail: "この1時間で、同期スナップショットの保存失敗が5件を超えました。KVの上限や障害の可能性があります。Workers Logsで message=\"snapshot could not be stored\" を確認してください。" },
  retentionBacklog: { counter: "ops:retention-backlog", threshold: 0, title: "プライバシー保持ジョブが滞留しています", detail: "保持期限を過ぎたデータが残っています(1回の実行で処理できる件数を超えた、または削除に失敗しています)。次の実行で解消するか見て、続く場合は docs/RUNBOOK.md の手順で確認してください。" },
  deletionRetry: { counter: "ops:deletion-retry", threshold: 3, title: "アカウント削除のやり直しが失敗しています", detail: "この1時間で、削除ジョブの再試行が3件を超えて失敗しました。削除が終わらないアカウントが残っている可能性があります。Workers Logsで message=\"privacy deletion retry failed\" を確認してください。" },
  providerDeletionKey: { counter: "ops:provider-deletion-key", threshold: 0, title: "外部サービスの削除が待っています", detail: "RevenueCatなどへの削除予約がありますが、REVENUECAT_SECRET_API_KEY が設定されていないため実行できません。キーを設定してください。" },
  refreshTokenReuse: { counter: "ops:refresh-reuse", threshold: 2, title: "MCPのリフレッシュトークンの再利用を検知しました", detail: "この1時間で、使用済みのMCPリフレッシュトークンが再利用され、接続を失効させた件数が2件を超えました。トークンが盗まれた可能性があります。Workers Logsで message=\"mcp refresh token reused\" を確認してください。" },
} as const;
