// Entry point Wrangler loads (see wrangler.jsonc's "main"). Kept as a thin
// re-export so the request-handling logic in app.ts can be unit-tested under
// plain Node — `cloudflare:workers` (needed only for the Durable Object
// export below) doesn't exist outside the Workers runtime.
import app from "./app.ts";
import { runScheduledPrivacyWork } from "./privacy-retention.ts";
export default {
  ...app,
  async scheduled(controller, env, ctx) {
    ctx.waitUntil(runScheduledPrivacyWork(env, controller.scheduledTime));
  },
};
export { ChatRoom } from "./chat-room.ts";
export { UserRegistry } from "./user-registry.ts";
export { DocumentRoom } from "./document-room.ts";
export { RateCounter } from "./rate-counter.ts";
export { MCPInbox } from "./mcp-inbox.ts";
