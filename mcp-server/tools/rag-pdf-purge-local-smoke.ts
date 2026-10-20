// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
// Manual synthetic workerd/D1 test. No remote bindings or persisted user data.
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {unstable_splitSqlQuery} from 'wrangler';
import {readFileSync,readdirSync,mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import assert from 'node:assert/strict';
import {purgeSettledRawPDFJobs} from '../src/rag/pdf-purge.ts';
const temp=mkdtempSync(join(tmpdir(),'studiquo-purge-smoke-'));
const mf=new Miniflare(convertV4MiniflareOptions({host:'127.0.0.1',cf:false,persist:temp,
 workers:[{name:'step5b',modules:true,script:"export default {fetch(){return new Response('ok')}}",
  compatibilityDate:'2026-08-27',d1Databases:['ADMIN_DB']}]}));
try{
 const db=await mf.getD1Database('ADMIN_DB'),dir=new URL('../migrations/',import.meta.url);let files=0;
 for(const name of readdirSync(dir).filter(n=>/^00(?:0[1-9]|1[0-5])_.*\.sql$/u.test(n)).sort()){
  for(const sql of unstable_splitSqlQuery(readFileSync(new URL(name,dir),'utf8') as any))await db.prepare(sql).run();files++;
 }
 const DAY=86400000,n=Date.now(),today=Math.floor(n/DAY)*DAY;
 const seed=async (window: any)=>{
  const job=crypto.randomUUID(),intake=crypto.randomUUID(),doc=crypto.randomUUID();
  await db.prepare("INSERT INTO rag_pdf_intakes VALUES('synthetic-owner',?,?, '',1,1,1,'cancelled',NULL,NULL,?)").bind(doc,intake,window+1000).run();
  await db.prepare(`INSERT INTO rag_pdf_jobs(job_id,account_key,document_id,intake_id,generation,consent_epoch,raw_consent_epoch,
   state,window_start,reserved_units,settled_units,memory_weight,policy_version,deadline,created_at,settled_at,writer_version)
   VALUES(?,'synthetic-owner',?,?,1,1,1,'settled',?,3,0,67108864,'synthetic',?,?,?,'floor-v2')`)
   .bind(job,doc,intake,window,window+1000,window,n-2*DAY-10000).run();
  await db.prepare("INSERT INTO rag_pdf_job_recovery(job_id,state) VALUES(?,'done')").bind(job).run();return job;
 };
 const floor=async()=>(await db.prepare('SELECT min_admission_window AS n FROM rag_pdf_retention_control').first()).n;
 const env={ADMIN_DB:db,RAG_PDF_RETENTION_ENABLED:'true',RAG_PDF_JOB_PURGE_ENABLED:'true'};
 await assert.rejects(()=>purgeSettledRawPDFJobs(env),/pdf_purge_disabled/u);
 const job=await seed(today-4*DAY);await seed(today-4*DAY);await seed(today-4*DAY);await db.prepare('UPDATE rag_pdf_purge_control SET enabled=1').run();
 const concurrent=await Promise.all([purgeSettledRawPDFJobs(env),purgeSettledRawPDFJobs(env)]);
 assert.equal(concurrent.reduce((sum,r)=>sum+r.purged,0),3);
 assert.equal(await db.prepare('SELECT 1 FROM rag_pdf_jobs WHERE job_id=?').bind(job).first(),null);
 assert.equal(await db.prepare('SELECT 1 FROM rag_pdf_job_recovery WHERE job_id=?').bind(job).first(),null);
 const savedFloor=await floor();assert.equal(savedFloor,today-3*DAY);
 const failed=await seed(today-3*DAY);
 await db.prepare("CREATE TRIGGER synthetic_parent_failure AFTER DELETE ON rag_pdf_jobs BEGIN SELECT RAISE(ABORT,'synthetic-failure'); END").run();
 await assert.rejects(()=>purgeSettledRawPDFJobs(env),/pdf_purge_unavailable/u);
 assert.ok(await db.prepare('SELECT 1 FROM rag_pdf_jobs WHERE job_id=?').bind(failed).first());
 assert.ok(await db.prepare('SELECT 1 FROM rag_pdf_job_recovery WHERE job_id=?').bind(failed).first());
 assert.equal(await floor(),savedFloor);
 assert.equal((await db.prepare('SELECT lease_id FROM rag_pdf_purge_control').first()).lease_id,null);
 await db.prepare('DROP TRIGGER synthetic_parent_failure').run();
 await db.prepare('CREATE TABLE synthetic_receipts(id TEXT)').run();
 await assert.rejects(()=>purgeSettledRawPDFJobs(env),/pdf_purge_unavailable/u);
 assert.ok(await db.prepare('SELECT 1 FROM rag_pdf_jobs WHERE job_id=?').bind(failed).first());
 console.log(JSON.stringify({localWorkerd:true,migrations:files,purgeAtomic:true,floorAdvanced:true,
  rollbackChildParentFloor:true,concurrentPasses:true,unknownReceiptDenied:true,remoteChanges:false}));
}finally{try{await mf.dispose();}finally{rmSync(temp,{recursive:true,force:true});}}
