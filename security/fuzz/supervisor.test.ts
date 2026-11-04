import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,rm,readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath,URL} from 'node:url';
import {runCampaign,saveReport} from './supervisor.ts';
import {spawn} from 'node:child_process';
const script=fileURLToPath(new URL('./fixtures/child.ts',import.meta.url));
const options=(mode:string)=>({script,family:'fixture',seed:42,signal:new AbortController().signal,extraArgs:[mode],closeTimeoutMs:3000});

test('normal child is closed before success is returned',async()=>{
  let pid=0;
  const r=await runCampaign({...options('normal'),onSpawn:p=>pid=p});
  assert.equal(r.exitCode,0);assert.equal(r.cleanupConfirmed,true);assert.equal(r.cases,1);
  assert.throws(()=>process.kill(pid,0),{code:'ESRCH'});
});
test('timeout waits for the process group to stop',async()=>{
  let pid=0;
  const r=await runCampaign({...options('hang'),timeoutMs:300,onSpawn:p=>pid=p});
  assert.equal(r.error,'campaign-timeout');assert.equal(r.cleanupConfirmed,true);
  assert.throws(()=>process.kill(-pid,0),{code:'ESRCH'});
});
test('output limit stops and reaps the child',async()=>{
  const r=await runCampaign({...options('spam'),outputBytes:256});
  assert.equal(r.error,'output-limit');assert.equal(r.cleanupConfirmed,true);
});
test('cancellation closes the child before returning',async()=>{
  const controller=new AbortController();let pid=0;
  const r=await runCampaign({...options('hang'),signal:controller.signal,onSpawn:p=>{pid=p;controller.abort();}});
  assert.equal(r.error,'campaign-interrupted');assert.equal(r.cleanupConfirmed,true);
  assert.throws(()=>process.kill(-pid,0),{code:'ESRCH'});
});
test('successful parent cannot leave a detached campaign descendant behind',async()=>{
  let pid=0;
  const r=await runCampaign({...options('descendant'),onSpawn:p=>pid=p});
  assert.equal(r.exitCode,0);assert.equal(r.cleanupConfirmed,true);
  assert.throws(()=>process.kill(-pid,0),{code:'ESRCH'});
});
test('report write failure is explicit and does not throw',async()=>{
  const directory=await mkdtemp(join(tmpdir(),'studiquo-fuzz-report-test-'));
  try {
    const blocker=join(directory,'file');await writeFile(blocker,'synthetic');
    assert.equal(await saveReport(join(blocker,'report.json'),{}),false);
    const valid=join(directory,'report.json');assert.equal(await saveReport(valid,{status:'passed'}),true);
    assert.deepEqual(JSON.parse(await readFile(valid,'utf8')),{status:'passed'});
  } finally {await rm(directory,{recursive:true,force:true});}
});

for(const signal of ['SIGINT','SIGTERM'] as const)test(`CLI ${signal} stops its active campaign and saves an error report`,{timeout:10000},async()=>{
  const directory=await mkdtemp(join(tmpdir(),'studiquo-fuzz-signal-test-'));
  const output=join(directory,'report.json');
  const child=spawn(process.execPath,[fileURLToPath(new URL('./run.ts',import.meta.url)),'--output',output],{stdio:['ignore','pipe','ignore']});
  let sent=false,stdout='';
  child.stdout.on('data',part=>{
    stdout+=part.toString();
    // The first progress report proves CLI signal handlers are installed.
    // Its next campaign is a finite pure-parser process, not a live service.
    if(!sent&&stdout.includes('"family":"cbor"')){sent=true;child.kill(signal);}
  });
  const timer=setTimeout(()=>child.kill('SIGKILL'),8000);
  try {
    const code=await new Promise<number|null>((resolve,reject)=>{child.once('error',reject);child.once('close',resolve);});
    assert.equal(sent,true);assert.equal(code,2);
    const report=JSON.parse(await readFile(output,'utf8'));
    assert.equal(report.status,'error');assert.equal(report.interruption,signal);
    assert.ok(report.reports.every((r:{cleanupConfirmed:boolean})=>r.cleanupConfirmed));
  } finally {clearTimeout(timer);await rm(directory,{recursive:true,force:true});}
});
