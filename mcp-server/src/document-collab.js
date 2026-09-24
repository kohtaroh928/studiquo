import { json, readJSONLimited as readJSONLimitedShared } from "./http.js";

// A full block snapshot for a modest document (well past what any
// reasonably-sized study document needs) plus JSON overhead — same
// reasoning as chat.js's MAX_BODY, scaled up since this carries a whole
// document instead of one message.
const MAX_BODY = 500_000;
const PROPOSE_LIMIT_PER_MINUTE = 30;
// Matches chat.js's own RATE_LIMIT_CHAT_FRIEND_ADD budget — inviting a
// collaborator is the same kind of occasional "add a person" action, not a
// fast-paced one, so it gets the same tight budget rather than propose's
// higher one meant for ordinary editing.
const INVITE_LIMIT_PER_MINUTE = 5;
const WINDOW_SECONDS = 60;
// Matches chat.js's own FRIEND_CODE_PATTERN — the client only ever knows a
// collaborator by their friend code (as shown in the existing friend list),
// never their raw userKey, so invite resolves a code the same way chat.js
// resolves one when adding a friend.
const FRIEND_CODE_PATTERN = /^[A-Z0-9]{6,32}$/;

function parseFriendCode(body) {
  const code = String(body?.code ?? "").trim().toUpperCase();
  return FRIEND_CODE_PATTERN.test(code) ? code : null;
}

async function friendDisplayName(env, userKey) {
  const user = await env.STUDIQUO_DATA.get(`chat:user:${userKey}`, "json");
  return user?.name ?? null;
}

async function readBody(request, maxBytes = MAX_BODY) {
  return readJSONLimitedShared(request, maxBytes);
}

// A RateCounter Durable Object soft cap (see rate-counter.js), the same one
// ai.js's usage quotas use — deliberately not routed through
// checkRateLimit()/the Cloudflare Rate Limiting binding those use, since
// that binding is provisioned per endpoint in the Cloudflare dashboard and
// this endpoint doesn't have one of its own yet.
async function withinLimit(env, keyPrefix, key, limit) {
  return env.RATE_COUNTER.getByName(`${keyPrefix}:${key}`).bump(limit, WINDOW_SECONDS);
}

// DocumentRoom.requireParticipant/requireReviewer throw a plain
// Error("Forbidden") for a caller without room access — without this, that
// propagates uncaught up to app.js's catch-all and comes back as a generic
// 500 instead of a proper 403. Mirrors chat.js's roomForbiddenResponse.
function roomForbiddenResponse(error) {
  if (error instanceof Error && error.message === "Forbidden") {
    return json({ error: "You do not have access to this document room." }, 403);
  }
  return null;
}

async function roomResponse(promise) {
  try {
    return json(await promise);
  } catch (error) {
    const forbidden = roomForbiddenResponse(error);
    if (forbidden) return forbidden;
    throw error;
  }
}

/**
 * Server-side half of the collaborative document review model from the
 * design's change-tracking step: a `DocumentRoom` Durable Object per shared
 * document (mirroring `ChatRoom`'s pattern), holding the reviewed block
 * text plus any still-pending change proposals. The client mints the room
 * ID itself (a random 64-hex-character string, the same shape chat's own
 * sha256-derived room IDs happen to have) when first turning collaboration
 * on for a document — unlike a chat room, a document room isn't derived
 * from exactly two participants' keys, since it can have any number of
 * invited editors/reviewers.
 *
 * `key` is the caller's already-authenticated session key — this handler
 * runs inside app.js's existing bearer-token gate, the same way
 * `handleAI` does, rather than performing its own auth like `handleChat`
 * does (chat's early registration exists only for its own pre-token
 * sign-in exchange endpoints, which this has no equivalent of).
 */
