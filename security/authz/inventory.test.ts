import assert from 'node:assert/strict';
import test from 'node:test';
import {readFileSync,readdirSync} from 'node:fs';
import {join,relative} from 'node:path';
import {root} from './runtime.ts';
import {routes,type Route} from './routes.ts';
type Declaration={file:string;line:number;pattern:RegExp;method?:string};
const declarations:Declaration[]=[];
function files(dir:string):string[]{return readdirSync(dir,{withFileTypes:true}).flatMap(e=>e.isDirectory()?files(join(dir,e.name)):e.name.endsWith('.ts')&&!e.name.endsWith('.test.ts')&&!e.name.startsWith('test-')?[join(dir,e.name)]:[]);}
const escape=(s:string)=>s.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
function patterns(text:string){
  return [...text.matchAll(/\/\^(\\\/api[^\r\n]*?)\$\/([a-z]*)/g)].flatMap(m=>{
    const choice=/\((accept\|decline|accept\|reject|process\|cancel|push\|push-test)\)/.exec(m[1]);
    return (choice?choice[1].split('|').map(v=>m[1].replace(choice[0],v)):[m[1]]).map(p=>new RegExp('^'+p+'$',m[2]));
  });
}
// Bounded source audit for the repository's literal/regex routing idiom.
// Dynamic PDF RegExp templates and prefix handlers are listed explicitly;
// this is not arbitrary TypeScript control-flow analysis.
for(const file of files(join(root,'mcp-server/src'))){
  const text=readFileSync(file,'utf8');
  const matches=new Map<string,RegExp[]>();
  for(const m of text.matchAll(/const\s+(\w+)\s*=([^;\n]+);/g)){
    const p=patterns(m[2]);if(p.length)matches.set(m[1],p);
  }
  const add=(index:number,pattern:RegExp,method?:string)=>declarations.push({file:relative(root,file),line:text.slice(0,index).split('\n').length,pattern,method});
  for(const m of text.matchAll(/\.pathname\s*(?:===|!==)\s*(["'])(\/(?:api|oauth)\/[^"']+|\/mcp)\1/g)){
    if(!m[2].endsWith('/'))add(m.index!,new RegExp('^'+escape(m[2])+'$'));
  }
  for(const m of text.matchAll(/\/\^(\\\/api[^\r\n]*?)\$\/[a-z]*/g))for(const p of patterns(m[0]))add(m.index!,p);
  for(const m of text.matchAll(/if\s*\(([\s\S]*?)\)\s*(?:\{|return)/g))for(const clause of m[1].split('||')){
    const ps:RegExp[]=[];
    for(const p of clause.matchAll(/\.pathname\s*===\s*(["'])(\/[^"']+)\1/g))ps.push(new RegExp('^'+escape(p[2])+'$'));
    for(const [name,list] of matches)if(new RegExp('\\b'+escape(name)+'\\b').test(clause))ps.push(...list);
    for(const method of clause.matchAll(/request\.method\s*===\s*["']([A-Z]+)["']/g))for(const p of ps)add(m.index!,p,method[1]);
  }
}
function uncovered(table:Route[]){return declarations.filter(d=>!table.some(r=>d.pattern.test(r.path)&&(!d.method||r.method===d.method))).map(d=>`${d.file}:${d.line} ${d.method??'*'} ${d.pattern.source}`);}
test('literal/regex source routes and explicit method guards are represented in the policy inventory',()=>assert.deepEqual(uncovered(routes),[]));
test('inventory audit catches losing POST while retaining GET on the same URL',()=>{
  const reduced=routes.filter(r=>!(r.path.includes('/api/chat/rooms/')&&r.path.endsWith('/messages')&&r.method==='POST'));
  assert.ok(uncovered(reduced).some(s=>s.includes('POST')&&s.includes('messages')));
});
test('inventory audit catches losing a nested RAG route',()=>{
  assert.ok(uncovered(routes.filter(r=>r.path!=='/api/rag/status')).some(s=>s.includes('rag')&&s.includes('status')));
});
