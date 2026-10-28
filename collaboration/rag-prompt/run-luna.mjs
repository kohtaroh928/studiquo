// Paid generation for the fixed comparison. Runs only with explicit opt-in and a key in the
// environment. Sends the prepared bodies unchanged, one at a time, with no retry; stops at the
// first failure or when the call/budget limit would be exceeded. Answer text is written only to
// the private .local run directory and never printed.
import {readFileSync, mkdirSync, writeFileSync, renameSync, openSync, writeSync, fsyncSync, closeSync, existsSync} from 'node:fs';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {preparePacket} from './workspace.ts';

const root = fileURLToPath(new URL('./', import.meta.url));
const API_URL = 'https://api.openai.com/v1/responses';
// gpt-6-luna standard text pricing checked 2026-10-18 (API_ACCESS.md). Reservation, not a bill.
const USD_PER_INPUT_TOKEN = 0.10 / 1e6, USD_PER_OUTPUT_TOKEN = 0.50 / 1e6;
const hash = value => createHash('sha256').update(typeof value === 'string' ? value : JSON.stringify(value)).digest('hex');
const NAME = /^[a-z][a-z0-9-]{0,63}$/;

// One request per (variant, case, style). The baseline body is shared by every candidate packet.
export function buildPlan(candidateNames, load = name => JSON.parse(readFileSync(path.join(root, 'candidates', name + '.json'), 'utf8')), caseSet = 'fixed6') {
  const requests = new Map();
  for (const name of candidateNames) {
    const packet = preparePacket(load(name), caseSet);
    for (const pair of packet.pairs) {
      const base = ['baseline', pair.caseKey, pair.style].join('|');
      if (requests.has(base) && requests.get(base).bodyHash !== pair.baselineHash) throw Error('baseline_mismatch');
      requests.set(base, {id: base, variant: 'baseline', caseKey: pair.caseKey, style: pair.style, bodyHash: pair.baselineHash, body: pair.baseline});
      const cand = [packet.candidateId, pair.caseKey, pair.style].join('|');
      requests.set(cand, {id: cand, variant: packet.candidateId, caseKey: pair.caseKey, style: pair.style, bodyHash: pair.candidateHash, body: pair.candidate});
    }
  }
  // Rotate which variant goes first for each (case, style) so order effects are spread out.
  const groups = new Map();
  for (const r of requests.values()) groups.set(r.caseKey + '|' + r.style, [...(groups.get(r.caseKey + '|' + r.style) ?? []), r]);
  const ordered = [...groups.values()].flatMap((group, i) => group.map((_, j) => group[(i + j) % group.length]));
  return {planHash: hash(ordered.map(r => r.id + ':' + r.bodyHash)), requests: ordered};
}

export const reserveUSD = body => JSON.stringify(body).length * USD_PER_INPUT_TOKEN + body.max_output_tokens * USD_PER_OUTPUT_TOKEN;

// Reads a Responses SSE stream into text, usage and the served model alias.
export async function readStream(response) {
  if (!response.ok || !response.body) throw Error('http_' + response.status);
  const decoder = new TextDecoder();
  let buffer = '', text = '', done = null;
  for await (const chunk of response.body) {
    buffer += decoder.decode(chunk, {stream: true});
    let cut;
    while ((cut = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, cut).trim();
      buffer = buffer.slice(cut + 1);
      if (!line.startsWith('data:')) continue;
      const data = line.slice(5).trim();
      if (data === '[DONE]') continue;
      const event = JSON.parse(data);
      if (event.type === 'response.output_text.delta') text += event.delta;
      else if (event.type === 'response.completed') done = event.response;
      else if (event.type === 'response.failed' || event.type === 'error') throw Error('stream_failed');
    }
  }
  if (!done) throw Error('stream_incomplete');
  return {text, model: done.model ?? null, usage: done.usage ?? null};
}

function appendJournal(file, row) {
  const fd = openSync(file, 'a', 0o600);
  try {writeSync(fd, JSON.stringify(row) + '\n'); fsyncSync(fd);} finally {closeSync(fd);}
}
function writePrivate(file, value) {
  writeFileSync(file + '.tmp', JSON.stringify(value, null, 2) + '\n', {mode: 0o600});
  renameSync(file + '.tmp', file);
}

