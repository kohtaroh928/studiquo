// D2b-A: actual local RPC/storage confirmation, with synthetic VM IO only.
// A historical destroy observation does not authorize retention or physical purge.
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {unstable_splitSqlQuery} from 'wrangler';
import {readFileSync,readdirSync,mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import assert from 'node:assert/strict';
import {sha256Hex} from '../src/auth.js';
import {canonicalJSON} from '../src/rag/structured-input.js';
import {processRawPDF} from '../src/rag/pdf-process.js';
import {accountKey} from '../src/rag/storage.js';
import {updateConsent} from '../src/rag/control.js';
import {updateRawPDFConsent} from '../src/rag/pdf-authorization.js';
import {prepareRawPDFIntake,cancelRawPDFIntake} from '../src/rag/pdf-intake.js';
import {cancelRawPDFProcessor} from '../src/rag/pdf-rpc.js';
 const bytes=new TextEncoder().encode('%PDF-synthetic'),pdfSha256=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
 const document={parser:{name:'docling',version:'2.139.0',profile:'native-layout-table-v1'},pdfSha256,strategy:'structure-semantic-recursive-v1',semanticApplied:false,semanticModel:null,maxEstimatedTokens:400,maxOverlapEstimatedTokens:65,semanticDistanceThreshold:0.35,semanticFallbackReason:'no_vectors',namespaceScope:'document_parser_only_not_authentication',offsetUnit:'unicode_codepoint',provenanceScope:'element'};
 const documentNamespace=await sha256Hex(canonicalJSON({parser:document.parser,pdfSha256})),text='Synthetic paragraph.';
 const metadata={documentNamespace,kind:'text',elementId:'#/texts/0',localId:'b'.repeat(64),idSource:'docling_self_ref',pageNumbers:[1],provenanceScope:'element',provenance:[{pageNumber:1,bbox:null,charspan:[0,text.length]}],coordinateState:'unknown',headingPath:{state:'unknown',reason:'missing_parent',items:[]},contextRefs:[],review:{needsReview:false,needsOCR:false,reviewRequired:false,oversized:false},source:{start:0,end:text.length,offsetUnit:'unicode_codepoint',textSha256:await sha256Hex(text)}};
 const manifest={version:1,integration:'prepared_only_no_upload',batches:[{structure:{version:1,document,documentNamespace},totalPages:1,pages:[{pageNumber:1,text,structured:{version:1,records:[{text,metadata}]}}]}]};

const source=readFileSync(new URL('../../services/docling-worker/index.js',import.meta.url),'utf8')
 .replaceAll('this.ctx.container','this.syntheticContainer');
const probe=`
export class RPCProbe extends DoclingJob {
 constructor(ctx,env){super(ctx,env);let finish;const monitor=new Promise(r=>finish=r);
 this.syntheticContainer={start(){},monitor:()=>monitor,getTcpPort:()=>({fetch:async url=>
  url.endsWith('/ready')?new Response(null,{status:204}):new Response(env.SYNTHETIC_MANIFEST,{headers:{'Content-Type':'application/json'}})}),destroy:async()=>finish()};
 }
 async inspect(){return (await this.ctx.storage.get('job'))??null;}
}
`;
const temp=mkdtempSync(join(tmpdir(),'studiquo-destroy-confirmation-smoke-'));
const mf=new Miniflare(convertV4MiniflareOptions({host:'127.0.0.1',cf:false,persist:temp,workers:[
 {name:'caller',modules:true,script:"export default {fetch(){return new Response('ok')}}",compatibilityDate:'2026-08-27',
  d1Databases:['ADMIN_DB'],serviceBindings:{DOCLING_PROCESSOR:{name:'private-docling',entrypoint:'DoclingProcessor'}}},
 {name:'private-docling',modules:true,script:source+probe,compatibilityDate:'2026-08-27',
  bindings:{DOCLING_RPC_V2_ONLY:'true',DOCLING_EXECUTION_ENABLED:'true',SYNTHETIC_MANIFEST:JSON.stringify(manifest)},
  durableObjects:{DOCLING_JOBS:{className:'RPCProbe',useSQLite:true}}}
]}));
try{
 const db=await mf.getD1Database('ADMIN_DB','caller'),dir=new URL('../migrations/',import.meta.url);let files=0;
 for(const name of readdirSync(dir).filter(n=>/^00(?:0[1-9]|1[0-8])_.*\.sql$/u.test(n)).sort()){
  for(const sql of unstable_splitSqlQuery(readFileSync(new URL(name,dir),'utf8')))await db.prepare(sql).run();files++;
 }
 assert.equal(files,18);
 const {DOCLING_PROCESSOR}=await mf.getBindings('caller');
 const env={ADMIN_DB:db,DOCLING_PROCESSOR,RAG_ENABLED:'true',AI_PROVIDER_APPROVED:'true',RAG_AUTO_INDEX_ENABLED:'true',
  RAG_PDF_PROCESSING_ENABLED:'true',RAG_PDF_STOP_EVIDENCE_ENABLED:'true',RAG_PDF_RPC_V2_ENABLED:'true'};
 const session={sub:'synthetic-local-rpc-v2'},key=await accountKey(session.sub);
 await updateConsent(env,key,{enabled:true,expectedEpoch:0});
 await updateRawPDFConsent(env,session,{enabled:true,expectedEpoch:0,consentEpoch:1,consentVersion:'raw-pdf-docling-v1'});
 const proof=await prepareRawPDFIntake(env,session,{documentId:'synthetic-document',requestId:'synthetic-request',expectedGeneration:0,
  pdfSha256,byteLength:bytes.length,consentEpoch:1,rawPDFConsentEpoch:1});
 const limits={perOwnerActive:1,globalActive:2,globalMemoryBytes:96*1024*1024,perOwnerDailyUnits:10,globalDailyUnits:20,
  reservationUnits:3,perOwnerDailyRequests:10,globalDailyRequests:20};
 const request=new Request('https://example.test/internal',{method:'POST',body:bytes,headers:{'Content-Type':'application/pdf',
  'X-Studiquo-AI-Consent':'openai-v1','X-Studiquo-Age':'adult','X-Studiquo-RAG-Consent':'rag-openai-v1','X-Studiquo-Raw-PDF-Consent':'raw-pdf-docling-v1'}});
 const result=await processRawPDF(env,session,proof,request,limits,{pollMs:250,workMs:10000,cleanupMs:2000,
  consumeResult:async value=>{assert.deepEqual(value,manifest);}});
 assert.equal(result.consumed,true);
 const saved=await db.prepare('SELECT * FROM rag_pdf_jobs').first();assert.equal(saved.state,'settled');assert.equal(saved.rpc_version,2);
 assert.equal(saved.rpc_not_after,saved.deadline);assert.equal(saved.rpc_pdf_sha256,pdfSha256);assert.equal(saved.settled_units,3);
 const evidence=await db.prepare('SELECT * FROM rag_pdf_execution_evidence').first();assert.ok(evidence.local_stopped_at);assert.ok(evidence.remote_stopped_at);
 const {DOCLING_JOBS}=await mf.getBindings('private-docling');const state=await DOCLING_JOBS.getByName(saved.job_id).inspect();
 assert.ok(Number.isSafeInteger(state.destroyConfirmedAt));assert.ok(state.destroyConfirmedAt>0);
 assert.equal(state.notAfter,saved.deadline);assert.equal(state.rpcVersion,2);assert.equal(JSON.stringify(state).includes(pdfSha256),false);
 await assert.rejects(()=>db.prepare('UPDATE rag_pdf_jobs SET rpc_not_after=rpc_not_after+1').run());
 await cancelRawPDFIntake(env,session,{documentId:proof.documentId,intakeId:proof.intakeId,generation:proof.generation});
 assert.equal((await db.prepare('SELECT pdf_sha256 FROM rag_pdf_intakes').first()).pdf_sha256,null);
 env.RAG_PDF_RPC_V2_ENABLED=env.RAG_PDF_PROCESSING_ENABLED='false';assert.equal((await cancelRawPDFProcessor(env,saved.job_id)).cancelled,true);
 await assert.rejects(async()=>await DOCLING_PROCESSOR.parse(saved.job_id,bytes));
 await assert.rejects(async()=>await DOCLING_PROCESSOR.parseV2({version:2,jobId:saved.job_id,pdfSha256,notAfter:saved.deadline},bytes));
 console.log(JSON.stringify({localWorkerd:true,d1Migrations:files,serviceBindingRPC:true,sqliteDO:true,mcpPipeline:true,
  immutableEnvelope:true,bothStopProofs:true,intakeErasedStop:true,flagOffStop:true,legacyParseRejected:true,replayRejected:true,
  destroyObservationDurable:true,physicalPurge:false,vm:'synthetic_io_adapter_only',remoteChanges:false}));
}finally{try{await mf.dispose();}finally{rmSync(temp,{recursive:true,force:true});}}
