// Entry point Wrangler loads (see wrangler.jsonc's "main"). Kept as a thin
// re-export so the request-handling logic in app.js can be unit-tested under
// plain Node — `cloudflare:workers` (needed only for the Durable Object
// export below) doesn't exist outside the Workers runtime.
export { default } from "./app.js";
export { ChatRoom } from "./chat-room.js";
export { UserRegistry } from "./user-registry.js";
