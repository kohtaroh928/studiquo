import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeMathTranscription as n, summarizeMathOCR as summary } from '../scripts/rag-quality/math-ocr-metrics.mjs';
describe('math OCR evaluation preserves structure',()=>{
 it('ignores only spacing, delimiters and fraction styling',()=>{assert.equal(n(' $ \\left(\\dfrac{x}{y}\\right) $ '),n('(\\frac{x}{y})'));});
 for (const [a,b] of [['C_p','Cp'],['x^2','x_2'],['\\frac{x}{y}','\\frac{y}{x}'],['-x','x'],['\\partial x','dx'],['\\Delta x','dx'],['\\mathbf{V}','V'],['x+y','y+x']]) it('retains structural difference',()=>{assert.notEqual(n(a),n(b));});
 it('does not count API failures as recognition successes',()=>{assert.deepEqual(summary([{completed:false},{completed:true,readable:false,elapsedMs:10},{completed:true,readable:true,actual:'x',expected:'x',elapsedMs:20,totalTokens:8}]),{attempted:3,completed:2,executionFailures:1,abstained:1,strictMatches:1,medianElapsedMs:20,measuredTokens:8});});
 it('preserves command boundaries',()=>{assert.notEqual(n('\\alpha b'),n('\\alphab'));assert.equal(n('\\alpha b'),n('\\alpha   b'));});
 it('bounds transcription and sample size',()=>{assert.throws(()=>n('x'.repeat(10001)));assert.throws(()=>summary(new Array(1001)));});
});
