// Entry point Wrangler loads (see wrangler.jsonc's "main"). Kept as a thin
// re-export so the request-handling logic in app.js can be unit-tested under
// plain Node — `cloudflare:workers` (needed only for the Durable Object
// export below) doesn't exist outside the Workers runtime.
import app from "./app.js";
import { cleanupScheduledRAG } from "./rag/storage.js";
import { runPrivacyRetention } from "./privacy-retention.js";
import { recoverRawPDFJobs } from "./rag/pdf-job-recovery.js";
export default {
  ...app,
  async scheduled(controller, env, ctx) {
    ctx.waitUntil(runPrivacyRetention(env, controller.scheduledTime));
    ctx.waitUntil(cleanupScheduledRAG(env));
    // Keep cleanup independent of admission flags so revocation can still stop
    // existing jobs. A separate operational switch defaults to disabled.
    if (env.RAG_PDF_CLEANUP_ENABLED === "true")
      ctx.waitUntil(recoverRawPDFJobs(env).catch(() => {
        console.warn(JSON.stringify({event:"rag_pdf_cleanup",outcome:"unavailable"}));
      }));
  },
};
export { ChatRoom } from "./chat-room.js";
export { UserRegistry } from "./user-registry.js";
export { DocumentRoom } from "./document-room.js";
export { RateCounter } from "./rate-counter.js";
export { MCPInbox } from "./mcp-inbox.js";
