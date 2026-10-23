import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
export function qualityEnvironment({ legacy = false }: any = {}) {
  const db = new DatabaseSync(':memory:');
  db.exec(readFileSync(new URL('../migrations/0006_rag.sql', import.meta.url) as any, 'utf8') as any);
  if (!legacy) db.exec(readFileSync(new URL("../migrations/0007_rag_context.sql", import.meta.url) as any, "utf8") as any);
  if (!legacy) db.exec(readFileSync(new URL("../migrations/0008_rag_control.sql", import.meta.url) as any, "utf8") as any);
  const prepare = (sql: any) => ({ bind(...args: any[]) { return {
    first: async () => db.prepare(sql).get(...args) ?? null,
    all: async () => ({ results: db.prepare(sql).all(...args) }),
    run: async () => ({ meta: { changes: Number(db.prepare(sql).run(...args).changes) } }),
  }; } });
  const vectors = new Map(); const calls: any[] = [];
  return {
    RAG_ENABLED: 'true', calls, vectors,
    ADMIN_DB: { db, prepare, async batch(statements: any) {
      db.exec('BEGIN');
      try { const out = []; for (const s of statements) out.push(await s.run()); db.exec('COMMIT'); return out; }
      catch (error) { db.exec('ROLLBACK'); throw error; }
    } },
    RATE_LIMIT_RAG_SEARCH: { limit: async () => ({ success: true }) },
    AI: { async run(model: any, input: any) {
      calls.push({ model, input });
      return model.includes('reranker')
        ? { response: input.contexts.map((_: any, id: any) => ({ id, score: 1 - id / 100 })) }
        : { data: input.text.map(() => Array(1024).fill(0.1)) };
    } },
    RAG_VECTORIZE: {
      async upsert(rows: any) { rows.forEach((r: any) => vectors.set(r.id, r)); },
      async getByIds(ids: any) { return ids.map((id: any) => vectors.get(id)).filter(Boolean); },
      async deleteByIds(ids: any) { ids.forEach((id: any) => vectors.delete(id)); },
      async query(_: any, options: any) { return { matches: [...vectors.values()]
        .filter(v => Object.entries(options.filter).every(([k, val]) => v.metadata[k] === val))
        .slice(0, options.topK).map(v => ({ id: v.id, score: 0.8 })) }; },
    },
  };
}
export const qualitySource = (overrides: any = {}) => ({
  sourceId: 'quality-source', title: '合成教材', kind: 'notebook', sourceHash: 'a'.repeat(64), totalPages: 1,
  pages: [{ pageNumber: 1, text: '光合成は植物が光を使って養分を作るしくみ。' }], ...overrides,
});