export async function handleDocumentCollab(url, request, env, key) {
  if (!url.pathname.startsWith("/api/document/")) return null;

  const initMatch = /^\/api\/document\/rooms\/([a-f0-9]{64})\/init$/.exec(url.pathname);
  if (initMatch && request.method === "POST") {
    const body = await readBody(request);
    const blocks = Array.isArray(body?.blocks) ? body.blocks : [];
    return json(await env.DOCUMENT_ROOM.getByName(initMatch[1]).initialize(key, blocks));
  }

  const inviteMatch = /^\/api\/document\/rooms\/([a-f0-9]{64})\/invite$/.exec(url.pathname);
  if (inviteMatch && request.method === "POST") {
    // Without this, an attacker could brute-force friend codes against this
    // endpoint at unlimited speed — codes are a large enough keyspace that
    // this alone doesn't make guessing one practical, but every other
    // "resolve a code" endpoint in this codebase is already rate-limited,
    // and this one was the one gap.
    const allowed = await withinLimit(env, "document-invite", key, INVITE_LIMIT_PER_MINUTE);
    if (!allowed) return json({ error: "Too many invites. Please slow down." }, 429);
    const body = await readBody(request);
    const code = parseFriendCode(body);
    const role = String(body?.role ?? "");
    // Returning a distinct 404 (rather than folding this into the generic
    // 400 below) lets the client tell "that's not a friend code" apart from
    // "that friend code isn't registered to anyone" in its own UI copy.
    if (!code) return json({ error: "Invalid code." }, 400);
    const userKey = await env.STUDIQUO_DATA.get(`chat:code:${code}`);
    if (!userKey) return json({ error: "No user found for that code." }, 404);
    try {
      return json(await env.DOCUMENT_ROOM.getByName(inviteMatch[1]).invite(key, userKey, role));
    } catch (error) {
      const forbidden = roomForbiddenResponse(error);
      if (forbidden) return forbidden;
      if (error instanceof Error && error.message === "InvalidRole") return json({ error: "role must be \"editor\" or \"reviewer\"." }, 400);
      throw error;
    }
  }

  const participantsMatch = /^\/api\/document\/rooms\/([a-f0-9]{64})\/participants$/.exec(url.pathname);
  if (participantsMatch && request.method === "GET") {
    try {
      const participants = await env.DOCUMENT_ROOM.getByName(participantsMatch[1]).listParticipants(key);
      // The room only knows each participant's opaque userKey — resolve a
      // display name from the same chat:user: record the friend list already
      // reads, so the UI can show "田中さん" instead of a hash.
      const named = await Promise.all(
        participants.map(async participant => ({ ...participant, name: await friendDisplayName(env, participant.userKey) }))
      );
      return json(named);
    } catch (error) {
      const forbidden = roomForbiddenResponse(error);
      if (forbidden) return forbidden;
      throw error;
    }
  }

  const stateMatch = /^\/api\/document\/rooms\/([a-f0-9]{64})\/state$/.exec(url.pathname);
  if (stateMatch && request.method === "GET") {
    return roomResponse(env.DOCUMENT_ROOM.getByName(stateMatch[1]).getState(key));
  }

  const proposeMatch = /^\/api\/document\/rooms\/([a-f0-9]{64})\/propose$/.exec(url.pathname);
  if (proposeMatch && request.method === "POST") {
    // Without this, a single compromised or misbehaving client could flood
    // a room (and this Durable Object's storage) with unlimited proposals —
    // same reasoning as chat.js's own message-send limit.
    const allowed = await withinLimit(env, "document-propose", key, PROPOSE_LIMIT_PER_MINUTE);
    if (!allowed) return json({ error: "Too many proposed changes. Please slow down." }, 429);
    const body = await readBody(request);
    const blockOrder = Number(body?.blockOrder);
    const previousText = String(body?.previousText ?? "").slice(0, 20_000);
    const newText = String(body?.newText ?? "").slice(0, 20_000);
    if (!Number.isSafeInteger(blockOrder) || blockOrder < 0) return json({ error: "Invalid blockOrder." }, 400);
    return roomResponse(env.DOCUMENT_ROOM.getByName(proposeMatch[1]).proposeChange(key, blockOrder, previousText, newText));
  }

  const reviewMatch = /^\/api\/document\/rooms\/([a-f0-9]{64})\/changes\/(\d+)\/review$/.exec(url.pathname);
  if (reviewMatch && request.method === "POST") {
    const changeID = Number(reviewMatch[2]);
    const body = await readBody(request);
    const decision = String(body?.decision ?? "");
    try {
      const result = await env.DOCUMENT_ROOM.getByName(reviewMatch[1]).reviewChange(key, changeID, decision);
      if (result.status === "not_found") return json({ error: "Change not found." }, 404);
      return json(result);
    } catch (error) {
      const forbidden = roomForbiddenResponse(error);
      if (forbidden) return forbidden;
      if (error instanceof Error && error.message === "InvalidDecision") return json({ error: "decision must be \"accept\" or \"reject\"." }, 400);
      throw error;
    }
  }

  return json({ error: "Not found" }, 404);
}
