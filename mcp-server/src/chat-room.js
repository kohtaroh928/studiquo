import { DurableObject } from "cloudflare:workers";

// Raw byte cap on an uploaded attachment (before base64 encoding, which adds
// ~33%) — bounds both the row size in this room's SQLite storage and how
// much a single upload can cost to store.
const MAX_ATTACHMENT_BYTES = 3 * 1024 * 1024;
const CONTENT_TYPE_PATTERN = /^[a-zA-Z0-9!#$&\-^_.+]+\/[a-zA-Z0-9!#$&\-^_.+]+$/;
// How long an uploaded attachment is kept before it's treated as expired —
// matches the 90-day convention already used for token expiry elsewhere in
// this codebase.
const ATTACHMENT_RETENTION_MS = 90 * 24 * 60 * 60 * 1000;
// A studiquo-specific cap, distinct from MAX_FRIENDS in user-registry.js —
// sized for a study group/class, not a social contact list.
const MAX_GROUP_MEMBERS = 50;

export class ChatRoom extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS participants (user_key TEXT PRIMARY KEY, code TEXT, name TEXT);
        CREATE TABLE IF NOT EXISTS messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          sender_key TEXT NOT NULL,
          text TEXT NOT NULL,
          sent_at INTEGER NOT NULL,
          client_message_id TEXT,
          is_canceled INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_messages_id ON messages(id);
        CREATE TABLE IF NOT EXISTS attachments (
          id TEXT PRIMARY KEY,
          content_type TEXT NOT NULL,
          data TEXT NOT NULL,
          uploaded_by TEXT NOT NULL,
          created_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS blocks (
          blocker_key TEXT PRIMARY KEY,
          blocked_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS room_state (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          closed INTEGER NOT NULL DEFAULT 0,
          kind TEXT NOT NULL DEFAULT 'direct',
          name TEXT
        );
        CREATE TABLE IF NOT EXISTS read_positions (
          user_key TEXT PRIMARY KEY,
          message_id INTEGER NOT NULL
        );
      `);
      // `client_message_id` was added after rooms already existed in
      // production — the CREATE TABLE above is a no-op for them, since it
      // only defines the shape for a brand-new table. This backfills the
      // column there; for a genuinely new room (whose CREATE TABLE already
      // includes it) this just fails with "duplicate column", which is
      // exactly the case to ignore.
      try {
        this.ctx.storage.sql.exec("ALTER TABLE messages ADD COLUMN client_message_id TEXT");
      } catch (error) {
        if (!String(error?.message ?? error).includes("duplicate column")) throw error;
      }
      try {
        this.ctx.storage.sql.exec("ALTER TABLE messages ADD COLUMN is_canceled INTEGER NOT NULL DEFAULT 0");
      } catch (error) {
        if (!String(error?.message ?? error).includes("duplicate column")) throw error;
      }
      try {
        this.ctx.storage.sql.exec("ALTER TABLE room_state ADD COLUMN kind TEXT NOT NULL DEFAULT 'direct'");
      } catch (error) {
        if (!String(error?.message ?? error).includes("duplicate column")) throw error;
      }
      try {
        this.ctx.storage.sql.exec("ALTER TABLE room_state ADD COLUMN name TEXT");
      } catch (error) {
        if (!String(error?.message ?? error).includes("duplicate column")) throw error;
      }
      try {
        this.ctx.storage.sql.exec("ALTER TABLE participants ADD COLUMN code TEXT");
      } catch (error) {
        if (!String(error?.message ?? error).includes("duplicate column")) throw error;
      }
      try {
        this.ctx.storage.sql.exec("ALTER TABLE participants ADD COLUMN name TEXT");
      } catch (error) {
        if (!String(error?.message ?? error).includes("duplicate column")) throw error;
      }
    });
  }

  isGroupRoom() {
    const row = this.ctx.storage.sql.exec("SELECT kind FROM room_state WHERE id = 1").toArray()[0];
    return row?.kind === "group";
  }

  requireGroup(userKey) {
    this.requireParticipant(userKey);
    if (!this.isGroupRoom()) throw new Error("NotAGroup");
  }

  /**
   * `options.kind` — `"direct"` (default, exactly 2 participants, supports
   * blocking) or `"group"` (N participants, no blocking; see requireGroup's
   * callers below). A group's `initialize` is only ever called once, at
   * creation, with just its creator — everyone else joins later through
   * `addParticipant`, once they've accepted an invitation (see groups.js).
   */
  /**
   * `options.creatorCode`/`options.creatorName` (group only) are stored
   * alongside the sole initial participant — see `groupInfo`'s doc comment
   * for why a group's roster carries this denormalized copy instead of
   * groups.js resolving it via a live KV lookup on every listing.
   */
  async initialize(roomID, participants, options = {}) {
    const kind = options.kind ?? "direct";
    const existing = this.ctx.storage.sql.exec("SELECT COUNT(*) AS count FROM participants").one().count;
    if (existing > 0) {
      // Re-friending restores access to the retained conversation.
      this.ctx.storage.sql.exec("DELETE FROM room_state WHERE id = 1");
      return;
    }
    const capped = kind === "group" ? participants : participants.slice(0, 2);
    for (const key of capped) {
      if (kind === "group") {
        this.ctx.storage.sql.exec(
          "INSERT OR IGNORE INTO participants (user_key, code, name) VALUES (?, ?, ?)",
          key, options.creatorCode ?? null, options.creatorName ?? null,
        );
      } else {
        this.ctx.storage.sql.exec("INSERT OR IGNORE INTO participants (user_key) VALUES (?)", key);
      }
    }
    if (kind === "group") {
      const name = String(options.name ?? "").trim().slice(0, 80) || null;
      this.ctx.storage.sql.exec("INSERT INTO room_state (id, closed, kind, name) VALUES (1, 0, 'group', ?)", name);
    }
  }

  /** Adds a new member to an existing group. Always self-initiated — called
   * only once an invitee accepts their invite (see groups.js), at which
   * point `newKey` legitimately belongs but, being brand new, can't yet
   * pass a requireParticipant check the way every other group method's
   * caller does. The actual authorization already happened one level up:
   * groups.js only reaches this call after UserRegistry.resolveIncomingGroupInvite
   * confirms `newKey` held a genuine, still-pending invite for this room.
   * `code`/`name` are stored alongside the key — see `groupInfo`'s doc
   * comment. */
  async addParticipant(newKey, code, name) {
    if (!this.isGroupRoom()) throw new Error("NotAGroup");
    const count = this.ctx.storage.sql.exec("SELECT COUNT(*) AS count FROM participants").one().count;
    if (count >= MAX_GROUP_MEMBERS) throw new Error("GroupFull");
    this.ctx.storage.sql.exec(
      "INSERT OR IGNORE INTO participants (user_key, code, name) VALUES (?, ?, ?)", newKey, code ?? null, name ?? null,
    );
    // A new member sees the group's full message history (there's no
    // per-member join marker), but their unread count should only start
    // counting from here — without this, joining an old, active group would
    // instantly show years of history as unread.
    const latestID = this.ctx.storage.sql.exec("SELECT COALESCE(MAX(id), 0) AS id FROM messages").one().id;
    this.ctx.storage.sql.exec(
      "INSERT INTO read_positions (user_key, message_id) VALUES (?, ?) " +
      "ON CONFLICT(user_key) DO UPDATE SET message_id = MAX(message_id, excluded.message_id)",
      newKey, latestID,
    );
    return { status: "added" };
  }

  /** Leaving (targetKey === callerKey) and removing another member are the
   * same operation — any current member may do either; groups have no
   * admin/owner concept, matching an ordinary (non-official) LINE group. */
  async removeParticipant(callerKey, targetKey) {
    this.requireGroup(callerKey);
    this.requireParticipant(targetKey);
    this.ctx.storage.sql.exec("DELETE FROM participants WHERE user_key = ?", targetKey);
    this.ctx.storage.sql.exec("DELETE FROM read_positions WHERE user_key = ?", targetKey);
    return { status: "removed" };
  }

  async renameRoom(callerKey, name) {
    this.requireGroup(callerKey);
    const trimmed = String(name ?? "").trim().slice(0, 80);
    if (!trimmed) throw new Error("InvalidName");
    this.ctx.storage.sql.exec("UPDATE room_state SET name = ? WHERE id = 1", trimmed);
    return { status: "renamed", name: trimmed };
  }

  /**
   * The group's name and its current members, each already carrying its own
   * code/name — stored directly on the participants row at join time (see
   * addParticipant/initialize) instead of resolved via a live KV lookup on
   * every call, the way friends() does for a 1:1 friend list. That live
   * lookup pattern is what actually exhausted the account's daily KV
   * operation quota in production: with a group polled every few seconds,
   * one lookup per member on every single poll multiplies fast. The
   * trade-off is staleness — a member's name here only updates the next
   * time they join a group, not the moment they rename themselves — judged
   * an acceptable cost for something that changes far less often than it
   * would otherwise be read.
   */
  async groupInfo(callerKey) {
    this.requireGroup(callerKey);
    const row = this.ctx.storage.sql.exec("SELECT name FROM room_state WHERE id = 1").toArray()[0];
    const members = this.ctx.storage.sql.exec("SELECT user_key, code, name FROM participants").toArray()
      .map(item => ({ key: item.user_key, code: item.code, name: item.name }));
    return { name: row?.name ?? null, members };
  }

  requireParticipant(userKey) {
    const row = this.ctx.storage.sql.exec("SELECT user_key FROM participants WHERE user_key = ?", userKey).toArray();
    if (row.length !== 1) throw new Error("Forbidden");
  }

  requireOpen(userKey) {
    this.requireParticipant(userKey);
    if (this.ctx.storage.sql.exec("SELECT closed FROM room_state WHERE id = 1").toArray()[0]?.closed) {
      throw new Error("Closed");
    }
  }

  async close(userKey) {
    this.requireParticipant(userKey);
    const latestID = this.ctx.storage.sql.exec("SELECT COALESCE(MAX(id), 0) AS id FROM messages").one().id;
    for (const participant of this.ctx.storage.sql.exec("SELECT user_key FROM participants").toArray()) {
      this.ctx.storage.sql.exec(
        "INSERT INTO read_positions (user_key, message_id) VALUES (?, ?) " +
        "ON CONFLICT(user_key) DO UPDATE SET message_id = MAX(message_id, excluded.message_id)",
        participant.user_key, latestID,
      );
    }
    // Not INSERT OR REPLACE: that would overwrite an existing row's kind/name
    // back to their column defaults. close() is only ever called on a direct
    // room in practice (see removeFriendMatch in chat.js — groups leave
    // through removeParticipant instead, never close()), but this stays
    // correct even so.
    this.ctx.storage.sql.exec(
      "INSERT INTO room_state (id, closed) VALUES (1, 1) ON CONFLICT(id) DO UPDATE SET closed = 1",
    );
    return { status: "closed" };
  }

  async inboxState(userKey) {
    this.requireParticipant(userKey);
    const latestID = this.ctx.storage.sql.exec("SELECT COALESCE(MAX(id), 0) AS id FROM messages").one().id;
    if (this.ctx.storage.sql.exec("SELECT closed FROM room_state WHERE id = 1").toArray()[0]?.closed) {
      return { latestID, unreadCount: 0, closed: true };
    }
    let position = this.ctx.storage.sql.exec(
      "SELECT message_id FROM read_positions WHERE user_key = ?", userKey,
    ).toArray()[0];
    if (!position) {
      // Existing rooms predate server-side read positions. Treat their
      // historical messages as read instead of showing years of false unread.
      this.ctx.storage.sql.exec(
        "INSERT INTO read_positions (user_key, message_id) VALUES (?, ?)", userKey, latestID,
      );
      position = { message_id: latestID };
    }
    const unreadCount = this.ctx.storage.sql.exec(
      "SELECT COUNT(*) AS count FROM messages WHERE id > ? AND sender_key != ? AND is_canceled = 0",
      position.message_id, userKey,
    ).one().count;
    return { latestID, unreadCount, closed: false };
  }

  async markRead(userKey, throughID) {
    this.requireParticipant(userKey);
    const latestID = this.ctx.storage.sql.exec("SELECT COALESCE(MAX(id), 0) AS id FROM messages").one().id;
    const safeID = Math.min(latestID, Math.max(0, Number.isSafeInteger(throughID) ? throughID : 0));
    this.ctx.storage.sql.exec(
      "INSERT INTO read_positions (user_key, message_id) VALUES (?, ?) " +
      "ON CONFLICT(user_key) DO UPDATE SET message_id = MAX(message_id, excluded.message_id)",
      userKey, safeID,
    );
    return { status: "read", throughID: safeID };
  }

  // The other person in this 1:1 room — a room only ever has two
  // participants, so "who blocked whom" never needs a target parameter,
  // just "the other one."
  otherParticipant(userKey) {
    const row = this.ctx.storage.sql
      .exec("SELECT user_key FROM participants WHERE user_key != ?", userKey)
      .toArray()[0];
    return row?.user_key ?? null;
  }

  isBlockedBy(blockerKey) {
    const row = this.ctx.storage.sql.exec("SELECT 1 FROM blocks WHERE blocker_key = ?", blockerKey).toArray();
    return row.length > 0;
  }

  // Blocking a whole group doesn't map to anything meaningful — leaving (see
  // removeParticipant) is the group equivalent of ending a 1:1 conversation.
  async blockOtherParticipant(userKey) {
    this.requireParticipant(userKey);
    if (this.isGroupRoom()) throw new Error("NotSupported");
    this.ctx.storage.sql.exec(
      "INSERT OR REPLACE INTO blocks (blocker_key, blocked_at) VALUES (?, ?)", userKey, Date.now(),
    );
    return { status: "blocked" };
  }

  async unblockOtherParticipant(userKey) {
    this.requireParticipant(userKey);
    if (this.isGroupRoom()) throw new Error("NotSupported");
    this.ctx.storage.sql.exec("DELETE FROM blocks WHERE blocker_key = ?", userKey);
    return { status: "unblocked" };
  }

  // Both directions at once, so the client can show "ブロック中" vs
  // "ブロック解除する" for the caller's own action, and separately decide
  // whether to even try sending (see sendMessage's own check below) rather
  // than surfacing that only as a failed send.
  async blockStatus(userKey) {
    this.requireParticipant(userKey);
    if (this.isGroupRoom()) throw new Error("NotSupported");
    const other = this.otherParticipant(userKey);
    return {
      blockedByMe: this.isBlockedBy(userKey),
      blockedByOther: other ? this.isBlockedBy(other) : false,
    };
  }

  // `clientMessageID` is an opaque, client-generated token (nullable) that
  // round-trips back in this same message's row on every future
  // `listMessages` call — it's what lets the sender's own client reconcile
  // its optimistic local copy with its now-confirmed server echo by exact
  // identity, instead of guessing by text content (which breaks down when
  // two messages with identical text are in flight at once).
  async sendMessage(userKey, text, clientMessageID = null) {
    this.requireOpen(userKey);
    // Groups have no blocking (see blockOtherParticipant) and every member's
    // read position is already initialized when they're added (see
    // addParticipant), so neither check below applies to one.
    if (!this.isGroupRoom()) {
      // A block is enforced from the blocker's side only — the sender isn't
      // told they've been blocked (matches ordinary blocking semantics: no
      // "you've been blocked" notice), just that sending silently fails.
      const other = this.otherParticipant(userKey);
      if (other && this.isBlockedBy(other)) throw new Error("Blocked");
      if (other && !this.ctx.storage.sql.exec(
        "SELECT 1 FROM read_positions WHERE user_key = ?", other,
      ).toArray().length) {
        // On an existing room's first send after this feature is introduced,
        // begin counting at the previous last message. Otherwise a recipient
        // who has not opened the app yet would miss this first new message.
        const previousID = this.ctx.storage.sql.exec("SELECT COALESCE(MAX(id), 0) AS id FROM messages").one().id;
        this.ctx.storage.sql.exec(
          "INSERT INTO read_positions (user_key, message_id) VALUES (?, ?)", other, previousID,
        );
      }
    }
    const sentAt = Date.now();
    const row = this.ctx.storage.sql.exec(
      "INSERT INTO messages (sender_key, text, sent_at, client_message_id) VALUES (?, ?, ?, ?) RETURNING id",
      userKey, text, sentAt, clientMessageID,
    ).one();
    // senderKey is internal — chat.js strips it and substitutes the
    // sender's code/name before this ever reaches a client (see
    // resolveSenderNames). A direct room's own client never needed
    // anything beyond isMine, but a group's does, since "not mine" no
    // longer means "the one other person".
    return { id: row.id, text, sentAt, isMine: true, clientMessageID, senderKey: userKey };
  }

  async listMessages(userKey, after = 0) {
    this.requireParticipant(userKey);
    const rows = after > 0
      ? this.ctx.storage.sql.exec(
          "SELECT id, sender_key, text, sent_at, client_message_id, is_canceled FROM messages WHERE id > ? ORDER BY id ASC LIMIT 200", after,
        ).toArray()
      : this.ctx.storage.sql.exec(
          "SELECT * FROM (SELECT id, sender_key, text, sent_at, client_message_id, is_canceled FROM messages ORDER BY id DESC LIMIT 200) ORDER BY id ASC",
        ).toArray();
    return rows.map(item => ({
      id: item.id,
      text: item.text,
      sentAt: item.sent_at,
      isMine: item.sender_key === userKey,
      clientMessageID: item.client_message_id ?? null,
      isCanceled: !!item.is_canceled,
      senderKey: item.sender_key,
    }));
  }

  // A real retraction, not just a local hide: the stored text is actually
  // cleared here, so the recipient (or the sender's own data on a fresh
  // install) can never see the original content again once this succeeds —
  // this is what makes "送信取消" mean what its label claims, instead of
  // only ever hiding the bubble on the sender's own device.
  async cancelMessage(userKey, messageID) {
    this.requireParticipant(userKey);
    const row = this.ctx.storage.sql.exec("SELECT sender_key FROM messages WHERE id = ?", messageID).toArray()[0];
    if (!row) return { status: "not_found" };
    if (row.sender_key !== userKey) throw new Error("Forbidden");
    this.ctx.storage.sql.exec("UPDATE messages SET is_canceled = 1, text = '' WHERE id = ?", messageID);
    return { status: "canceled" };
  }

  // Rewrites one of the caller's own messages' text in place — used to
  // repair a legacy chat attachment (one still carrying only a local,
  // off-device id, from before attachments could be uploaded at all) once
  // its material has been re-rendered and re-uploaded under the newer,
  // shareable scheme. Only the original sender may edit, the same
  // ownership check `cancelMessage` uses; a canceled message stays
  // canceled — an edit must never resurrect a retracted message.
  async editMessage(userKey, messageID, text) {
    this.requireParticipant(userKey);
    const row = this.ctx.storage.sql.exec(
      "SELECT sender_key, is_canceled FROM messages WHERE id = ?", messageID,
    ).toArray()[0];
    if (!row) return { status: "not_found" };
    if (row.sender_key !== userKey) throw new Error("Forbidden");
    if (row.is_canceled) return { status: "canceled" };
    this.ctx.storage.sql.exec("UPDATE messages SET text = ? WHERE id = ?", text, messageID);
    return { status: "edited" };
  }

  // Looks up the current text for a specific set of message ids, regardless
  // of how old they are relative to the room's latest message.
  // `listMessages(after)` only reconciles a rolling window of recent ids
  // (see its caller in ProfileAndFriendsView.swift), which would never
  // surface an `editMessage` repair to a message old enough to have
  // scrolled out of that window — this is the fallback that checks
  // specific known-stale ids directly instead.
  async getMessagesByIDs(userKey, ids) {
    this.requireParticipant(userKey);
    if (!Array.isArray(ids) || ids.length === 0) return [];
    const placeholders = ids.map(() => "?").join(",");
    const rows = this.ctx.storage.sql.exec(
      `SELECT id, sender_key, text, sent_at, client_message_id, is_canceled FROM messages WHERE id IN (${placeholders})`,
      ...ids,
    ).toArray();
    return rows.map(item => ({
      id: item.id,
      text: item.text,
      sentAt: item.sent_at,
      isMine: item.sender_key === userKey,
      clientMessageID: item.client_message_id ?? null,
      isCanceled: !!item.is_canceled,
      senderKey: item.sender_key,
    }));
  }

  // Stores an attachment's actual bytes (base64-encoded) in this room, so
  // the other participant — on a different device, with no access to the
  // uploader's local filesystem or app database — can actually retrieve it.
  // Previously an attachment only ever carried a local file path / local
  // database id, which meant nothing outside the sender's own device.
  async storeAttachment(userKey, contentType, base64Data) {
    this.requireOpen(userKey);
    const type = String(contentType ?? "").slice(0, 100);
    if (!CONTENT_TYPE_PATTERN.test(type)) throw new Error("InvalidContentType");
    const data = String(base64Data ?? "");
    const approxBytes = Math.floor((data.length * 3) / 4);
    if (!data || approxBytes > MAX_ATTACHMENT_BYTES) throw new Error("AttachmentTooLarge");
    // There's no cron/alarm wired up for this room, so there's no periodic
    // sweep — piggybacking a cleanup of long-expired attachments onto every
    // new upload is what stands in for one. A room that's active enough to
    // still be receiving uploads is exactly the kind that would otherwise
    // accumulate storage forever with no expiry at all.
    this.ctx.storage.sql.exec("DELETE FROM attachments WHERE created_at < ?", Date.now() - ATTACHMENT_RETENTION_MS);
    const id = crypto.randomUUID();
    this.ctx.storage.sql.exec(
      "INSERT INTO attachments (id, content_type, data, uploaded_by, created_at) VALUES (?, ?, ?, ?, ?)",
      id, type, data, userKey, Date.now(),
    );
    return { id };
  }

  async getAttachment(userKey, id) {
    this.requireParticipant(userKey);
    const row = this.ctx.storage.sql.exec(
      "SELECT content_type, data FROM attachments WHERE id = ?", id,
    ).toArray()[0];
    if (!row) return null;
    return { contentType: row.content_type, data: row.data };
  }
}
