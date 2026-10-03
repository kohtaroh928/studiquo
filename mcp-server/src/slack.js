// Posts a Block Kit message to the operators' Slack channel when
// SLACK_ISSUE_REPORT_WEBHOOK_URL is configured. Shared by the hand-written
// problem reports (issue-reports.js) and the automatic error reports
// (app-errors.js). Slack being unreachable must never fail the request that
// triggered it: whatever it announces is already stored by the time this
// runs, so a failure is only logged.
export async function postSlackBlocks(env, blocks) {
  const webhookURL = env.SLACK_ISSUE_REPORT_WEBHOOK_URL;
  if (!webhookURL) return;
  try {
    await fetch(webhookURL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ blocks }),
    });
  } catch (error) {
    console.error(JSON.stringify({ message: "slack notify failed", error: error instanceof Error ? error.message : String(error) }));
  }
}
