// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
// Manual local-only workerd/D1 smoke. Synthetic metadata; no remote bindings.
import {Miniflare,convertV4MiniflareOptions} from './rag-local-runtime.ts';
import {unstable_splitSqlQuery} from 'wrangler';
import {readFileSync,readdirSync,mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import assert from 'node:assert/strict';
import {minimizeExpiredRawPDFIntakes,rawPDFRetentionStatus} from '../src/rag/pdf-retention.ts';
const temp=mkdtempSync(join(tmpdir(),'studiquo-retention-smoke-'));
const mf=new Miniflare(convertV4MiniflareOptions({host:'127.0.0.1',cf:false,workers:[{name:'step5a',modules:true,script:"export default {fetch(){return new Response('ok')}}",compatibilityDate:'2026-08-27',d1Databases:['ADMIN_DB']}],persist:temp}));
try{
 const db=await mf.getD1Database('ADMIN_DB');
 const dir=new URL('../migrations/',import.meta.url);let files=0;
 for(const name of readdirSync(dir).filter(n=>/^00(?:0[1-9]|1[0-4])_.*\.sql$/u.test(n)).sort()){
  for(const sql of unstable_splitSqlQuery(readFileSync(new URL(name,dir),'utf8') as any))await db.prepare(sql).run();files++;
 }
 const intake=crypto.randomUUID();
 await db.prepare("INSERT INTO rag_pdf_intakes VALUES('synthetic-owner','synthetic-document',?,'synthetic-request',1,1,1,'pending',?,100,1000)").bind(intake,'a'.repeat(64)).run();
 const job=crypto.randomUUID();
 await db.prepare("INSERT INTO rag_pdf_jobs(job_id,account_key,document_id,intake_id,generation,consent_epoch,raw_consent_epoch,state,window_start,reserved_units,memory_weight,policy_version,deadline,created_at) VALUES(?,'synthetic-owner','synthetic-document',?,1,1,1,'reserved',0,3,67108864,'synthetic',1000,0)").bind(job,intake).run();
 const env={ADMIN_DB:db,RAG_PDF_RETENTION_ENABLED:'true'};
 assert.deepEqual(await minimizeExpiredRawPDFIntakes(env,{clock:()=>1000}),{minimized:1});
 assert.equal((await db.prepare('SELECT state FROM rag_pdf_jobs').first()).state,'stop_requested');
 const before=Date.now();
 await db.prepare("UPDATE rag_pdf_jobs SET state='settled',settled_units=0,settled_at=MAX(?,CAST(strftime('%s','now') AS INTEGER)*1000+1000) WHERE job_id=? AND state='stop_requested'").bind(1000,job).run();
 assert.ok((await db.prepare('SELECT settled_at FROM rag_pdf_jobs').first()).settled_at>=before);
 assert.deepEqual(await rawPDFRetentionStatus(env,{clock:()=>1000}),{expiredIntakes:0,oldestExpiredMs:0,heldJobs:0,settledWithoutTime:0,settledWithTime:1,physicalPurgeEnabled:false});
 await db.prepare('UPDATE rag_pdf_retention_control SET min_admission_window=86400000').run();
 await assert.rejects(()=>db.prepare("INSERT OR REPLACE INTO rag_pdf_retention_control(singleton,policy_version) VALUES(1,'raw-pdf-retention-v1')").run());
 assert.equal((await db.prepare('SELECT min_admission_window AS n FROM rag_pdf_retention_control').first()).n,86400000);
 console.log(JSON.stringify({localWorkerd:true,migrations:files,expiredIntakeMinimized:true,jobRetained:true,dbSettlementTime:true,aggregateOnly:true,replaceFloorRejected:true,remoteChanges:false}));
}finally{try{await mf.dispose();}finally{rmSync(temp,{recursive:true,force:true});}}
