// Private stage0 review persistence. No transport, key loading, CLI, or stage1 authorization.
import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {isDeepStrictEqual as equal} from 'node:util';
import {replaySubjectRolePairedLedger,subjectRolePairedLedgerManifest} from './subject-role-paired-ledger.mjs';
import {createSubjectRoleReviewPackets,verifySubjectRoleReviewPackets} from './subject-role-review-packets.mjs';
import {prepareSubjectRoleReviewArtifact,verifySubjectRoleReviewArtifact} from './subject-role-review-artifact.mjs';
const hash=x=>createHash('sha256').update(x).digest('hex');
const jsonHash=x=>hash(JSON.stringify(x));
const exact=(o,k)=>o!==null&&typeof o==='object'&&!Array.isArray(o)&&Object.keys(o).length===k.length&&k.every(x=>Object.hasOwn(o,x));
const hex=x=>typeof x==='string'&&/^[a-f0-9]{64}$/.test(x);
const same=(a,b)=>a.dev===b.dev&&a.ino===b.ino;
const fail=()=>{throw Error('subject_role_control_audit_required');};
const LIMIT=2097152,ARTIFACT_LIMIT=8388608;
const names={ledger:'ledger.ndjson',journal:'control.ndjson',collection:'packets-stage-0.json',artifact:'review-stage-0.json',lock:'running.lock'};
function stat(file,directory){const s=fs.lstatSync(file);if(s.isSymbolicLink()||!(directory?s.isDirectory():s.isFile())||s.uid!==process.getuid()||(s.mode&0o777)!==(directory?0o700:0o600)||!directory&&s.nlink!==1)fail();return s;}
function syncDir(dir){const fd=fs.openSync(dir,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);try{fs.fsyncSync(fd);}finally{fs.closeSync(fd);}}
function manifest(rawLedger){
 const state=replaySubjectRolePairedLedger(rawLedger);if(state.audit!=='pending'||state.completedRequests!==2||!state.safeReopenCheckpoint)fail();
 const sourceHashes={};for(const f of ['subject-role-review-control.mjs','subject-role-review-artifact.mjs','subject-role-review-packets.mjs'])sourceHashes[f]=hash(fs.readFileSync(new URL(f,import.meta.url)));
 return {version:1,suiteId:'subject-role-review-control-offline-stage0-v1',transportAttached:false,stage1Authorized:false,
  ledgerHash:hash(rawLedger),ledgerManifest:subjectRolePairedLedgerManifest(),sourceHashes,
  binding:{stage:0,completedRequests:2,checkpointHash:state.checkpointHash,manifestHash:state.manifestHash,runId:state.runId}};
}
function replay(rows,base){
 if(!Array.isArray(rows)||rows.length<1||rows.length>3||!exact(rows[0],['type','manifest','previous'])||rows[0].type!=='manifest'||rows[0].previous!==null||!equal(rows[0].manifest,base))fail();
 let previous=jsonHash(rows[0]),prepared=false,reviewed=false,decision='pending';
 for(const row of rows.slice(1)){
  if(row.previous!==previous||reviewed)fail();
  if(row.type==='packets_ready'){
   if(prepared||!exact(row,['type','collectionHash','mappingHash','previous'])||!hex(row.collectionHash)||!hex(row.mappingHash))fail();prepared=true;
  }else if(row.type==='review'){
   if(!prepared||!exact(row,['type','artifactHash','comparisonDecision','casesHash','previous'])||!hex(row.artifactHash)||!hex(row.casesHash)||!['continue','stop'].includes(row.comparisonDecision))fail();
   reviewed=true;decision=row.comparisonDecision;
  }else fail();previous=jsonHash(row);
 }
 return {prepared,reviewed,comparisonDecision:decision};
}
export function openSubjectRoleReviewControl(options){
 let fd,closed=false,poisoned=false,initialDir,initialLock,base,rows,state,expectedRaw,directory,rawLedger;
 const pinned=new Map();
 try{
  if(arguments.length!==1||!exact(options,['directory','rawLedger']))fail();({directory,rawLedger}=options);
  if(typeof directory!=='string'||!path.isAbsolute(directory)||path.normalize(directory)!==directory||fs.realpathSync(path.dirname(directory))!==path.dirname(directory))fail();
  base=manifest(rawLedger);
  let fresh=false;try{fs.mkdirSync(directory,{mode:0o700});fresh=true;syncDir(path.dirname(directory));}catch(e){if(e?.code!=='EEXIST')throw e;}
  initialDir=stat(directory,true);if(fs.realpathSync(directory)!==directory)fail();
  const file=k=>path.join(directory,names[k]);fs.mkdirSync(file('lock'),{mode:0o700});initialLock=stat(file('lock'),true);syncDir(directory);
  const identity=()=>{if(closed||poisoned||fs.realpathSync(directory)!==directory||!same(initialDir,stat(directory,true))||!same(initialLock,stat(file('lock'),true)))fail();};
  function read(k,max){
   identity();const p=file(k),named=stat(p,false),prior=pinned.get(k);if(prior&&!same(prior,named))fail();let current;
   try{
    current=fs.openSync(p,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);const before=fs.fstatSync(current);
    if(!same(named,before)||before.size>max||before.nlink!==1||!before.isFile()||before.uid!==process.getuid()||(before.mode&0o777)!==0o600)fail();
    const chunks=[];let count=0;for(;;){const b=Buffer.alloc(Math.min(65536,max-count+1)),n=fs.readSync(current,b,0,b.length,count);if(!n)break;count+=n;if(count>max)fail();chunks.push(b.subarray(0,n));}
    const after=fs.fstatSync(current);identity();const afterNamed=stat(p,false);
    if(!same(before,after)||!same(after,afterNamed)||before.size!==after.size||count!==before.size||before.mtimeMs!==after.mtimeMs||before.ctimeMs!==after.ctimeMs||after.nlink!==1||after.mode!==before.mode||after.uid!==before.uid)fail();
    pinned.set(k,after);return new TextDecoder('utf-8',{fatal:true}).decode(Buffer.concat(chunks));
   }finally{if(current!==undefined)fs.closeSync(current);}
  }
  function create(k,raw,max){
   identity();const bytes=Buffer.from(raw);if(bytes.length>max)fail();let current;
   try{current=fs.openSync(file(k),fs.constants.O_CREAT|fs.constants.O_EXCL|fs.constants.O_RDWR|fs.constants.O_NOFOLLOW,0o600);if(fs.writeSync(current,bytes,0,bytes.length,0)!==bytes.length)fail();fs.fsyncSync(current);}finally{if(current!==undefined)fs.closeSync(current);}
   syncDir(directory);if(read(k,max)!==raw)fail();
  }
  const serialize=list=>list.map(JSON.stringify).join('\n')+'\n';
  function artifacts(list){
   const s=replay(list,base),allowed=[names.ledger,names.journal,names.lock];if(s.prepared)allowed.push(names.collection);if(s.reviewed)allowed.push(names.artifact);
   if(!equal(fs.readdirSync(directory).sort(),allowed.sort()))fail();
   const ledger=read('ledger',LIMIT);if(ledger!==rawLedger||hash(ledger)!==base.ledgerHash)fail();
   if(!s.prepared)return {collection:null,artifact:null};
   const collectionRaw=read('collection',LIMIT),ready=list[1];if(hash(collectionRaw)!==ready.collectionHash)fail();
   const collection=verifySubjectRoleReviewPackets(ledger,collectionRaw);if(collection.mappingHash!==ready.mappingHash||!equal(collection.binding,base.binding))fail();
   if(!s.reviewed)return {collection,artifact:null};
   const artifactRaw=read('artifact',ARTIFACT_LIMIT),review=list[2];if(hash(artifactRaw)!==review.artifactHash)fail();
   const artifact=verifySubjectRoleReviewArtifact(ledger,collectionRaw,artifactRaw);
   if(artifact.comparisonDecision!==review.comparisonDecision||jsonHash(artifact.cases)!==review.casesHash)fail();return {collection,artifact};
  }
  function checkJournal(){identity();if(!equal(manifest(rawLedger),base)||read('journal',LIMIT)!==expectedRaw)fail();}
  function audit(){checkJournal();return artifacts(rows);}
  function append(event){
   checkJournal();const row={...structuredClone(event),previous:jsonHash(rows.at(-1))},next=[...rows,row],nextState=replay(next,base);
   artifacts(next);const raw=serialize(next),bytes=Buffer.from(JSON.stringify(row)+'\n');if(Buffer.byteLength(raw)>LIMIT)fail();
   const named=stat(file('journal'),false),held=fs.fstatSync(fd);if(!same(named,held)||!same(held,pinned.get('journal'))||held.size!==Buffer.byteLength(expectedRaw))fail();
   if(fs.writeSync(fd,bytes,0,bytes.length,held.size)!==bytes.length)fail();fs.fsyncSync(fd);if(read('journal',LIMIT)!==raw)fail();
   rows=next;state=nextState;expectedRaw=raw;
  }
  if(fresh){
   create('ledger',rawLedger,LIMIT);rows=[{type:'manifest',manifest:base,previous:null}];expectedRaw=serialize(rows);create('journal',expectedRaw,LIMIT);
  }else{
   expectedRaw=read('journal',LIMIT);if(!expectedRaw.endsWith('\n'))fail();rows=expectedRaw.slice(0,-1).split('\n').map(JSON.parse);if(serialize(rows)!==expectedRaw)fail();
  }
  state=replay(rows,base);artifacts(rows);if(state.comparisonDecision==='stop')fail();
  fd=fs.openSync(file('journal'),fs.constants.O_RDWR|fs.constants.O_NOFOLLOW);if(!same(fs.fstatSync(fd),pinned.get('journal')))fail();
  function view(verified){const a=verified.artifact;return structuredClone({binding:base.binding,manifestHash:jsonHash(base),...state,
   stageReviewsComplete:a?.stageReviewsComplete??false,stageCandidateAllMatched:a?.stageCandidateAllMatched??null,
   stageBaselineMismatchCount:a?.stageBaselineMismatchCount??null,comparablePairs:a?.comparablePairs??0,
   stage1Authorized:false,transportAttached:false,reviewerAuthenticated:false,humanReviewVerified:false,releaseAccepted:false});}
  const guard=fn=>function(...args){try{const checked=audit();return fn(checked,...args);}catch{poisoned=true;fail();}};
  return {
   status:guard(function(checked){if(arguments.length!==1)fail();return view(checked);}),
   preparePackets:guard(function(){if(arguments.length!==1||state.prepared)fail();const c=createSubjectRoleReviewPackets(rawLedger),raw=JSON.stringify(c);create('collection',raw,LIMIT);append({type:'packets_ready',collectionHash:hash(raw),mappingHash:c.mappingHash});return view(artifacts(rows));}),
   exportPackets:guard(function(checked){if(arguments.length!==1||!state.prepared)fail();return checked.collection.packets.map(packet=>({packet:structuredClone(packet),packetHash:checked.collection.mapping.find(m=>m.packetId===packet.packetId).packetHash}));}),
   recordReview:guard(function(checked,rawSubmissionBatch){if(arguments.length!==2||!state.prepared||state.reviewed)fail();const collectionRaw=read('collection',LIMIT),a=prepareSubjectRoleReviewArtifact(rawLedger,collectionRaw,rawSubmissionBatch),raw=JSON.stringify(a);create('artifact',raw,ARTIFACT_LIMIT);append({type:'review',artifactHash:hash(raw),comparisonDecision:a.comparisonDecision,casesHash:jsonHash(a.cases)});return view(artifacts(rows));}),
   close(){
    let release=false;
    try{if(arguments.length)fail();audit();release=state.comparisonDecision!=='stop';const current=fd;fd=undefined;closed=true;fs.closeSync(current);if(release){if(!same(initialDir,stat(directory,true))||!same(initialLock,stat(file('lock'),true)))fail();fs.rmdirSync(file('lock'));syncDir(directory);}}
    catch{poisoned=true;if(fd!==undefined){const current=fd;fd=undefined;closed=true;try{fs.closeSync(current);}catch{}}if(release)try{if(same(initialDir,stat(directory,true))&&!fs.existsSync(file('lock'))){fs.mkdirSync(file('lock'),{mode:0o700});syncDir(directory);}}catch{}fail();}
   },
  };
 }catch{if(fd!==undefined)try{fs.closeSync(fd);}catch{}fail();}
}
