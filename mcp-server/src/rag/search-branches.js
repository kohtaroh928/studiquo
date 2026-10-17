// A stalled branch cannot hold a successful branch until the global RAG
// deadline. Binding work cannot be cancelled; late results are ignored.
export async function boundedSearch(work, timeoutMs = 4000) {
  let timer;
  try {
    return await Promise.race([
      Promise.resolve().then(work),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('search_timeout')), timeoutMs);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
