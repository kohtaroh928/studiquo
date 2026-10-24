// Evaluation only. Preserve mathematical structure; never simplify algebra or rename variables.
export function normalizeMathTranscription(value: any) {
 if (typeof value !== 'string' || value.length > 10000) throw new Error('invalid_transcription');
 const canonical = value.trim().replace(/^\$\$?|\$\$?$/gu, '')
  .replace(/\\(?:left|right)(?![A-Za-z])/gu, '')
  .replace(/\\(?:dfrac|tfrac)(?![A-Za-z])/gu, '\\frac')
  .replace(/[−–]/gu, '-');
 // Tokenize before discarding whitespace: \\alpha b must not become \\alphab.
 return (canonical.match(/\\[A-Za-z]+|\\.|[^\s]/gu) ?? []).join('\u001f');
}
export function summarizeMathOCR(rows: any) {
 if (!Array.isArray(rows) || rows.length > 1000) throw new Error('invalid_rows');
 const completed = rows.filter(r => r.completed === true);
 const readable = completed.filter(r => r.readable === true);
 const times = completed.map(r => r.elapsedMs).filter(t => Number.isFinite(t) && t >= 0).sort((a,b)=>a-b);
 return { attempted: rows.length, completed: completed.length, executionFailures: rows.length-completed.length,
  abstained: completed.length-readable.length,
  strictMatches: readable.filter(r => normalizeMathTranscription(r.expected) === normalizeMathTranscription(r.actual)).length,
  medianElapsedMs: times.length ? times[Math.floor(times.length/2)] : null,
  // Every provider response, including failures, may incur tokens. Do not call this a bill.
  measuredTokens: rows.reduce((n,r)=>n+(Number.isFinite(r.totalTokens)&&r.totalTokens>=0?r.totalTokens:0),0) };
}
