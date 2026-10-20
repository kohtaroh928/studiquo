// Trusted service binding only. Never accept a protocol, deadline or stop ack
// from HTTP. Cancellation must survive intake minimization and flag rollback.
const validId=v=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(v);
const deadline=v=>Number.isSafeInteger(v)&&v>0&&v<=Number.MAX_SAFE_INTEGER-180000;
const fail=()=>{throw Error('pdf_rpc_unavailable');};
export function rawPDFProcessorAvailable(env,v2=false){
 const p=env.DOCLING_PROCESSOR;
 return typeof p?.[v2?'parseV2':'parse']==='function'&&typeof p?.[v2?'cancelV2':'cancel']==='function';
}
export function rawPDFStopAvailable(env){
 const p=env.DOCLING_PROCESSOR;return typeof p?.cancelV2==='function'||typeof p?.cancel==='function';
}
export async function parseRawPDFV2(env,contract,bytes){
 if(!contract||Object.keys(contract).length!==4||contract.version!==2||!validId(contract.jobId)||!deadline(contract.notAfter)||
  typeof contract.pdfSha256!=='string'||!/^[0-9a-f]{64}$/u.test(contract.pdfSha256)||typeof env.DOCLING_PROCESSOR?.parseV2!=='function')fail();
 return env.DOCLING_PROCESSOR.parseV2(Object.freeze({...contract}),bytes);
}
export async function cancelRawPDFProcessor(env,jobId,{v2=false}={}){
 if(!validId(jobId)||typeof v2!=='boolean')fail();
 // SELECT * also works on the old schema. No intake lookup or renewed TTL.
 const row=await env.ADMIN_DB.prepare('SELECT * FROM rag_pdf_jobs WHERE job_id=?').bind(jobId).first();
 if(!row||row.job_id!==jobId)fail();
 const version=row.rpc_version??1;
 if(![1,2].includes(version))fail();
 const useV2=version===2||v2||env.RAG_PDF_RPC_V2_ENABLED==='true';
 if(version===2&&(!deadline(row.rpc_not_after)||row.rpc_not_after!==row.deadline||
  typeof row.rpc_pdf_sha256!=='string'||!/^[0-9a-f]{64}$/u.test(row.rpc_pdf_sha256)))fail();
 if(useV2){
  const notAfter=version===2?row.rpc_not_after:row.deadline;
  if(!deadline(notAfter)||typeof env.DOCLING_PROCESSOR?.cancelV2!=='function')fail();
  // Legacy draining uses its original deadline, never invents a parse digest,
  // and never upgrades the DB row. Failed v2 calls have no legacy fallback.
  return env.DOCLING_PROCESSOR.cancelV2(Object.freeze({version:2,jobId,notAfter}));
 }
 if(typeof env.DOCLING_PROCESSOR?.cancel!=='function')fail();
 return env.DOCLING_PROCESSOR.cancel(jobId);
}
