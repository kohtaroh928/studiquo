import { DurableObject } from "cloudflare:workers";

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
          sent_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_messages_id ON messages(id);
      `);
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

  async sendMessage(userKey, text) {
    this.requireParticipant(userKey);
    const sentAt = Date.now();
    const row = this.ctx.storage.sql.exec(
      "INSERT INTO messages (sender_key, text, sent_at) VALUES (?, ?, ?) RETURNING id",
      userKey, text, sentAt,
    ).one();
    return { id: row.id, text, sentAt, isMine: true };
  }

  async listMessages(userKey, after = 0) {
    this.requireParticipant(userKey);
    const rows = after > 0
      ? this.ctx.storage.sql.exec(
          "SELECT id, sender_key, text, sent_at FROM messages WHERE id > ? ORDER BY id ASC LIMIT 200", after,
        ).toArray()
      : this.ctx.storage.sql.exec(
          "SELECT * FROM (SELECT id, sender_key, text, sent_at FROM messages ORDER BY id DESC LIMIT 200) ORDER BY id ASC",
        ).toArray();
    return rows.map(item => ({
      id: item.id,
      text: item.text,
      sentAt: item.sent_at,
      isMine: item.sender_key === userKey,
    }));
  }
}
