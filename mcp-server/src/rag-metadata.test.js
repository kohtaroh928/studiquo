import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {qualityEnvironment,qualitySource} from './rag-quality-fixture.js';
import {accountKey,indexSource,deleteSource,deleteAccountRAG} from './rag/storage.js';
import {sha256Hex} from './auth.js';
import {canonicalJSON,structuredCitation,prepareStructuredInput} from './rag/structured-input.js';
async function payload(){
 const document={parser:{name:'docling',version:'2.139.0',profile:'native-layout-table-v1'},pdfSha256:'a'.repeat(64),strategy:'structure-semantic-recursive-v1',semanticApplied:false,semanticModel:null,maxEstimatedTokens:400,maxOverlapEstimatedTokens:65,semanticDistanceThreshold:0.35,semanticFallbackReason:'no_vectors',namespaceScope:'document_parser_only_not_authentication',offsetUnit:'unicode_codepoint',provenanceScope:'element'};
 const documentNamespace=await sha256Hex(canonicalJSON({parser:document.parser,pdfSha256:document.pdfSha256}));
 const text='合成教材の価格は900円。';
 const metadata={documentNamespace,kind:'text',elementId:'#/texts/0',localId:'b'.repeat(64),idSource:'docling_self_ref',pageNumbers:[1],provenanceScope:'element',provenance:[{pageNumber:1,bbox:{l:1,t:2,r:3,b:4,coordOrigin:'TOPLEFT'},charspan:[0,Array.from(text).length]}],coordinateState:'known',headingPath:{state:'unknown',reason:'missing_parent',items:[]},contextRefs:[{role:'parent',elementId:'#/body',resolved:false}],review:{needsReview:false,needsOCR:false,reviewRequired:false,oversized:false},source:{start:0,end:Array.from(text).length,offsetUnit:'unicode_codepoint',textSha256:await sha256Hex(text)}};
 return qualitySource({kind:'pdf',structure:{version:1,document,documentNamespace},pages:[{pageNumber:1,text,structured:{version:1,records:[{text,metadata}]}}]});
}
function environment(upgrade=true){const env=qualityEnvironment();if(upgrade)env.ADMIN_DB.db.exec(readFileSync(new URL('../migrations/0009_rag_metadata.sql',import.meta.url),'utf8'));return env;}
const stored=env=>env.ADMIN_DB.db.prepare('SELECT * FROM rag_chunks WHERE ready=1').all();
test('structured exact records, canonical owner, preserved metadata and unchanged skip',async()=>{
 const env=environment(),key=await accountKey('owner'),p=await payload();try{await indexSource(env,key,p);const row=stored(env)[0];assert.equal(row.text,p.pages[0].text);assert.equal(row.account_key,key);assert.notEqual(row.chunk_id,p.pages[0].structured.records[0].metadata.localId);assert.equal(JSON.parse(row.metadata_json).record.elementId,'#/texts/0');const calls=env.calls.length;assert.equal((await indexSource(env,key,p)).skipped,1);assert.equal(env.calls.length,calls);assert.ok(structuredCitation([row]));}finally{env.ADMIN_DB.db.close();}
});
test('metadata-only fresh IDs reuse embeddings; folder clones retain metadata',async()=>{
 const env=environment(),key=await accountKey('owner'),p=await payload();try{await indexSource(env,key,p);const old=stored(env)[0],calls=env.calls.length;p.pages[0].structured.records[0].metadata.provenance[0].bbox.l=2;await indexSource(env,key,p);const next=stored(env)[0];assert.notEqual(next.chunk_id,old.chunk_id);assert.notEqual(next.page_hash,old.page_hash);assert.equal(next.embedding_hash,old.embedding_hash);assert.equal(env.calls.length,calls);assert.equal(JSON.parse(next.metadata_json).record.provenance[0].bbox.l,2);p.folderId='moved-folder';await indexSource(env,key,p);assert.equal(stored(env)[0].metadata_json,next.metadata_json);assert.equal(stored(env)[0].vector_folder,'moved-folder');assert.equal(env.calls.length,calls);}finally{env.ADMIN_DB.db.close();}
});
test('common metadata changes context generation while reusing text embeddings',async()=>{
 const env=environment(),key=await accountKey('owner'),p=await payload();try{await indexSource(env,key,p);const old=stored(env)[0],calls=env.calls.length;p.structure.document.maxEstimatedTokens=399;await indexSource(env,key,p);assert.notEqual(stored(env)[0].chunk_id,old.chunk_id);assert.equal(env.calls.length,calls);}finally{env.ADMIN_DB.db.close();}
});
test('old schema rejects structured before mutation and preserves legacy indexing',async()=>{
 const env=environment(false),key=await accountKey('owner');try{await assert.rejects(indexSource(env,key,await payload()),/index_upgrade_required/);assert.equal(env.ADMIN_DB.db.prepare('SELECT count(*) AS n FROM rag_accounts').get().n,0);await indexSource(env,key,qualitySource());assert.equal(stored(env).length,1);}finally{env.ADMIN_DB.db.close();}
});
test('invalid structured fields never create account/source or invoke embedding',async()=>{
 const changes=[p=>p.pages[0].structured.records[0].metadata.review.needsOCR=true,p=>p.pages[0].structured.records[0].metadata.kind='picture',p=>p.pages[0].structured.records[0].metadata.pageNumbers=[2],p=>p.pages[0].structured.records[0].metadata.source.textSha256='0'.repeat(64),p=>p.pages[0].structured.records[0].metadata.accountKey='forged',p=>p.structure.document.parser.extra='bad',p=>p.pages[0].structured.records[0].metadata.source.end++,p=>p.pages[0].structured.records[0].text='漢'.repeat(501),p=>delete p.structure];
 for(const change of changes){const env=environment(),p=await payload();change(p);try{await assert.rejects(indexSource(env,await accountKey('owner'),p),/invalid_structured_input/);assert.equal(env.ADMIN_DB.db.prepare('SELECT count(*) AS n FROM rag_accounts').get().n,0);assert.equal(env.calls.length,0);}finally{env.ADMIN_DB.db.close();}}
});
test('source/account erasure cleans stored metadata and vectors',async()=>{
 for(const account of [false,true]){const env=environment(),key=await accountKey('owner'),p=await payload();try{await indexSource(env,key,p);if(account)await deleteAccountRAG(env,'owner');else await deleteSource(env,key,p.sourceId);assert.equal(stored(env).length,0);assert.equal(env.vectors.size,0);}finally{env.ADMIN_DB.db.close();}}
});
test('citation projection rejects malformed/mixed metadata and leaves legacy undefined',async()=>{
 const env=environment(),key=await accountKey('owner');try{await indexSource(env,key,await payload());const row=stored(env)[0],citation=structuredCitation([row]);assert.equal(citation.segments[0].chunkId,row.chunk_id);assert.equal(citation.provenanceScope,'element');assert.equal(structuredCitation([{metadata_json:null}]),undefined);assert.throws(()=>structuredCitation([row,{metadata_json:null}]),/invalid_metadata/);assert.throws(()=>structuredCitation([{...row,metadata_json:'{}'}]),/invalid_metadata/);}finally{env.ADMIN_DB.db.close();}
});
test('structured page hashes are canonical, independent of incoming property order',async()=>{
 const p=await payload(),a=await prepareStructuredInput(p),q=structuredClone(p),source=q.pages[0].structured.records[0].metadata.source;q.pages[0].structured.records[0].metadata.source={textSha256:source.textSha256,offsetUnit:'unicode_codepoint',end:source.end,start:0};const b=await prepareStructuredInput(q);assert.equal(a.pages.get(1).pageHash,b.pages.get(1).pageHash);
});

test('identical client namespace/local IDs never merge different canonical users',async()=>{
 const env=environment(),p=await payload(),a=await accountKey('owner-a'),b=await accountKey('owner-b');try{await indexSource(env,a,p);await indexSource(env,b,p);const records=stored(env);assert.equal(records.length,2);assert.notEqual(records[0].chunk_id,records[1].chunk_id);await deleteSource(env,a,p.sourceId);assert.equal(stored(env).length,1);assert.equal(stored(env)[0].account_key,b);}finally{env.ADMIN_DB.db.close();}
});
test('authorization cancelled during embedding leaves no ready metadata chunk',async()=>{
 const env=environment(),p=await payload(),key=await accountKey('owner'),original=env.AI.run;env.AI.run=async(...args)=>{env.ADMIN_DB.db.prepare('UPDATE rag_accounts SET deleted=1 WHERE account_key=?').run(key);return original(...args);};try{await assert.rejects(indexSource(env,key,p),/index_cancelled/);assert.equal(stored(env).length,0);assert.equal(env.vectors.size,0);}finally{env.ADMIN_DB.db.close();}
});
