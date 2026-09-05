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

export class ChatRoom extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS participants (user_key TEXT PRIMARY KEY);
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
    });
  }

  async initialize(roomID, participants) {
    const existing = this.ctx.storage.sql.exec("SELECT COUNT(*) AS count FROM participants").one().count;
    if (existing > 0) return;
    for (const key of participants.slice(0, 2)) {
      this.ctx.storage.sql.exec("INSERT OR IGNORE INTO participants (user_key) VALUES (?)", key);
    }
  }

  requireParticipant(userKey) {
    const row = this.ctx.storage.sql.exec("SELECT user_key FROM participants WHERE user_key = ?", userKey).toArray();
    if (row.length !== 1) throw new Error("Forbidden");
  }

  // `clientMessageID` is an opaque, client-generated token (nullable) that
  // round-trips back in this same message's row on every future
  // `listMessages` call — it's what lets the sender's own client reconcile
  // its optimistic local copy with its now-confirmed server echo by exact
  // identity, instead of guessing by text content (which breaks down when
  // two messages with identical text are in flight at once).
  async sendMessage(userKey, text, clientMessageID = null) {
    this.requireParticipant(userKey);
    const sentAt = Date.now();
    const row = this.ctx.storage.sql.exec(
      "INSERT INTO messages (sender_key, text, sent_at, client_message_id) VALUES (?, ?, ?, ?) RETURNING id",
      userKey, text, sentAt, clientMessageID,
    ).one();
    return { id: row.id, text, sentAt, isMine: true, clientMessageID };
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

  // Stores an attachment's actual bytes (base64-encoded) in this room, so
  // the other participant — on a different device, with no access to the
  // uploader's local filesystem or app database — can actually retrieve it.
  // Previously an attachment only ever carried a local file path / local
  // database id, which meant nothing outside the sender's own device.
  async storeAttachment(userKey, contentType, base64Data) {
    this.requireParticipant(userKey);
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
