// Entry point Wrangler loads (see wrangler.jsonc's "main"). Kept as a thin
// re-export so the request-handling logic in app.ts can be unit-tested under
// plain Node — `cloudflare:workers` (needed only for the Durable Object
// export below) doesn't exist outside the Workers runtime.
import app from "./app.ts";
import { runScheduledPrivacyWork } from "./privacy-retention.ts";
import { CRON_HEARTBEAT_KEY } from "./ops-alerts.ts";
import type { Env } from "./env.ts";
export default {
  ...app,
  async scheduled(controller: { scheduledTime: number | undefined; }, env: Env, ctx: ExecutionContext) {
    // Written first, so that /health shows the schedule is running even if the work below is slow or fails.
    ctx.waitUntil(env.STUDIQUO_DATA.put(CRON_HEARTBEAT_KEY, String(Date.now()), { expirationTtl: 7 * 86_400 }).catch(() => {}));
    ctx.waitUntil(runScheduledPrivacyWork(env, controller.scheduledTime));
  },
};
export { ChatRoom } from "./chat-room.ts";
export { UserRegistry } from "./user-registry.ts";
export { DocumentRoom } from "./document-room.ts";
export { RateCounter } from "./rate-counter.ts";
export { MCPInbox } from "./mcp-inbox.ts";
