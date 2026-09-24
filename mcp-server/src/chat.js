import { isRevoked } from "./revocation.js";
import { isExpired } from "./token.js";
import { checkRateLimit } from "./rate-limit.js";
import { bearerToken, sha256Hex } from "./auth.js";
import { json, readJSONLimited as readJSONLimitedShared } from "./http.js";
import { realSession } from "./session.js";

const MAX_BODY = 16_000;
// Attachment uploads carry base64-encoded image/file bytes (up to
// MAX_ATTACHMENT_BYTES in chat-room.js, ~33% larger once base64-encoded,
// plus a little JSON overhead) — far past the small-JSON-payload MAX_BODY.
const MAX_ATTACHMENT_UPLOAD_BODY = 6_000_000;
// The client resizes a profile photo to 512x512 before ever sending it
// (UserProfileView.profileImageData in ProfileAndFriendsView.swift), which
// lands well under 300KB raw as a JPEG — this caps the decoded size, with
// MAX_AVATAR_UPLOAD_BODY as the matching cap on the base64-encoded JSON body
// (~33% larger, plus a little overhead), the same relationship
// MAX_ATTACHMENT_UPLOAD_BODY has to MAX_ATTACHMENT_BYTES.
const MAX_AVATAR_BYTES = 300_000;
const MAX_AVATAR_UPLOAD_BODY = 450_000;
const ALLOWED_AVATAR_CONTENT_TYPES = new Set(["image/jpeg", "image/png"]);
const FRIEND_ADD_LIMIT_PER_MINUTE = 5;
const CHAT_MESSAGE_LIMIT_PER_MINUTE = 30;
const ATTACHMENT_UPLOAD_LIMIT_PER_MINUTE = 10;
const AVATAR_UPLOAD_LIMIT_PER_MINUTE = 5;
const REPORT_LIMIT_PER_MINUTE = 5;
const MAX_FRIENDS = 500;
// A report's free-text reason — generous for context, but bounded so a
// report can't be used to smuggle an oversized payload into storage.
const MAX_REPORT_REASON_LENGTH = 1_000;
// Matches the format the client itself generates and validates (see
// FriendStore.codePattern in ProfileAndFriendsView.swift). Rejecting anything
// else here — rather than only trimming/uppercasing — keeps a malformed
// `code` from ever reaching a KV lookup keyed on it.
const FRIEND_CODE_PATTERN = /^[A-Z0-9]{6,32}$/;

function parseFriendCode(body) {
  const code = String(body?.code ?? "").trim().toUpperCase();
  return FRIEND_CODE_PATTERN.test(code) ? code : null;
}

// Same format as a friend code (see FRIEND_CODE_PATTERN) — the two are
// generated the same way, just stored under a different KV prefix so a
// link token can never be confused with, or substituted for, a manually
// typed friend code.
function parseLinkToken(body) {
  const token = String(body?.token ?? "").trim().toUpperCase();
  return FRIEND_CODE_PATTERN.test(token) ? token : null;
}

// Same alphabet/shape as UserRegistry's own generateCode (user-registry.js)
// — kept as a separate copy rather than imported, since user-registry.js
// pulls in `cloudflare:workers` for its DurableObject base class, which
// only resolves inside the Workers runtime and would break this file's own
// plain-Node test suite (chat.test.js) if imported here.
const LINK_TOKEN_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
function generateLinkToken() {
  const bytes = new Uint8Array(7);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, value => LINK_TOKEN_ALPHABET[value % 32]).join("");
}

// `Number("1e400")` and friends parse to Infinity, which SQLite's bind
// rejects with an exception — this turns that into a clean fallback instead
// of a 500 from chat-room.js's query.
function parseAfter(rawValue) {
  const number = Number(rawValue ?? 0);
  return Number.isSafeInteger(number) && number >= 0 ? number : 0;
}

// The client reports its own "today" as a plain date string (its own local
// calendar day) alongside the seconds studied so far that day — the server
// just stores and relays this as-is. Deciding whether a friend's reported
// date still counts as "today" is left to the viewer's own client, which is
// the only side that actually knows what day it is for the viewer.
function parseStudyStats(body) {
  const seconds = Number(body?.todayStudySeconds);
  const date = String(body?.studyDate ?? "");
  if (!Number.isSafeInteger(seconds) || seconds < 0 || seconds > 86_400) return null;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return null;
  return { seconds, date };
}

