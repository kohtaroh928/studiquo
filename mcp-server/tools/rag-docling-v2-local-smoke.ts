// @ts-nocheck -- historical JS regression fixture; runtime assertions preserved during TS port.
import {stripTypeScriptTypes} from 'node:module';
// Actual local workerd/SQLite DO storage + RPC; VM destruction is a synthetic
// adapter. No container start, PDF parse, remote binding, or physical purge.
import {Miniflare,convertV4MiniflareOptions} from './rag-local-runtime.ts';
import {readFileSync,mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import assert from 'node:assert/strict';
const source=stripTypeScriptTypes(readFileSync(new URL('../../services/docling-worker/index.ts',import.meta.url),'utf8')).replace('export default DoclingProcessor;','');
const probe=`
export class BoundaryProbe extends DoclingJob {
 async cleanup(){this.syntheticDestroys=(this.syntheticDestroys??0)+1;await this.ctx.storage.deleteAlarm();return true;}
 async inspect(){return {state:(await this.ctx.storage.get('job'))??null,destroys:this.syntheticDestroys??0};}
}
export default {async fetch(request,env){
 const denied=async f=>{try{await f();return false;}catch{return true;}};
 const jobId='12345678-1234-4123-8123-123456789abc',notAfter=Date.now()+60000;
 const c={version:2,jobId,notAfter},job=env.JOBS.getByName(jobId);
 const stopped=await job.cancelV2(c),saved=await job.inspect();
 const changed=await denied(()=>job.cancelV2({...c,notAfter:notAfter+1}));
 const legacy=await denied(()=>job.cancel(jobId));
 const bytes=new TextEncoder().encode('%PDF-synthetic');
 const digest=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
 const replay=await denied(()=>job.parseV2({...c,pdfSha256:digest},bytes));
 const other='12345678-1234-4123-8123-123456789abd',empty=env.JOBS.getByName(other);
 await empty.cancelV2({version:2,jobId:other,notAfter:Date.now()-1000});const after=await empty.inspect();
 return Response.json({localWorkerd:true,sqliteDO:true,actualRPC:true,fixedDeadline:saved.state.notAfter===notAfter,
  cancelConfirmed:stopped.cancelled===true,changedDeadlineRejected:changed,legacyRejected:legacy,replayRejected:replay,
  expiredEmptyNoMarker:after.state===null,expiredEmptyDestroyAdapter:after.destroys===1,
  vm:'synthetic_destroy_adapter_only',remoteChanges:false});
}};`;
const temp=mkdtempSync(join(tmpdir(),'studiquo-v2-boundary-smoke-'));
const mf=new Miniflare(convertV4MiniflareOptions({host:'127.0.0.1',cf:false,d1Persist:join(temp,'d1'),durableObjectsPersist:join(temp,'do'),workers:[{
 name:'step5d1',modules:true,script:source+probe,compatibilityDate:'2026-08-27',
 bindings:{DOCLING_RPC_V2_ONLY:'true',DOCLING_EXECUTION_ENABLED:'true'},
 durableObjects:{JOBS:{className:'BoundaryProbe',useSQLite:true}}
}]}));
try{
 const response=await mf.dispatchFetch('http://localhost/');assert.equal(response.status,200);
 const result=await response.json();for(const [key,value]of Object.entries(result))if(typeof value==='boolean')assert.equal(value,key!=='remoteChanges',key);
 console.log(JSON.stringify(result));
}finally{try{await mf.dispose();}finally{rmSync(temp,{recursive:true,force:true});}}
