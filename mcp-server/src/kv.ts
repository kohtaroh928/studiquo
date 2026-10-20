// Small helpers for Workers KV.

/**
 * The cursor to pass to the next `list` call, or undefined when the listing is
 * complete. `cursor` exists only on an incomplete page; checking for the key is
 * what narrows the union without relying on strictNullChecks.
 */
export function nextCursor(page: KVNamespaceListResult<unknown>): string | undefined {
  if (page.list_complete) return undefined;
  return "cursor" in page ? page.cursor : undefined;
}
