import { blockedBetween } from "./block-check.ts";
import { json, readJSONLimited as readJSONLimitedShared } from "./http.ts";
import { sendPush } from "./push.ts";
import { roomMembershipKey } from "./document-room-store.ts";
import type { Env } from "./env.ts";
import { nextCursor } from "./kv.ts";
import type { ChatUser } from "./records.ts";

/** document-invite:<user>:<room>: an offer to join a shared document, until it is answered. */
interface DocumentInvite {
  inviterKey: string;
  inviterName?: string | null;
  role: string;
  createdAt: number;
}

// A full block snapshot for a modest document (well past what any
// reasonably-sized study document needs) plus JSON overhead — same
// reasoning as chat.ts's MAX_BODY, scaled up since this carries a whole
// document instead of one message.
const MAX_BODY = 500_000;
const PROPOSE_LIMIT_PER_MINUTE = 30;
// Matches chat.ts's own RATE_LIMIT_CHAT_FRIEND_ADD budget — inviting a
// collaborator is the same kind of occasional "add a person" action, not a
// fast-paced one, so it gets the same tight budget rather than propose's
// higher one meant for ordinary editing.
const INVITE_LIMIT_PER_MINUTE = 5;
const WINDOW_SECONDS = 60;
// An invitation is only an offer: the person is seated in the room when they
// accept it. Left unanswered it lapses, and one person can only be holding so
// many at once (a stranger's spam cannot pile up without bound).
const INVITE_TTL_SECONDS = 14 * 24 * 3_600;
const MAX_PENDING_INVITES = 20;
const RESPOND_LIMIT_PER_MINUTE = 20;

export function pendingInviteKey(userKey: string, roomID: string) {
  return `doc-invite:${userKey}:${roomID}`;
}

async function pendingInviteNames(env: Env, userKey: string) {
  const prefix = pendingInviteKey(userKey, "");
  const names = [];
  let cursor;
  do {
    const page = await env.STUDIQUO_DATA.list({ prefix, cursor });
    for (const item of page.keys ?? []) names.push(item.name);
    cursor = nextCursor(page);
  } while (cursor);
  return names;
}
// Creating a room is a rare action (turning collaboration on for a document),
// and every room is a Durable Object that stays in storage, so it gets an
// hourly budget rather than the per-minute one the other actions use.
const INIT_LIMIT_PER_HOUR = 20;
const INIT_WINDOW_SECONDS = 3_600;
// Matches chat.ts's own FRIEND_CODE_PATTERN — the client only ever knows a
// collaborator by their friend code (as shown in the existing friend list),
// never their raw userKey, so invite resolves a code the same way chat.ts
// resolves one when adding a friend.
const FRIEND_CODE_PATTERN = /^[A-Z0-9]{6,32}$/;

function parseFriendCode(body: { code: unknown; }) {
  const code = String(body?.code ?? "").trim().toUpperCase();
  return FRIEND_CODE_PATTERN.test(code) ? code : null;
}

async function friendDisplayName(env: Env, userKey: string) {
  const user = await env.STUDIQUO_DATA.get<ChatUser>(`chat:user:${userKey}`, "json");
  return user?.name ?? null;
}

async function readBody(request: Request, maxBytes = MAX_BODY) {
  return readJSONLimitedShared(request, maxBytes);
}

// A RateCounter Durable Object soft cap (see rate-counter.ts), the same one
// ai.ts's usage quotas use — deliberately not routed through
// checkRateLimit()/the Cloudflare Rate Limiting binding those use, since
// that binding is provisioned per endpoint in the Cloudflare dashboard and
// this endpoint doesn't have one of its own yet.
async function withinLimit(env: Env, keyPrefix: string, key: string, limit: number, windowSeconds = WINDOW_SECONDS) {
  return env.RATE_COUNTER.getByName(`${keyPrefix}:${key}`).bump(limit, windowSeconds);
}

// The caller's own record, read through their registry object when there is
// one (a plain KV read can be a minute behind a friend removal).
async function chatUser(env: Env, userKey: string) {
  const registered = env.USER_REGISTRY ? await env.USER_REGISTRY.getByName(userKey).getUser(userKey) : null;
  return registered ?? await env.STUDIQUO_DATA.get<ChatUser>(`chat:user:${userKey}`, "json");
}

// DocumentRoom.requireParticipant/requireReviewer throw a plain
// Error("Forbidden") for a caller without room access — without this, that
// propagates uncaught up to app.ts's catch-all and comes back as a generic
// 500 instead of a proper 403. Mirrors chat.ts's roomForbiddenResponse.
function roomForbiddenResponse(error: unknown) {
  if (error instanceof Error && error.message === "Forbidden") {
    return json({ error: "You do not have access to this document room." }, 403);
  }
  return null;
}