async function readBody(request, maxBytes = MAX_BODY) {
  return readJSONLimitedShared(request, maxBytes);
}

async function ensureUser(env, key, name = null, studyStats = null) {
  const storageKey = `chat:user:${key}`;
  const user = await env.STUDIQUO_DATA.get(storageKey, "json");
  if (user) {
    let changed = false;
    const cleaned = name == null ? "" : String(name).trim().slice(0, 80);
    if (cleaned && cleaned !== user.name) {
      user.name = cleaned;
      changed = true;
    }
    if (studyStats) {
      user.todayStudySeconds = studyStats.seconds;
      user.studyDate = studyStats.date;
      changed = true;
    }
    // Backfills a link token for a user created before invite links
    // existed — see UserRegistry.ensureUser's brand-new-user branch for
    // why this has to be a second, separate value from `code`.
    if (!user.linkToken) {
      do { user.linkToken = generateLinkToken(); } while (await env.STUDIQUO_DATA.get(`chat:linktoken:${user.linkToken}`));
      await env.STUDIQUO_DATA.put(`chat:linktoken:${user.linkToken}`, key);
      changed = true;
    }
    if (changed) {
      await env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    }
    return user;
  }
  // A brand-new user is registered through UserRegistry (a per-key Durable
  // Object) so two concurrent requests for the same not-yet-registered key
  // can't each mint and persist a different friend code for it.
  return env.USER_REGISTRY.getByName(key).ensureUser(key, name);
}

async function roomID(first, second) {
  return sha256Hex([first, second].sort().join(":"));
}

