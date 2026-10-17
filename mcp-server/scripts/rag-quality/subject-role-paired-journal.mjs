// Private offline persistence around the stage0-only ledger. Never use for paid dispatch.
import fs from 'node:fs';
import path from 'node:path';
import {createHash,randomUUID} from 'node:crypto';
import {isDeepStrictEqual as equal} from 'node:util';
import {subjectRolePairedLedgerManifest,replaySubjectRolePairedLedger} from './subject-role-paired-ledger.mjs';
const hash=x=>createHash('sha256').update(x).digest('hex');
const jsonHash=x=>hash(JSON.stringify(x));
const fail=()=>{throw Error('subject_role_journal_audit_required');};
const same=(a,b)=>a.dev===b.dev&&a.ino===b.ino;
const limit=2097152;
function safeStat(file,directory){
 const s=fs.lstatSync(file);
 if(s.isSymbolicLink()||!(directory?s.isDirectory():s.isFile())||s.uid!==process.getuid()||
  (s.mode&0o777)!==(directory?0o700:0o600)||!directory&&s.nlink!==1)fail();
 return s;
}
function syncDir(directory){const fd=fs.openSync(directory,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);try{fs.fsyncSync(fd);}finally{fs.closeSync(fd);}}
export function subjectRolePairedJournalManifest(){
 if(arguments.length)fail();
 try{return {version:1,suiteId:'subject-role-paired-journal-offline-stage0-v1',transportAttached:false,
  persistenceAttached:true,reviewGateAttached:false,maxExecutableStage:0,journalBytes:limit,
  sourceHash:hash(fs.readFileSync(new URL('subject-role-paired-journal.mjs',import.meta.url))),ledger:subjectRolePairedLedgerManifest()};}catch{fail();}
}
export function openSubjectRolePairedJournal(directory){
 let fd,closed=false,poisoned=false,initialDir,initialLock,base,expectedRaw,header,records,state;
 const lock=typeof directory==='string'?path.join(directory,'running.lock'):null;
 try{
  if(arguments.length!==1||typeof directory!=='string'||!path.isAbsolute(directory)||path.normalize(directory)!==directory||
   fs.realpathSync(path.dirname(directory))!==path.dirname(directory))fail();
  base=subjectRolePairedJournalManifest();
  let fresh=false;try{fs.mkdirSync(directory,{mode:0o700});fresh=true;syncDir(path.dirname(directory));}catch(e){if(e?.code!=='EEXIST')throw e;}
  initialDir=safeStat(directory,true);if(fs.realpathSync(directory)!==directory)fail();
  fs.mkdirSync(lock,{mode:0o700});initialLock=safeStat(lock,true);syncDir(directory);
  const file=path.join(directory,'journal.ndjson');
  if(fresh){fd=fs.openSync(file,fs.constants.O_CREAT|fs.constants.O_EXCL|fs.constants.O_RDWR|fs.constants.O_NOFOLLOW,0o600);}
  else{safeStat(file,false);fd=fs.openSync(file,fs.constants.O_RDWR|fs.constants.O_NOFOLLOW);}
  const identity=()=>{
   if(closed||poisoned||fs.realpathSync(directory)!==directory||!same(initialDir,safeStat(directory,true))||!same(initialLock,safeStat(lock,true)))fail();
   if(!equal(fs.readdirSync(directory).sort(),['journal.ndjson','running.lock']))fail();
   const named=safeStat(file,false),s=fs.fstatSync(fd);
   if(!same(named,s)||!s.isFile()||s.uid!==process.getuid()||(s.mode&0o777)!==0o600||s.nlink!==1||s.size>limit)fail();
   return s;
  };
  const read=()=>{
   const before=identity(),chunks=[];let count=0;
   for(;;){const b=Buffer.alloc(Math.min(65536,limit-count+1)),n=fs.readSync(fd,b,0,b.length,count);if(!n)break;count+=n;if(count>limit)fail();chunks.push(b.subarray(0,n));}
   const after=identity();
   if(!same(before,after)||before.size!==after.size||count!==before.size||before.mtimeMs!==after.mtimeMs||before.ctimeMs!==after.ctimeMs)fail();
   return new TextDecoder('utf-8',{fatal:true}).decode(Buffer.concat(chunks));
  };
  const ledgerRaw=list=>list.map(r=>JSON.stringify(r)).join('\n')+'\n';
  const allRaw=list=>JSON.stringify(header)+'\n'+ledgerRaw(list);
  if(fresh){
   const runId=randomUUID();header={type:'persistence_manifest',manifest:base,runId};
   records=[{type:'manifest',manifest:base.ledger,runId,previous:null}];state=replaySubjectRolePairedLedger(ledgerRaw(records));
   const raw=allRaw(records),bytes=Buffer.from(raw);if(bytes.length>limit)fail();identity();
   if(fs.writeSync(fd,bytes,0,bytes.length,0)!==bytes.length)fail();fs.fsyncSync(fd);syncDir(directory);
   expectedRaw=raw;if(read()!==expectedRaw)fail();
  }else{
   expectedRaw=read();if(!expectedRaw.endsWith('\n'))fail();const lines=expectedRaw.slice(0,-1).split('\n');
   header=JSON.parse(lines.shift());
   if(!header||Object.keys(header).length!==3||header.type!=='persistence_manifest'||!equal(header.manifest,base))fail();
   records=lines.map(s=>JSON.parse(s));state=replaySubjectRolePairedLedger(ledgerRaw(records));
   if(header.runId!==state.runId||!state.safeReopenCheckpoint||allRaw(records)!==expectedRaw)fail();
  }
  const audit=()=>{if(!equal(subjectRolePairedJournalManifest(),base)||read()!==expectedRaw)fail();};
  const append=event=>{
   const copy=structuredClone(event);if(!equal(JSON.parse(JSON.stringify(copy)),copy))fail();
   const row={...copy,previous:jsonHash(records.at(-1))},next=[...records,row],checked=replaySubjectRolePairedLedger(ledgerRaw(next));
   const raw=allRaw(next),bytes=Buffer.from(JSON.stringify(row)+'\n'),offset=Buffer.byteLength(expectedRaw);
   if(Buffer.byteLength(raw)>limit)fail();
   // Validate the whole existing file immediately before append; fsync must finish before exposing success.
   audit();if(fs.writeSync(fd,bytes,0,bytes.length,offset)!==bytes.length)fail();fs.fsyncSync(fd);
   if(read()!==raw)fail();records=next;state=checked;expectedRaw=raw;
  };
  const view=()=>structuredClone({...state,journalManifestHash:jsonHash(base),transportAttached:false,persistenceAttached:true,reviewGateAttached:false});
  const guard=fn=>function(...args){try{audit();return fn(...args);}catch{poisoned=true;fail();}};
  return {
   status:guard(function(){if(arguments.length)fail();return view();}),
   reserveNext:guard(function(){if(arguments.length||!state.nextJob)fail();const job=structuredClone(state.nextJob);append({type:'reserved',job,reservedMicroUSD:8192});return job;}),
   complete:guard(function(result,elapsedMs){if(arguments.length!==2||state.pending===null)fail();append({type:'completed',ordinal:state.pending,result,elapsedMs});return view();}),
   finishStage:guard(function(){if(arguments.length)fail();append({type:'stage_finished',stage:0,completedRequests:state.completedRequests,completedPairs:state.technicalCompletedPairs});return view();}),
   markFailed:guard(function(failure){if(arguments.length!==1||!failure||Object.keys(failure).length!==3||!['phase','httpStatus','reason'].every(k=>Object.hasOwn(failure,k)))fail();append({type:'failed',ordinal:state.pending,...failure});return view();}),
   close(){
    let release=false;
    try{
     if(arguments.length)fail();audit();release=state.safeReopenCheckpoint;
     const current=fd;fd=undefined;closed=true;fs.closeSync(current);
     if(release){if(!same(initialDir,safeStat(directory,true))||!same(initialLock,safeStat(lock,true)))fail();fs.rmdirSync(lock);syncDir(directory);}
    }catch{
     poisoned=true;if(fd!==undefined){const current=fd;fd=undefined;closed=true;try{fs.closeSync(current);}catch{}}
     // If lock removal succeeded but directory sync failed, restore a stop marker when the directory is still ours.
     if(release)try{if(same(initialDir,safeStat(directory,true))&&!fs.existsSync(lock)){fs.mkdirSync(lock,{mode:0o700});syncDir(directory);}}catch{}
     fail();
    }
   },
  };
 }catch{if(fd!==undefined)try{fs.closeSync(fd);}catch{}fail();}
}
