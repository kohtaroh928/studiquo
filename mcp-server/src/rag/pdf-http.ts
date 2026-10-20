import {json} from '../http.ts';
import {accountKey} from './storage.ts';
import {aiPrivacyHeadersRejection} from '../ai-privacy.ts';
import {readRawPDFConsent,updateRawPDFConsent} from './pdf-authorization.ts';
import {prepareLimitedRawPDFIntake,requireRawPDFIntakeAuthorization,cancelRawPDFIntake} from './pdf-intake.ts';
import {rawPDFPreflightRejection,RAW_PDF_CONSENT_VERSION} from './pdf-preflight.ts';
import {streamRawPDFResponse} from './pdf-response.ts';
const UUID='[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const route=new RegExp(`^/api/rag/pdf/intakes/(${UUID})/(process|cancel)$`);
const fail=()=>{throw Error('pdf_request_unavailable');};
const object=(v: any)=>v&&typeof v==='object'&&!Array.isArray(v);
const flags=(env: any)=>['AI_PROVIDER_APPROVED','RAG_ENABLED','RAG_AUTO_INDEX_ENABLED','RAG_PDF_PROCESSING_ENABLED'].every(k=>env[k]==='true');
function config(raw: any,keys: any){
 if(typeof raw!=='string'||raw.length>4096)fail();let p: any;try{p=JSON.parse(raw);}catch{fail();}
 if(!object(p)||Object.keys(p).length!==keys.length||keys.some((k: any)=>!Number.isSafeInteger(p[k])||p[k]<1||p[k]>1000000000))fail();return Object.freeze(p);
}
function executionConfig(env: any){
 if(!flags(env)||typeof env.DOCLING_PROCESSOR?.parse!=='function'||typeof env.DOCLING_PROCESSOR?.cancel!=='function')fail();
 const policy=config(env.RAG_PDF_ADMISSION_POLICY,['perOwnerActive','globalActive','globalMemoryBytes','perOwnerDailyUnits','globalDailyUnits','reservationUnits','perOwnerDailyRequests','globalDailyRequests']);
 if(policy.perOwnerActive>policy.globalActive||policy.globalActive>16||policy.globalMemoryBytes<67108864||policy.globalMemoryBytes>100663296||policy.reservationUnits>policy.perOwnerDailyUnits||policy.reservationUnits>policy.globalDailyUnits||policy.perOwnerDailyRequests>10000||policy.globalDailyRequests>100000)fail();
 const limits=config(env.RAG_PDF_INTAKE_LIMITS,['ownerRows','globalRows','ownerPending','globalPending']);
 if(Object.values(limits).some((v: any)=>v>1000000)||limits.ownerRows>limits.globalRows||limits.ownerPending>limits.ownerRows||limits.globalPending>limits.globalRows||limits.ownerPending>limits.globalPending)fail();
 return {policy,limits};
}
async function schema(env: any){
 const row=await env.ADMIN_DB.prepare(`SELECT COUNT(*) AS n FROM sqlite_master WHERE
  (type='table' AND name IN ('rag_raw_pdf_consents','rag_pdf_intakes','rag_pdf_jobs','rag_pdf_job_recovery')) OR
  (type='trigger' AND name IN ('rag_raw_pdf_control_changed','rag_raw_pdf_control_deleted','rag_raw_pdf_account_deleted',
   'rag_pdf_intakes_raw_changed','rag_pdf_intakes_raw_deleted','rag_pdf_intakes_document_inserted','rag_pdf_intakes_document_changed',
   'rag_pdf_intakes_document_deleted','rag_pdf_intakes_account_removed','rag_pdf_jobs_intake_changed','rag_pdf_jobs_intake_deleted'))`).bind().first();
 if(row?.n!==15)fail();
}
async function payload(request: any){
 if(request.headers.get('content-type')?.split(';')[0].trim()!=='application/json')fail();
 const reader=request.body?.getReader();if(!reader)fail();let timer: any,onAbort: any,complete=false;
 try{
  const interrupt=new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('pdf_request_invalid')),5000);onAbort=()=>reject(Error('pdf_request_invalid'));request.signal?.addEventListener('abort',onAbort,{once:true});if(request.signal?.aborted)onAbort();});
  const decoder=new TextDecoder('utf-8',{fatal:true} as any);let text='',bytes=0,reads=0;
  for(;;){const part=await Promise.race([reader.read(),interrupt]);if(++reads>1024)fail();if(part.done){complete=true;break;}bytes+=part.value.byteLength;if(bytes>8192)fail();text+=decoder.decode(part.value,{stream:true});}
  const value=JSON.parse(text+decoder.decode());if(!object(value))fail();return value;
 }finally{clearTimeout(timer);request.signal?.removeEventListener('abort',onAbort);if(!complete)reader.cancel().catch(()=>{});try{reader.releaseLock();}catch{}}
}
function headersRejection(request: any,env: any){
 const denied=aiPrivacyHeadersRejection(request.headers,env);if(denied)return denied;
 if(request.headers.get('X-Studiquo-RAG-Consent')!=='rag-openai-v1'||request.headers.get('X-Studiquo-Raw-PDF-Consent')!==RAW_PDF_CONSENT_VERSION)return json({error:'raw_pdf_consent_required'},403);
 return null;
}
async function lookup(env: any,key: any,intakeId: any){
 const row=await env.ADMIN_DB.prepare(`SELECT document_id,intake_id,generation,consent_epoch,raw_consent_epoch,pdf_sha256,byte_length,expires_at
 FROM rag_pdf_intakes WHERE account_key=? AND intake_id=?`).bind(key,intakeId).first();
 if(!row)fail();return {documentId:row.document_id,intakeId:row.intake_id,generation:row.generation,consentEpoch:row.consent_epoch,
 rawPDFConsentEpoch:row.raw_consent_epoch,pdfSha256:row.pdf_sha256,byteLength:row.byte_length,expiresAt:row.expires_at};
}
// Caller must supply realSession()'s canonical session. No body-derived identity.
export async function handleRawPDFHTTP(url: any,request: any,env: any,session: any,{processOptions,transferMs}: any={}){
 if(!url.pathname.startsWith('/api/rag/pdf/'))return null;
 if(typeof session?.sub!=='string'||!session.sub.length||session.sub.length>512)return json({error:'unauthorized'},401);
 try{
  const key=await accountKey(session.sub);
  if(typeof env.RATE_LIMIT_RAG_PDF?.limit!=='function')return json({error:'pdf_rate_limit_unavailable'},503);
  if((await env.RATE_LIMIT_RAG_PDF.limit({key})).success!==true)return json({error:'rate_limited'},429);
  const match=url.pathname.match(route),consent=url.pathname==='/api/rag/pdf/consent',intakes=url.pathname==='/api/rag/pdf/intakes';
  if(url.search||(!consent&&!intakes&&!match))return json({error:'not_found'},404);
  if((consent&&!['GET','POST'].includes(request.method))||(!consent&&request.method!=='POST'))return json({error:'not_found'},404);
  if(consent){
   await schema(env);
   if(request.method==='GET')return json(await readRawPDFConsent(env,session));
   const p=await payload(request);
   if(p.enabled===true){executionConfig(env);const denied=headersRejection(request,env);if(denied)return denied;}
   return json(await updateRawPDFConsent(env,session,p));
  }
  if(match?.[2]==='cancel'){
   await schema(env);const p=await payload(request);
   if(Object.keys(p).join(',')!=='generation'||!Number.isSafeInteger(p.generation)||p.generation<1)return json({error:'invalid_pdf_cancel'},400);
   const proof=await lookup(env,key,match[1]);if(p.generation!==proof.generation)fail();
   return json(await cancelRawPDFIntake(env,session,{documentId:proof.documentId,intakeId:proof.intakeId,generation:proof.generation}));
  }
  // Flags, immutable server policy, bindings, schemas and owner proof precede any
  // access to the raw Request body. Privacy checks here inspect headers only.
  const {policy,limits}=executionConfig(env);await schema(env);
  const denied=headersRejection(request,env);if(denied)return denied;
  if(intakes)return json(await prepareLimitedRawPDFIntake(env,session,await payload(request),limits));
  const preflight=rawPDFPreflightRejection(request.headers,env);if(preflight)return preflight;
  const proof=await lookup(env,key,match[1]);await requireRawPDFIntakeAuthorization(env,session,proof);
  return streamRawPDFResponse(env,session,proof,request,policy,{processOptions,transferMs});
 }catch{return json({error:'pdf_request_unavailable'},503);}
}
