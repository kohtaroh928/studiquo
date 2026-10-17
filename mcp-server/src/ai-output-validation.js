import { z } from 'zod';

// Match the existing public response shapes. Cross-field factual correctness is
// evaluated separately; validation must never coerce, repair or drop fields.
// JSON Schema integer means finite integral numbers, without adding a new range.
const integer = z.number().refine(Number.isInteger).meta({ type: 'integer' });
const rubric = z.strictObject({
  criteria: z.array(z.strictObject({
    name: z.string(), maxPoints: integer, requirement: z.string(),
  })),
});
const grade = z.strictObject({
  score: integer, maxScore: integer, verdict: z.string(),
  criteria: z.array(z.strictObject({
    name: z.string(), earnedPoints: integer, maxPoints: integer, comment: z.string(),
  })),
  issues: z.array(z.strictObject({
    step: integer,
    kindRawValue: z.enum(['logical_gap', 'counterexample', 'definition_error', 'calculation_error', 'unjustified_assumption', 'presentation']),
    excerpt: z.string(), explanation: z.string(), suggestion: z.string(),
  })),
});
const review = z.strictObject({
  isStudyRelevant: z.boolean(), explanationMarkdown: z.string(),
  quiz: z.array(z.strictObject({ question: z.string(), answer: z.string() })),
});
const schemas = new Map([['rubric', rubric], ['grade', grade], ['review', review]]);
export const MAX_STRUCTURED_OUTPUT_BYTES = 131072;
function fail() { throw new Error('invalid_structured_output'); }

export function structuredOutputJSONSchema(name) {
  const schema = schemas.get(name);
  if (!schema) fail();
  const { $schema, ...json } = z.toJSONSchema(schema);
  return json;
}

export function parseStructuredOutput(name, raw) {
  const schema = schemas.get(name);
  if (!schema || typeof raw !== 'string' || new TextEncoder().encode(raw).byteLength > MAX_STRUCTURED_OUTPUT_BYTES) fail();
  let value;
  try { value = JSON.parse(raw); } catch { fail(); }
  const parsed = schema.safeParse(value);
  if (!parsed.success) fail(); // Never expose Zod errors containing user content.
  return parsed.data;
}
