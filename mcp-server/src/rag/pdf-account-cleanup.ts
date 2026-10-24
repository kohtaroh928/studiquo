import {accountKey} from './storage.ts';
import {recoverAccountRawPDFJobs} from './pdf-job-recovery.ts';
const stmt=(db: any,sql: any,...args: any[])=>db.prepare(sql).bind(...args);
const pending=()=>Object.freeze({version:1,tracked:true,pending:true});
// Deletion-only, after the account denial fence is persisted. No text, IDs or
// raw exceptions are returned. A timeout observes work, never proves stopping.
export async function cleanupAccountRawPDF(env: any,sub: any,{requireSchema=false,establishFence=false,timeoutMs=10000,limit=10,isCurrent}: any={}): Promise<any> {
 let end: any,expired=false;
 try{
  if((isCurrent!==undefined&&typeof isCurrent!=='function')||typeof requireSchema!=='boolean'||typeof establishFence!=='boolean'||!Number.isSafeInteger(timeoutMs)||timeoutMs<1||timeoutMs>10000||
   !Number.isSafeInteger(limit)||limit<1||limit>10)throw Error('invalid');
  end=performance.now()+timeoutMs;
  const within=async (work: any): Promise<any> =>{
   const left=end-performance.now();if(expired||left<=0)throw Error('timeout');let timer: any;
   try{return await Promise.race([Promise.resolve().then(async()=>{if(isCurrent&&!await isCurrent())throw Error('ownership_lost');if(expired||performance.now()>=end)throw Error('timeout');const result=await work();if(isCurrent&&!await isCurrent())throw Error('ownership_lost');if(expired||performance.now()>=end)throw Error('timeout');return result;}),new Promise((_: any,reject: any)=>{timer=setTimeout(()=>{expired=true;reject(Error('timeout'));},left);})]);}
   finally{clearTimeout(timer);}
  };
  const db=env.ADMIN_DB;
  if(!db){
   if(requireSchema||env.RAG_ENABLED==='true'||env.RAG_PDF_PROCESSING_ENABLED==='true')return pending();
   return Object.freeze({version:1,tracked:false,pending:false});
  }
  const tables=await within(()=>stmt(db,`SELECT name FROM sqlite_master WHERE type='table' AND name IN
   ('rag_raw_pdf_consents','rag_pdf_intakes','rag_pdf_jobs','rag_pdf_job_recovery')`).all());
  if(tables.results.length===0&&!requireSchema)return Object.freeze({version:1,tracked:false,pending:false});
  if(tables.results.length!==4)return pending();
  const key=await within(()=>accountKey(sub));
  // Only a durable already-deleted/independent-complete checkpoint may ask to
  // establish the missing denial row for legacy accounts that never used RAG.
  if(establishFence)await within(()=>stmt(db,`INSERT INTO rag_accounts(account_key,deleted) VALUES(?,1)
   ON CONFLICT(account_key) DO UPDATE SET deleted=1`,key).run());
  const fence=await within(()=>stmt(db,'SELECT 1 AS ok FROM rag_accounts WHERE account_key=? AND deleted=1',key).first());
  if(!fence)return pending();
  // Invalidation is independent of every admission/retrieval flag. Keep the
  // consent/intake tombstones and all job/accounting/evidence metadata.
  await within(()=>stmt(db,`UPDATE rag_raw_pdf_consents SET enabled=0,rag_consent_epoch=NULL,consent_version=NULL,
   epoch=CASE WHEN epoch<9007199254740991 THEN epoch+1 ELSE epoch END WHERE account_key=? AND enabled!=0`,key).run());
  await within(()=>stmt(db,`UPDATE rag_pdf_intakes SET state='cancelled',pdf_sha256=NULL,byte_length=NULL,request_id=''
   WHERE account_key=? AND intake_id IN (SELECT intake_id FROM rag_pdf_intakes
    WHERE account_key=? AND (state!='cancelled' OR pdf_sha256 IS NOT NULL OR byte_length IS NOT NULL OR request_id!='')
    ORDER BY expires_at,intake_id LIMIT ?)`,key,key,limit).run());
  const currentPass = async () => {
   if(expired||performance.now()>=end)return false;
   const owns=isCurrent?await isCurrent():true;
   return owns&&!expired&&performance.now()<end;
  };
  await within(()=>{
   const left=Math.floor(end-performance.now());if(left<1)throw Error('timeout');
   return recoverAccountRawPDFJobs(env,key,{limit,timeoutMs:Math.min(2000,left),passMs:Math.min(10000,left),isCurrent:currentPass});
  });
  const remaining=await within(()=>stmt(db,`SELECT
   (EXISTS(SELECT 1 FROM rag_pdf_jobs j LEFT JOIN rag_pdf_job_recovery r USING(job_id)
    WHERE j.account_key=? AND (j.state!='settled' OR (r.job_id IS NOT NULL AND (r.state!='done' OR r.lease_id IS NOT NULL OR r.lease_until!=0))))
    OR EXISTS(SELECT 1 FROM rag_pdf_intakes WHERE account_key=? AND
     (state!='cancelled' OR pdf_sha256 IS NOT NULL OR byte_length IS NOT NULL OR request_id!=''))
    OR EXISTS(SELECT 1 FROM rag_raw_pdf_consents WHERE account_key=? AND enabled!=0)) AS pending`,key,key,key).first());
  if(!remaining||![0,1].includes(remaining.pending))return pending();
  return Object.freeze({version:1,tracked:true,pending:remaining.pending===1});
 }catch{return pending();}
}