async function recordRoomMembership(env: Env, userKey: string, roomID: string, role: string | ArrayBuffer | ArrayBufferView<ArrayBufferLike> | ReadableStream<unknown>) {
  await env.STUDIQUO_DATA.put(roomMembershipKey(userKey, roomID), role);
}

async function roomResponse(promise: unknown) {
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
 * runs inside app.ts's existing bearer-token gate, the same way
 * `handleAI` does, rather than performing its own auth like `handleChat`
 * does (chat's early registration exists only for its own pre-token
 * sign-in exchange endpoints, which this has no equivalent of).
 */
export async function handleDocumentCollab(url: URL, request: Request, env: Env, key: string, ctx: ExecutionContext) {
  if (!url.pathname.startsWith("/api/document/")) return null;

  const initMatch = /^\/api\/document\/rooms\/([a-f0-9]{64})\/init$/.exec(url.pathname);
  if (initMatch && request.method === "POST") {
    const allowed = await withinLimit(env, "document-init", key, INIT_LIMIT_PER_HOUR, INIT_WINDOW_SECONDS);
    if (!allowed) return json({ error: "Too many rooms created. Please try again later." }, 429);
    const body = await readBody(request);
    const blocks = Array.isArray(body?.blocks) ? body.blocks : [];
    const room = env.DOCUMENT_ROOM.getByName(initMatch[1]);
    const result = await room.initialize(key, blocks);
    // Which rooms an account is in, so deleting the account can find them: a
    // room is only reachable by its id, and the room itself knows its members
    // by opaque keys. Written when the caller owns the room. An
    // `already_initialized` answer counts too when the room says the caller is
    // its owner: the first attempt may have created the room and then failed
    // before this entry was written, and the client's retry lands here.
    if (result?.status === "initialized" || (await room.roleOf(key)) === "owner") {
      await recordRoomMembership(env, key, initMatch[1], "owner");
    }
    return json(result);
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
    if (!code) return json({ error: "Invalid code." }, 400);
    // Only a friend can be added to a document. Without this, anyone who knew a
    // friend code could seat a stranger in a room whose content they control
    // and send them a push; it also made this route an oracle for which codes
    // exist. A blocked pair cannot be invited either way round.
    const owner = await chatUser(env, key);
    const friend = (owner?.friends ?? []).find(item => item.code === code);
    if (!friend) return json({ error: "You can only invite your own friends." }, 400);
    if (await blockedBetween(env, key, friend)) {
      return json({ error: "This friend cannot be invited right now." }, 403);
    }
    // A friend whose account has since gone.
    const userKey = await env.STUDIQUO_DATA.get(`chat:code:${code}`);
    if (!userKey) return json({ error: "No user found for that code." }, 404);
    try {
      const room = env.DOCUMENT_ROOM.getByName(inviteMatch[1]);
      if ((await room.roleOf(key)) !== "owner") return roomForbiddenResponse(new Error("Forbidden"));
      if (role !== "editor" && role !== "reviewer") return json({ error: "role must be \"editor\" or \"reviewer\"." }, 400);
      if (userKey === key) return json({ error: "role must be \"editor\" or \"reviewer\"." }, 400);
      // Someone who already took part has said yes before: a new role for them
      // is applied as it was.
      if (await room.roleOf(userKey)) {
        const result = await room.invite(key, userKey, role);
        await recordRoomMembership(env, userKey, inviteMatch[1], role);
        return json(result);
      }
      const inviteKey = pendingInviteKey(userKey, inviteMatch[1]);
      if (!(await env.STUDIQUO_DATA.get(inviteKey)) && (await pendingInviteNames(env, userKey)).length >= MAX_PENDING_INVITES) {
        return json({ error: "This friend has too many pending invitations." }, 429);
      }
      const inviterName = await friendDisplayName(env, key);
      await env.STUDIQUO_DATA.put(inviteKey, JSON.stringify({ inviterKey: key, inviterName, role, createdAt: Date.now() }), { expirationTtl: INVITE_TTL_SECONDS });
      // The friend code was resolved before this ran. If that account was
      // deleted in between, its deletion has already passed the point where it
      // collects its invitations, and the offer would stay behind under a key
      // nothing can name again. Take it back.
      if (!(await env.STUDIQUO_DATA.get(`chat:user:${userKey}`))) {
        await env.STUDIQUO_DATA.delete(inviteKey);
        return json({ error: "No user found for that code." }, 404);
      }
      const delivery = sendPush(env, userKey, {
        category: "shareInvite",
        title: "共有招待",
        body: `${inviterName || "フレンド"}さんからノートの共有招待が届きました。承諾すると参加します。`,
        data: { route: "shareInvite", roomID: inviteMatch[1] },
      });
      if (ctx?.waitUntil) ctx.waitUntil(delivery);
      else await delivery;
      return json({ status: "pending" });
    } catch (error) {
      const forbidden = roomForbiddenResponse(error);
      if (forbidden) return forbidden;
      if (error instanceof Error && error.message === "InvalidRole") return json({ error: "role must be \"editor\" or \"reviewer\"." }, 400);
      throw error;
    }
  }

  // The invitations waiting for this person's answer.
  if (url.pathname === "/api/document/invites" && request.method === "GET") {
    const invites: { roomID: string; role: string; inviterName: string | null; createdAt: number }[] = [];
    for (const name of await pendingInviteNames(env, key)) {
      const invite = await env.STUDIQUO_DATA.get<DocumentInvite>(name, "json");
      if (!invite) continue;
      invites.push({ roomID: name.slice(pendingInviteKey(key, "").length), role: invite.role, inviterName: invite.inviterName ?? null, createdAt: invite.createdAt });
    }
    return json(invites.sort((left, right) => right.createdAt - left.createdAt));
  }

  const respondMatch = /^\/api\/document\/rooms\/([a-f0-9]{64})\/invite\/(accept|decline)$/.exec(url.pathname);
  if (respondMatch && request.method === "POST") {
    if (!(await withinLimit(env, "document-respond", key, RESPOND_LIMIT_PER_MINUTE))) {
      return json({ error: "Too many attempts. Please slow down." }, 429);
    }
    const roomID = respondMatch[1];
    const inviteKey = pendingInviteKey(key, roomID);
    const invite = await env.STUDIQUO_DATA.get<DocumentInvite>(inviteKey, "json");
    if (!invite) return json({ error: "This invitation is no longer available." }, 404);
    if (respondMatch[2] === "decline") {
      await env.STUDIQUO_DATA.delete(inviteKey);
      return json({ status: "declined" });
    }
    try {
      // The seat is given on the inviter's authority at this moment: if they
      // are no longer the room's owner (or are gone), the offer is void.
      const room = env.DOCUMENT_ROOM.getByName(roomID);
      await room.invite(invite.inviterKey, key, invite.role);
      await recordRoomMembership(env, key, roomID, invite.role);
      // Same race as when the offer was made: an account deleted meanwhile must
      // not be left in the room.
      if (!(await env.STUDIQUO_DATA.get(`chat:user:${key}`))) {
        await room.removeAccount(key);
        await env.STUDIQUO_DATA.delete(roomMembershipKey(key, roomID));
        await env.STUDIQUO_DATA.delete(inviteKey);
        return json({ error: "This invitation is no longer available." }, 404);
      }
      await env.STUDIQUO_DATA.delete(inviteKey);
      return json({ status: "joined", role: invite.role });
    } catch (error) {
      if (error instanceof Error && (error.message === "Forbidden" || error.message === "InvalidRole")) {
        await env.STUDIQUO_DATA.delete(inviteKey);
        return json({ error: "This invitation is no longer available." }, 410);
      }
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

  // The owner takes a member out of the room, or a member leaves it. Either
  // way the member's index entry and any invitation still waiting for the room
  // go too, so they cannot walk back in on an old offer.
  const removeMatch = /^\/api\/document\/rooms\/([a-f0-9]{64})\/participants\/([a-f0-9]{64})$/.exec(url.pathname);
  const leaveMatch = /^\/api\/document\/rooms\/([a-f0-9]{64})\/leave$/.exec(url.pathname);
  if ((removeMatch && request.method === "DELETE") || (leaveMatch && request.method === "POST")) {
    if (!(await withinLimit(env, "document-respond", key, RESPOND_LIMIT_PER_MINUTE))) {
      return json({ error: "Too many attempts. Please slow down." }, 429);
    }
    const roomID = (removeMatch ?? leaveMatch)![1];
    const memberKey = removeMatch ? removeMatch[2] : key;
    try {
      const room = env.DOCUMENT_ROOM.getByName(roomID);
      const inviteKey = pendingInviteKey(memberKey, roomID);
      const hadInvite = !!(await env.STUDIQUO_DATA.get(inviteKey));
      const result = removeMatch ? await room.removeMember(key, memberKey) : await room.leave(key);
      // Someone who was only invited, not seated, is "removed" by withdrawing the offer.
      // Cleaned up even when the room had no seat for them, so a retry after a
      // failed cleanup finishes the job instead of answering 404 forever.
      await env.STUDIQUO_DATA.delete(roomMembershipKey(memberKey, roomID));
      await env.STUDIQUO_DATA.delete(inviteKey);
      if (result.status === "not_found" && !hadInvite) return json({ error: "That person is not in this room." }, 404);
      return json(result.status === "not_found" ? { status: "withdrawn" } : result);
    } catch (error) {
      const forbidden = roomForbiddenResponse(error);
      if (forbidden) return forbidden;
      if (error instanceof Error && error.message === "OwnerCannotLeave") return json({ error: "The owner cannot leave the room." }, 400);
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
    // same reasoning as chat.ts's own message-send limit.
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