export async function run({runName, candidates, maxCalls, budgetUSD, apiKey, fetchImpl = fetch, resume = false, outputRoot = path.join(root, '.local'), caseSet = 'fixed6'}) {
  if (!NAME.test(runName) || !candidates.length || !candidates.every(c => NAME.test(c))) throw Error('invalid_names');
  if (!Number.isInteger(maxCalls) || maxCalls < 1 || !(budgetUSD > 0)) throw Error('invalid_limits');
  const plan = buildPlan(candidates, undefined, caseSet);
  const dir = path.join(outputRoot, runName), journal = path.join(dir, 'journal.ndjson');
  const answersFile = path.join(dir, 'answers.json'), metricsFile = path.join(dir, 'metrics.json');
  if (!apiKey) throw Error('missing_key');
  const state = new Map();
  let calls = 0, reserved = 0;
  if (resume) {
    const saved = JSON.parse(readFileSync(path.join(dir, 'plan.json'), 'utf8'));
    if (saved.planHash !== plan.planHash || saved.maxCalls !== maxCalls || saved.budgetUSD !== budgetUSD) throw Error('plan_changed');
    for (const line of readFileSync(journal, 'utf8').split('\n').filter(Boolean)) {
      const row = JSON.parse(line); state.set(row.id, row);
      if (row.state === 'reserved') {calls += 1; reserved += row.reservedUSD;}
    }
    // A reservation without an outcome may have reached the provider; a person resolves it.
    if ([...state.values()].some(row => row.state === 'reserved')) throw Error('unresolved_send');
    if ([...state.values()].some(row => row.state === 'failed')) throw Error('previous_failure');
  } else {
    mkdirSync(outputRoot, {recursive: true, mode: 0o700});
    mkdirSync(dir, {mode: 0o700});
    writeFileSync(path.join(dir, 'plan.json'), JSON.stringify({version: 1, planHash: plan.planHash, maxCalls, budgetUSD, candidates, caseSet,
      requests: plan.requests.map(r => ({id: r.id, bodyHash: r.bodyHash}))}, null, 2) + '\n', {flag: 'wx', mode: 0o600});
  }
  const answers = existsSync(answersFile) ? JSON.parse(readFileSync(answersFile, 'utf8')) : {version: 1, planHash: plan.planHash, variants: {}};
  const metrics = existsSync(metricsFile) ? JSON.parse(readFileSync(metricsFile, 'utf8')) : {version: 1, planHash: plan.planHash, rows: []};
  for (const request of plan.requests) {
    if (state.get(request.id)?.state === 'completed') continue;
    const cost = reserveUSD(request.body);
    if (calls + 1 > maxCalls || reserved + cost > budgetUSD) return {stopped: 'limit', calls, reservedUSD: reserved};
    appendJournal(journal, {id: request.id, bodyHash: request.bodyHash, state: 'reserved', reservedUSD: cost, at: new Date().toISOString()});
    calls += 1; reserved += cost;
    const started = Date.now();
    try {
      const response = await fetchImpl(API_URL, {method: 'POST', signal: AbortSignal.timeout(60000),
        headers: {'content-type': 'application/json', authorization: 'Bearer ' + apiKey}, body: JSON.stringify(request.body)});
      const result = await readStream(response);
      (answers.variants[request.variant] ??= {})[request.caseKey + '|' + request.style] = result.text;
      writePrivate(answersFile, answers);
      metrics.rows.push({id: request.id, model: result.model, usage: result.usage, elapsedMs: Date.now() - started, answerHash: hash(result.text)});
      writePrivate(metricsFile, metrics);
      appendJournal(journal, {id: request.id, bodyHash: request.bodyHash, state: 'completed', reservedUSD: 0});
    } catch (error) {
      // Only a short code is kept; provider error text can echo request content.
      const code = /^(http_\d+|stream_\w+)$/.test(error.message) ? error.message : error.name === 'TimeoutError' ? 'timeout' : 'request_error';
      appendJournal(journal, {id: request.id, bodyHash: request.bodyHash, state: 'failed', code, reservedUSD: 0});
      return {stopped: 'failure', code, calls, reservedUSD: reserved};
    }
  }
  return {stopped: 'done', calls, reservedUSD: reserved};
}

function parseArgs(args) {
  const [runName, list, ...rest] = args, opts = {resume: false};
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === '--resume') opts.resume = true;
    else if (rest[i] === '--max-calls') opts.maxCalls = Number(rest[++i]);
    else if (rest[i] === '--budget-usd') opts.budgetUSD = Number(rest[++i]);
    else if (rest[i] === '--cases') opts.caseSet = rest[++i];
    else throw Error('usage');
  }
  return {runName, candidates: (list ?? '').split(',').filter(Boolean), ...opts};
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    if (process.env.STUDIQUO_RAG_PROMPT_REMOTE !== 'true') throw Error('remote_opt_in_required');
    if (Number(process.versions.node.split('.')[0]) < 24) throw Error('node_24_required');
    const result = await run({...parseArgs(process.argv.slice(2)), apiKey: process.env.STUDIQUO_RAG_EVAL_OPENAI_KEY});
    console.log(JSON.stringify(result));
    if (result.stopped !== 'done') process.exitCode = 1;
  } catch (error) {
    console.error('rag_prompt_run_stopped: ' + (/^[a-z_0-9]+$/.test(error.message) ? error.message : 'error'));
    process.exitCode = 1;
  }
}
