// Entry point Wrangler loads (see wrangler.jsonc's "main"). Kept as a thin
// re-export so the request-handling logic in app.ts can be unit-tested under
// plain Node — `cloudflare:workers` (needed only for the Durable Object
// export below) doesn't exist outside the Workers runtime.
import app from "./app.ts";
import { cleanupScheduledRAG } from "./rag/storage.ts";
import { runScheduledPrivacyWork } from "./privacy-retention.ts";
import { recoverRawPDFJobs } from "./rag/pdf-job-recovery.ts";
import type { Env } from "./env.ts";
export default {
  ...app,
  async scheduled(controller: { scheduledTime: number | undefined; }, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(runScheduledPrivacyWork(env, controller.scheduledTime));
    ctx.waitUntil(cleanupScheduledRAG(env));
    // Keep cleanup independent of admission flags so revocation can still stop
    // existing jobs. A separate operational switch defaults to disabled.
    if (env.RAG_PDF_CLEANUP_ENABLED === "true")
      ctx.waitUntil(recoverRawPDFJobs(env).catch(() => {
        console.warn(JSON.stringify({event:"rag_pdf_cleanup",outcome:"unavailable"}));
      }));
  },
};
export { ChatRoom } from "./chat-room.ts";
export { UserRegistry } from "./user-registry.ts";
export { DocumentRoom } from "./document-room.ts";
export { RateCounter } from "./rate-counter.ts";
export { MCPInbox } from "./mcp-inbox.ts";