// ChatRoom.requireParticipant throws a plain Error("Forbidden") for a caller
// who isn't in the room; without this, that propagates uncaught up to app.js's
// catch-all and comes back as a generic 500 instead of a proper 403.
//
// sendMessage throws a separate Error("Blocked") when the other participant
// has blocked the caller — translated here to a deliberately vague message
// rather than "you have been blocked", the same discretion ordinary blocking
// UX gives every other messaging app: the blocked person isn't told why.
function roomForbiddenResponse(error) {
  if (error instanceof Error && error.message === "Forbidden") {
    return json({ error: "You are not a participant in this room." }, 403);
  }
  if (error instanceof Error && error.message === "Blocked") {
    return json({ error: "Message could not be sent." }, 403);
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

export async function handleChat(url, request, env) {
  if (!url.pathname.startsWith("/api/chat/")) return null;
  const token = bearerToken(request);
  if (!token) return json({ error: "Authentication required." }, 401);
  if (isExpired(token)) return json({ error: "This token has expired. Reconnect from Studiquo to get a new one." }, 401);
  const session = await realSession(env, token);
  if (!session) return json({ error: "Reconnect from Studiquo to get a new token." }, 401);
  const tokenKey = await sha256Hex(token);
  if (await isRevoked(env, tokenKey)) return json({ error: "This token has been revoked. Reconnect from Studiquo to get a new one." }, 401);
  // A session changes on each sign-in, but a person's chat identity must not.
  // Preserve the old token-derived key when upgrading an existing account so
  // its friend codes and room participants remain usable after token rotation.
  const identityHash = await sha256Hex(`chat-account:${session.sub}`);
  const key = await env.USER_REGISTRY.getByName(identityHash).resolveChatKey(identityHash, tokenKey);

  if (url.pathname === "/api/chat/me" && request.method === "POST") {
    const body = await readBody(request);
    const user = await ensureUser(env, key, body?.name, parseStudyStats(body));
    return json({ code: user.code, name: user.name, linkToken: user.linkToken, avatarUpdatedAt: user.avatarUpdatedAt ?? null });
  }

  // Uploads the caller's own profile photo so it can be shown to their
  // friends — previously there was no way for a friend to ever see anything
  // but a generic placeholder icon, no matter what photo was set in the
  // profile screen, because nothing about it was ever sent to the server.
  // Stored under the stable `code` (not the internal `key`) so GET
  // /api/chat/avatar/:code below can be reached with the same identifier
  // friends already know a person by.
  if (url.pathname === "/api/chat/me/avatar" && request.method === "POST") {
    // Reuses the attachment-upload rate limit binding under its own KV
    // prefix (see checkRateLimit's kvPrefix param) rather than needing a new
    // Cloudflare Rate Limiting binding provisioned just for this.
    const allowed = await checkRateLimit(
      env, env.RATE_LIMIT_CHAT_ATTACHMENT_UPLOAD, "avatar-upload", key, AVATAR_UPLOAD_LIMIT_PER_MINUTE
    );
    if (!allowed) return json({ error: "Too many uploads. Please slow down." }, 429);
    const body = await readBody(request, MAX_AVATAR_UPLOAD_BODY);
    const contentType = String(body?.contentType ?? "");
    const data = String(body?.data ?? "");
    if (!ALLOWED_AVATAR_CONTENT_TYPES.has(contentType) || !data) {
      return json({ error: "Invalid avatar." }, 400);
    }
    if (Math.floor(data.length * 3 / 4) > MAX_AVATAR_BYTES) {
      return json({ error: "Invalid avatar." }, 400);
    }
    const user = await ensureUser(env, key);
    const updatedAt = Date.now();
    await env.STUDIQUO_DATA.put(`chat:avatar:${user.code}`, JSON.stringify({ contentType, data, updatedAt }));
    user.avatarUpdatedAt = updatedAt;
    await env.STUDIQUO_DATA.put(`chat:user:${key}`, JSON.stringify(user));
    return json({ avatarUpdatedAt: updatedAt });
  }

  if (url.pathname === "/api/chat/friends" && request.method === "GET") {
    const user = await ensureUser(env, key);
    // Each friend's own current name and study stats are looked up live
    // (rather than trusting this user's stored friends entry, a snapshot
    // frozen at accept time) so a friend renaming themselves later doesn't
    // leave everyone else seeing their old name forever. avatarUpdatedAt
    // rides along the same live lookup so the client knows, without
    // fetching every friend's photo on every poll, whether the one it has
    // cached is still current.
    const withLiveDetails = await Promise.all((user.friends ?? []).map(async friend => {
      const friendKey = await env.STUDIQUO_DATA.get(`chat:code:${friend.code}`);
      const friendRecord = friendKey ? await env.STUDIQUO_DATA.get(`chat:user:${friendKey}`, "json") : null;
      return {
        ...friend,
        name: friendRecord?.name ?? friend.name,
        todayStudySeconds: friendRecord?.todayStudySeconds ?? 0,
        studyDate: friendRecord?.studyDate ?? null,
        avatarUpdatedAt: friendRecord?.avatarUpdatedAt ?? null,
      };
    }));
    return json(withLiveDetails);
  }

  // Serves a friend's (or the caller's own) uploaded profile photo. Gated to
  // the caller themselves or an established friend, the same trust boundary
  // the rest of this file draws around a person's name and study stats —
  // not a public-by-code lookup.
  const avatarMatch = /^\/api\/chat\/avatar\/([A-Z0-9]{6,32})$/.exec(url.pathname);
  if (avatarMatch && request.method === "GET") {
    const targetCode = avatarMatch[1];
    const user = await ensureUser(env, key);
    const isSelf = user.code === targetCode;
    const isFriend = (user.friends ?? []).some(friend => friend.code === targetCode);
    if (!isSelf && !isFriend) return json({ error: "Not found" }, 404);
    const avatar = await env.STUDIQUO_DATA.get(`chat:avatar:${targetCode}`, "json");
    if (!avatar) return json({ error: "Not found" }, 404);
    const bytes = Uint8Array.from(atob(avatar.data), c => c.charCodeAt(0));
    return new Response(bytes, {
      status: 200,
      headers: { "content-type": avatar.contentType, "cache-control": "private, max-age=60" },
    });
  }

  if (url.pathname === "/api/chat/friends/requests" && request.method === "GET") {
    const user = await ensureUser(env, key);
    return json(user.incomingRequests ?? []);
  }

  // Lets the requester see their own not-yet-answered requests.
  if (url.pathname === "/api/chat/friends/outgoing" && request.method === "GET") {
    const user = await ensureUser(env, key);
    return json(user.outgoingRequests ?? []);
  }

  // Creates a one-directional pending request instead of an immediate mutual
  // friendship — the recipient must accept it (a later endpoint) before a
  // room exists and either side can message the other.
  if (url.pathname === "/api/chat/friends" && request.method === "POST") {
    // Without this, the 200/404 split on a guessed code is a free oracle for
    // brute-forcing other users' friend codes — cap attempts per caller.
    const allowed = await checkRateLimit(env, env.RATE_LIMIT_CHAT_FRIEND_ADD, "chat-friend-add", key, FRIEND_ADD_LIMIT_PER_MINUTE);
    if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);
    const body = await readBody(request);
    const friendCode = parseFriendCode(body);
    if (!friendCode) return json({ error: "Invalid code." }, 400);
    const otherKey = await env.STUDIQUO_DATA.get(`chat:code:${friendCode}`);
    if (!otherKey) return json({ error: "Friend not found." }, 404);
    if (otherKey === key) return json({ error: "You cannot add yourself as a friend." }, 400);
    const user = await ensureUser(env, key);
    // Recording the request against the recipient's own record is delegated
    // to their UserRegistry instance so it's serialized against any other
    // request arriving for them at the same time (see addIncomingRequest).
    const result = await env.USER_REGISTRY.getByName(otherKey).addIncomingRequest(otherKey, user.code, user.name);
    if (result.status === "not_found") return json({ error: "Friend not found." }, 404);
    if (result.status === "pending") {
      await env.USER_REGISTRY.getByName(key).addOutgoingRequest(key, result.recipient.code, result.recipient.name);
    }
    return json({ status: result.status });
  }

  // Redeems the *other* person's invite-link token for an immediate,
  // mutual friendship — unlike POST /api/chat/friends above, there's no
  // pending request and no separate accept step: actually having received
  // the link/QR (which is the only way to ever learn its token) is treated
  // as consent enough. `linkToken` is deliberately a different value from
  // `code` (see UserRegistry.ensureUser's doc comment) specifically so
  // this shortcut can never be reached by just typing a friend code by
  // hand.
  if (url.pathname === "/api/chat/friends/link-add" && request.method === "POST") {
    const allowed = await checkRateLimit(env, env.RATE_LIMIT_CHAT_FRIEND_ADD, "chat-friend-link-add", key, FRIEND_ADD_LIMIT_PER_MINUTE);
    if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);
    const body = await readBody(request);
    const linkToken = parseLinkToken(body);
    if (!linkToken) return json({ error: "Invalid invite link." }, 400);
    const otherKey = await env.STUDIQUO_DATA.get(`chat:linktoken:${linkToken}`);
    if (!otherKey) return json({ error: "This invite link is no longer valid." }, 404);
    if (otherKey === key) return json({ error: "You cannot add yourself as a friend." }, 400);
    const [user, other] = await Promise.all([ensureUser(env, key), ensureUser(env, otherKey)]);
    if ((other.friends ?? []).length >= MAX_FRIENDS) {
      return json({ error: "Friend list is full." }, 400);
    }
    const room = await roomID(key, otherKey);
    // The caller's own side is delegated to their UserRegistry instance for
    // the same race-safety reason every other friends-list mutation here
    // is (see addFriendDirectly). The link owner's side is written directly
    // here, mirroring how the accept handler below updates its own "other"
    // side.
    const result = await env.USER_REGISTRY.getByName(key).addFriendDirectly(key, other.code, other.name, room);
    if (result.status === "not_found") return json({ error: "Friend not found." }, 404);
    if (result.status === "friends_full") return json({ error: "Friend list is full." }, 400);
    if (result.status === "already_friends") {
      const existing = (user.friends ?? []).find(item => item.code === other.code);
      return json({ status: "already_friends", code: other.code, name: other.name, roomID: existing?.roomID ?? room });
    }
    other.friends = [...(other.friends ?? []).filter(item => item.code !== user.code), { code: user.code, name: user.name, roomID: room }];
    await Promise.all([
      env.STUDIQUO_DATA.put(`chat:user:${otherKey}`, JSON.stringify(other)),
      env.CHAT_ROOM.getByName(room).initialize(room, [key, otherKey]),
    ]);
    return json({ status: "added", code: other.code, name: other.name, roomID: room });
  }

  // Accept: the request's recipient turns it into a mutual friendship and
  // the room the two of them will message in is created.
  if (url.pathname === "/api/chat/friends/requests/accept" && request.method === "POST") {
    const body = await readBody(request);
    const friendCode = parseFriendCode(body);
    if (!friendCode) return json({ error: "Invalid code." }, 400);
    const otherKey = await env.STUDIQUO_DATA.get(`chat:code:${friendCode}`);
    if (!otherKey) return json({ error: "Request not found." }, 404);
    if (otherKey === key) return json({ error: "You cannot accept a request from yourself." }, 400);
    const other = await ensureUser(env, otherKey);
    if ((other.friends ?? []).length >= MAX_FRIENDS) {
      return json({ error: "Friend list is full." }, 400);
    }
    const room = await roomID(key, otherKey);
    // Removing the pending request and adding the friend on the recipient's
    // own side is delegated to their UserRegistry instance, so a concurrent
    // reject of the same request can't race this and silently undo it.
    const result = await env.USER_REGISTRY.getByName(key).resolveIncomingRequest(key, "accept", other.code, other.name, room);
    if (result.status === "not_found") return json({ error: "Request not found." }, 404);
    if (result.status === "friends_full") return json({ error: "Friend list is full." }, 400);
    other.friends = [...(other.friends ?? []).filter(item => item.code !== result.friend.code), { ...result.friend, roomID: room }];
    other.outgoingRequests = (other.outgoingRequests ?? []).filter(item => item.code !== result.friend.code);
    await Promise.all([
      env.STUDIQUO_DATA.put(`chat:user:${otherKey}`, JSON.stringify(other)),
      env.CHAT_ROOM.getByName(room).initialize(room, [key, otherKey]),
    ]);
    return json({ code: other.code, name: other.name, roomID: room });
  }

  // Reject: just clears the pending request, no friendship is created.
  if (url.pathname === "/api/chat/friends/requests/reject" && request.method === "POST") {
    const body = await readBody(request);
    const friendCode = parseFriendCode(body);
    if (!friendCode) return json({ error: "Invalid code." }, 400);
    const result = await env.USER_REGISTRY.getByName(key).resolveIncomingRequest(key, "reject", friendCode, null, null);
    if (result.status === "not_found") return json({ error: "Request not found." }, 404);
    // Clears the resolved request from the original requester's own
    // "sent, awaiting approval" list.
    const senderKey = await env.STUDIQUO_DATA.get(`chat:code:${friendCode}`);
    if (senderKey) {
      await env.USER_REGISTRY.getByName(senderKey).removeOutgoingRequest(senderKey, result.recipient.code);
    }
    return json({ status: "rejected" });
  }

  const match = /^\/api\/chat\/rooms\/([a-f0-9]{64})\/messages$/.exec(url.pathname);
  if (match && request.method === "GET") {
    const after = parseAfter(url.searchParams.get("after"));
    return roomResponse(env.CHAT_ROOM.getByName(match[1]).listMessages(key, after));
  }
  if (match && request.method === "POST") {
    // Without this, a single compromised or misbehaving client could flood a
    // room (and this Durable Object's storage) with unlimited messages.
    const allowed = await checkRateLimit(env, env.RATE_LIMIT_CHAT_MESSAGE, "chat-message", key, CHAT_MESSAGE_LIMIT_PER_MINUTE);
    if (!allowed) return json({ error: "Too many messages. Please slow down." }, 429);
    const body = await readBody(request);
    const text = String(body?.text ?? "").trim().slice(0, 2_000);
    if (!text) return json({ error: "Message is required." }, 400);
    const clientMessageID = typeof body?.clientMessageID === "string" ? body.clientMessageID.slice(0, 100) : null;
    return roomResponse(env.CHAT_ROOM.getByName(match[1]).sendMessage(key, text, clientMessageID));
  }

  // Retracts one of the caller's own messages for real: the stored text is
  // cleared server-side, so every reader of this room — not just the
  // sender's own device — stops seeing it. `cancelMessage` returns a
  // {status: "not_found"} value rather than throwing for a missing id, so
  // that case is handled explicitly rather than via roomResponse's
  // exception-only Forbidden mapping.
  const cancelMatch = /^\/api\/chat\/rooms\/([a-f0-9]{64})\/messages\/(\d+)\/cancel$/.exec(url.pathname);
  if (cancelMatch && request.method === "POST") {
    const messageID = Number(cancelMatch[2]);
    try {
      const result = await env.CHAT_ROOM.getByName(cancelMatch[1]).cancelMessage(key, messageID);
      if (result.status === "not_found") return json({ error: "Message not found." }, 404);
      return json(result);
    } catch (error) {
      const forbidden = roomForbiddenResponse(error);
      if (forbidden) return forbidden;
      throw error;
    }
  }

  // Repairs a legacy attachment reference in place, once the sender's own
  // device has re-rendered and re-uploaded the material under the newer,
  // shareable scheme — see `editMessage` in chat-room.js.
  const editMatch = /^\/api\/chat\/rooms\/([a-f0-9]{64})\/messages\/(\d+)\/edit$/.exec(url.pathname);
  if (editMatch && request.method === "POST") {
    const messageID = Number(editMatch[2]);
    const body = await readBody(request);
    const text = String(body?.text ?? "").trim().slice(0, 2_000);
    if (!text) return json({ error: "Message is required." }, 400);
    try {
      const result = await env.CHAT_ROOM.getByName(editMatch[1]).editMessage(key, messageID, text);
      if (result.status === "not_found") return json({ error: "Message not found." }, 404);
      return json(result);
    } catch (error) {
      const forbidden = roomForbiddenResponse(error);
      if (forbidden) return forbidden;
      throw error;
    }
  }

  // Batch lookup by id, for reconciling messages old enough to have
  // scrolled out of `listMessages`' rolling reconcile window — see
  // `getMessagesByIDs` in chat-room.js.
  const lookupMatch = /^\/api\/chat\/rooms\/([a-f0-9]{64})\/messages\/lookup$/.exec(url.pathname);
  if (lookupMatch && request.method === "POST") {
    const body = await readBody(request);
    const ids = Array.isArray(body?.ids)
      ? body.ids.map(Number).filter(Number.isSafeInteger).slice(0, 200)
      : [];
    return roomResponse(env.CHAT_ROOM.getByName(lookupMatch[1]).getMessagesByIDs(key, ids));
  }

  // Uploads an attachment's actual bytes to the room it'll be shared in, so
  // the other participant — on a different device — can retrieve them too.
  // Previously an attachment only ever carried the sender's local file path
  // or local database id, meaningless off the sender's own device.
  const attachmentUploadMatch = /^\/api\/chat\/rooms\/([a-f0-9]{64})\/attachments$/.exec(url.pathname);
  if (attachmentUploadMatch && request.method === "POST") {
    // Each upload can be up to MAX_ATTACHMENT_UPLOAD_BODY (6MB) — without
    // this, a compromised or misbehaving client could spam a room's
    // storage with unlimited uploads, unlike message sends just above.
    const allowed = await checkRateLimit(
      env, env.RATE_LIMIT_CHAT_ATTACHMENT_UPLOAD, "chat-attachment-upload", key, ATTACHMENT_UPLOAD_LIMIT_PER_MINUTE
    );
    if (!allowed) return json({ error: "Too many uploads. Please slow down." }, 429);
    const body = await readBody(request, MAX_ATTACHMENT_UPLOAD_BODY);
    try {
      const result = await env.CHAT_ROOM.getByName(attachmentUploadMatch[1]).storeAttachment(key, body?.contentType, body?.data);
      return json(result, 201);
    } catch (error) {
      const forbidden = roomForbiddenResponse(error);
      if (forbidden) return forbidden;
      if (error instanceof Error && (error.message === "InvalidContentType" || error.message === "AttachmentTooLarge")) {
        return json({ error: "Invalid attachment." }, 400);
      }
      throw error;
    }
  }

  const attachmentDownloadMatch = /^\/api\/chat\/rooms\/([a-f0-9]{64})\/attachments\/([0-9a-f-]{36})$/.exec(url.pathname);
  if (attachmentDownloadMatch && request.method === "GET") {
    try {
      const attachment = await env.CHAT_ROOM.getByName(attachmentDownloadMatch[1]).getAttachment(key, attachmentDownloadMatch[2]);
      if (!attachment) return json({ error: "Not found" }, 404);
      const bytes = Uint8Array.from(atob(attachment.data), c => c.charCodeAt(0));
      return new Response(bytes, {
        status: 200,
        headers: { "content-type": attachment.contentType, "cache-control": "private, max-age=31536000, immutable" },
      });
    } catch (error) {
      const forbidden = roomForbiddenResponse(error);
      if (forbidden) return forbidden;
      throw error;
    }
  }

  // Blocks the other participant in this 1:1 room — from that point on,
  // sendMessage rejects anything they try to send here (see chat-room.js).
  // Idempotent, like initialize elsewhere: blocking twice is a no-op, not
  // an error.
  const blockMatch = /^\/api\/chat\/rooms\/([a-f0-9]{64})\/block$/.exec(url.pathname);
  if (blockMatch && request.method === "POST") {
    return roomResponse(env.CHAT_ROOM.getByName(blockMatch[1]).blockOtherParticipant(key));
  }

  const unblockMatch = /^\/api\/chat\/rooms\/([a-f0-9]{64})\/unblock$/.exec(url.pathname);
  if (unblockMatch && request.method === "POST") {
    return roomResponse(env.CHAT_ROOM.getByName(unblockMatch[1]).unblockOtherParticipant(key));
  }

  // { blockedByMe, blockedByOther } — lets the client show the right
  // "ブロックする"/"ブロック解除する" label and decide whether to even
  // attempt a send, rather than only ever discovering a block from a
  // failed message.
  const blockStatusMatch = /^\/api\/chat\/rooms\/([a-f0-9]{64})\/block-status$/.exec(url.pathname);
  if (blockStatusMatch && request.method === "GET") {
    return roomResponse(env.CHAT_ROOM.getByName(blockStatusMatch[1]).blockStatus(key));
  }

  // Records a report for manual review — there's no in-app moderation
  // queue or admin role yet, so this is written to STUDIQUO_DATA under a
  // listable prefix (`report:...`) rather than into the room's own
  // Durable Object storage, which has no external inspection tool at all.
  // Verifying the reporter is an actual room participant (not just anyone
  // with a valid token) still goes through the room itself.
  const reportMatch = /^\/api\/chat\/rooms\/([a-f0-9]{64})\/messages\/(\d+)\/report$/.exec(url.pathname);
  if (reportMatch && request.method === "POST") {
    const allowed = await checkRateLimit(env, env.RATE_LIMIT_CHAT_REPORT, "chat-report", key, REPORT_LIMIT_PER_MINUTE);
    if (!allowed) return json({ error: "Too many reports. Please slow down." }, 429);
    const messageID = Number(reportMatch[2]);
    const body = await readBody(request);
    const reason = String(body?.reason ?? "").trim().slice(0, MAX_REPORT_REASON_LENGTH);
    try {
      await env.CHAT_ROOM.getByName(reportMatch[1]).requireParticipant(key);
    } catch (error) {
      const forbidden = roomForbiddenResponse(error);
      if (forbidden) return forbidden;
      throw error;
    }
    const reportKey = `report:chat:${Date.now()}:${crypto.randomUUID()}`;
    await env.STUDIQUO_DATA.put(reportKey, JSON.stringify({
      roomID: reportMatch[1], messageID, reporterKey: key, reason, createdAt: Date.now(),
    }));
    return json({ status: "reported" });
  }

  return json({ error: "Not found" }, 404);
}
