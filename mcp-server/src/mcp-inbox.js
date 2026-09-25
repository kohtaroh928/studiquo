import { DurableObject } from "cloudflare:workers";

// One object per Studiquo account serializes submissions and acknowledgements.
export class MCPInbox extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS items (
      id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload TEXT NOT NULL,
      source TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
      created_at INTEGER NOT NULL, imported_at INTEGER
    )`);
    this.sql.exec("CREATE TABLE IF NOT EXISTS consumed_tokens (id TEXT PRIMARY KEY, used_at INTEGER NOT NULL)");
  }

  async consumeOnce(id) {
    if ([...this.sql.exec("SELECT id FROM consumed_tokens WHERE id = ?", id)].length) return false;
    this.sql.exec("INSERT INTO consumed_tokens (id, used_at) VALUES (?, ?)", id, Date.now());
    this.sql.exec("DELETE FROM consumed_tokens WHERE used_at < ?", Date.now() - 90 * 24 * 3600 * 1000);
    return true;
  }

  async enqueue(id, kind, payload, source) {
    this.sql.exec("DELETE FROM items WHERE status = 'imported' AND imported_at < ?", Date.now() - 90 * 24 * 3600 * 1000);
    const pending = [...this.sql.exec("SELECT COUNT(*) AS count FROM items WHERE status = 'pending'")][0].count;
    if (pending >= 100) throw new Error("Studiquo has 100 pending imports. Open the iPad app before sending more.");
    this.sql.exec(
      "INSERT OR IGNORE INTO items (id, kind, payload, source, created_at) VALUES (?, ?, ?, ?, ?)",
      id, kind, JSON.stringify({ type: kind, ...payload }), source, Date.now()
    );
    return { id, status: "pending" };
  }

  async list() {
    return [...this.sql.exec(
      "SELECT id, kind, payload, source, status, created_at FROM items WHERE status = 'pending' ORDER BY created_at LIMIT 100"
    )].map(row => ({ ...row, payload: JSON.parse(row.payload) }));
  }

  async acknowledge(id) {
    this.sql.exec(
      "UPDATE items SET status = 'imported', imported_at = ? WHERE id = ? AND status = 'pending'",
      Date.now(), id
    );
    return { id, status: [...this.sql.exec("SELECT status FROM items WHERE id = ?", id)][0]?.status ?? "missing" };
  }

  async status(id) {
    return [...this.sql.exec("SELECT id, status, imported_at FROM items WHERE id = ?", id)][0] ?? null;
  }
}
