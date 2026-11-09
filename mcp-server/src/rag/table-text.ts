// Reading rows of a table out of plain excerpt text. Comparison only: the excerpt sent to the
// model and shown to the student stays as it was extracted.
// "|", tabs and wide gaps mark cells. Text extracted from a PDF has none of these, so its rows are
// split on single spaces, where one cell can become two tokens ("0.5 A"): `marked` says which it is.
export type TableRow = { cells: string[]; marked: boolean };

export function tableRow(line: string): TableRow {
 const text = line.trim();
 if (text.includes('|')) return { cells: text.replace(/^\||\|$/gu, '').split('|').map(c => c.trim()), marked: true };
 if (/\t| {2,}/u.test(text)) return { cells: text.split(/\t+| {2,}/u).map(c => c.trim()), marked: true };
 return { cells: text.split(/\s+/u), marked: false };
}

const separator = (row: TableRow) => row.marked && row.cells.every(c => /^:?-+:?$/u.test(c));

// Runs of consecutive lines with at least two cells. A line of prose ends a run, so a header
// never reaches across it to a table further down.
export function tableRuns(text: string) {
 const runs: TableRow[][] = [];
 for (const block of text.split(/\n\s*\n/u)) {
  let run: TableRow[] = [];
  for (const line of block.split('\n')) {
   const row = tableRow(line);
   if (separator(row)) continue;
   if (row.cells.length >= 2) { run.push(row); continue; }
   if (run.length) runs.push(run);
   run = [];
  }
  if (run.length) runs.push(run);
 }
 return runs;
}

// The unit a header carries for its column: "価格(円)".
export const headerUnit = (cell: string) => /[(（]([^()（）]{1,8})[)）]\s*$/u.exec(cell)?.[1]?.trim() ?? '';
export const bareNumber = (cell: string) => /^[-−]?\d[\d,.]*$/u.test(cell);

// The excerpt with bare numbers written out with their column's unit, so that "何度" can see
// "融点(°C) | 0". Rows whose cell count differs from the header's are left alone.
export function withTableUnits(text: string) {
 const united: string[] = [];
 for (const run of tableRuns(text)) {
  const units = run[0].cells.map(headerUnit);
  if (!units.some(Boolean)) continue;
  for (const row of run.slice(1)) {
   if (row.cells.length !== units.length) continue;
   row.cells.forEach((cell, i) => { if (units[i] && bareNumber(cell)) united.push(cell + units[i]); });
  }
 }
 return united.length ? `${text}\n${united.join('\n')}` : text;
}
