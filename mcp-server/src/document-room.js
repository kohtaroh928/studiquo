import { DurableObject } from "cloudflare:workers";

// Mirrors chat-room.js's ChatRoom shape closely — same Durable Object
// pattern, same per-room SQLite storage, same requireParticipant-throws-
// Forbidden convention — but for a document's collaborative-review session
// instead of a chat conversation. See the design's change-tracking step:
// an editor's change is recorded as `pending` here and only actually
// applied to `blocks` once a reviewer accepts it, which is what makes this
// a *review* room rather than a live simultaneous-typing one — no
// character-level operational-transform merging is needed, since two
// people's edits to the same block simply sit as two independent pending
// proposals until a reviewer picks one (or both, in sequence).
export class DocumentRoom extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS participants (
          user_key TEXT PRIMARY KEY,
          role TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS blocks (
          block_order INTEGER PRIMARY KEY,
          kind TEXT NOT NULL,
          text TEXT NOT NULL DEFAULT '',
          list_kind TEXT,
          list_level INTEGER NOT NULL DEFAULT 0,
          paragraph_style TEXT
        );
        CREATE TABLE IF NOT EXISTS changes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          author_key TEXT NOT NULL,
          block_order INTEGER NOT NULL,
          previous_text TEXT NOT NULL,
          new_text TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending',
          created_at INTEGER NOT NULL
        );
      `);
    });
  }

  requireParticipant(userKey) {
    const row = this.ctx.storage.sql.exec("SELECT role FROM participants WHERE user_key = ?", userKey).toArray();
    if (row.length !== 1) throw new Error("Forbidden");
    return row[0].role;
  }

  requireReviewer(userKey) {
    const role = this.requireParticipant(userKey);
    if (role !== "owner" && role !== "reviewer") throw new Error("Forbidden");
  }

  // Owner-only, and idempotent like ChatRoom.initialize — a no-op once the
  // room already has participants, so a retried/duplicate "start
  // collaborating" request from the client can't reset an in-progress
  // session (dropping every invited editor/reviewer back out) partway
  // through.
  async initialize(ownerKey, blocks) {
    const existing = this.ctx.storage.sql.exec("SELECT COUNT(*) AS count FROM participants").one().count;
    if (existing > 0) return { status: "already_initialized" };
    this.ctx.storage.sql.exec("INSERT OR IGNORE INTO participants (user_key, role) VALUES (?, 'owner')", ownerKey);
    // Capped the same way ChatRoom.initialize caps its participant list —
    // a defensive bound on how much one request can write, not a design
    // limit on document size.
    for (const block of (Array.isArray(blocks) ? blocks : []).slice(0, 2000)) {
      this.ctx.storage.sql.exec(
        "INSERT OR REPLACE INTO blocks (block_order, kind, text, list_kind, list_level, paragraph_style) VALUES (?, ?, ?, ?, ?, ?)",
        Number(block.order) || 0,
        String(block.kind ?? "paragraph"),
        String(block.text ?? ""),
        block.listKind ?? null,
        Number(block.listLevel) || 0,
        block.paragraphStyle ?? null,
      );
    }
    return { status: "initialized" };
  }

  // Only the owner may invite — an editor/reviewer can't in turn invite
  // someone else into the room.
  async invite(ownerKey, userKey, role) {
    const ownerRole = this.requireParticipant(ownerKey);
    if (ownerRole !== "owner") throw new Error("Forbidden");
    if (role !== "editor" && role !== "reviewer") throw new Error("InvalidRole");
    if (userKey === ownerKey) throw new Error("InvalidRole");
    this.ctx.storage.sql.exec("INSERT OR REPLACE INTO participants (user_key, role) VALUES (?, ?)", userKey, role);
    return { status: "invited" };
  }

  async listParticipants(userKey) {
    this.requireParticipant(userKey);
    return this.ctx.storage.sql.exec("SELECT user_key, role FROM participants").toArray()
      .map(row => ({ userKey: row.user_key, role: row.role }));
  }

  // The full sync payload a client polls for: every block's current
  // (already-reviewed) text, plus every still-open proposal — enough for a
  // device to reconcile its local copy without a separate endpoint per
  // piece.
  async getState(userKey) {
    this.requireParticipant(userKey);
    const blocks = this.ctx.storage.sql.exec("SELECT * FROM blocks ORDER BY block_order ASC").toArray();
    const changes = this.ctx.storage.sql.exec("SELECT * FROM changes WHERE status = 'pending' ORDER BY id ASC").toArray();
    return {
      blocks: blocks.map(row => ({
        order: row.block_order,
        kind: row.kind,
        text: row.text,
        listKind: row.list_kind,
        listLevel: row.list_level,
        paragraphStyle: row.paragraph_style,
      })),
      pendingChanges: changes.map(row => ({
        id: row.id,
        authorKey: row.author_key,
        blockOrder: row.block_order,
        previousText: row.previous_text,
        newText: row.new_text,
        createdAt: row.created_at,
      })),
    };
  }

  // Records a proposed edit — never applied to `blocks` directly. Only the
  // owner or an editor may propose; a reviewer with no editor role can
  // review but not author changes of their own here.
  async proposeChange(userKey, blockOrder, previousText, newText) {
    const role = this.requireParticipant(userKey);
    if (role !== "owner" && role !== "editor") throw new Error("Forbidden");
    const row = this.ctx.storage.sql.exec(
      "INSERT INTO changes (author_key, block_order, previous_text, new_text, status, created_at) VALUES (?, ?, ?, ?, 'pending', ?) RETURNING id",
      userKey, blockOrder, previousText, newText, Date.now(),
    ).one();
    return { id: row.id, status: "pending" };
  }

  // Accepting writes the change's text into `blocks`; rejecting just marks
  // the proposal closed, leaving `blocks` untouched. Already-resolved
  // changes return their existing status rather than erroring, so a
  // double-tap on "承認" from a slow connection is a harmless no-op instead
  // of a surfaced failure.
  async reviewChange(userKey, changeID, decision) {
    this.requireReviewer(userKey);
    if (decision !== "accept" && decision !== "reject") throw new Error("InvalidDecision");
    const change = this.ctx.storage.sql.exec("SELECT * FROM changes WHERE id = ?", changeID).toArray()[0];
    if (!change) return { status: "not_found" };
    if (change.status !== "pending") return { status: change.status };
    if (decision === "accept") {
      this.ctx.storage.sql.exec("UPDATE blocks SET text = ? WHERE block_order = ?", change.new_text, change.block_order);
    }
    const finalStatus = decision === "accept" ? "accepted" : "rejected";
    this.ctx.storage.sql.exec("UPDATE changes SET status = ? WHERE id = ?", finalStatus, changeID);
    return { status: finalStatus };
  }
}
