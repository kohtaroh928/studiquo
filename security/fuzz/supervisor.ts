import {spawn} from 'node:child_process';
import {mkdir,writeFile} from 'node:fs/promises';
import {dirname} from 'node:path';

export interface CampaignOptions {
  script:string; family:string; seed:number; signal:AbortSignal;
  timeoutMs?:number; outputBytes?:number; closeTimeoutMs?:number;
  extraArgs?:string[]; onSpawn?:(pid:number)=>void;
}

function groupExists(pid:number):boolean {
  try { process.kill(-pid,0); return true; }
  catch(error) { if((error as NodeJS.ErrnoException).code==='ESRCH')return false; throw error; }
}

/** Kill only the detached group created by this supervisor, then confirm exit. */
async function finishGroup(pid:number|undefined,timeoutMs:number):Promise<boolean> {
  if(!pid)return true;
  try { process.kill(-pid,'SIGKILL'); }
  catch(error) { if((error as NodeJS.ErrnoException).code!=='ESRCH')return false; }
  const until=Date.now()+timeoutMs;
  do {
    try { if(!groupExists(pid))return true; } catch { return false; }
    await new Promise(resolve=>setTimeout(resolve,20));
  } while(Date.now()<until);
  return false;
}

export async function runCampaign(options:CampaignOptions):Promise<any> {
  const {script,family,seed,signal,timeoutMs=45000,outputBytes=1048576,closeTimeoutMs=3000}=options;
  if(signal.aborted)return {family,seed,error:'campaign-interrupted',cleanupConfirmed:true};
  return new Promise(resolveReport=>{
    const child=spawn(process.execPath,['--max-old-space-size=192',script,family,String(seed),...(options.extraArgs??[])],{stdio:['ignore','pipe','pipe'],detached:true});
    let stdout='',bytes=0,settled=false,closed=false,reason:string|undefined,closeTimer:ReturnType<typeof setTimeout>|undefined;
    const complete=(report:any)=>{
      if(settled)return;
      settled=true;clearTimeout(timer);clearTimeout(closeTimer);signal.removeEventListener('abort',abort);
      resolveReport(report);
    };
    const stop=(why:string)=>{
      if(settled||reason)return;
      reason=why;
      try { if(child.pid)process.kill(-child.pid,'SIGKILL'); }
      catch(error) { if((error as NodeJS.ErrnoException).code!=='ESRCH')reason='campaign-stop-failed'; }
      // A stop request is not proof of exit. Never launch the next family if
      // close does not arrive or group cleanup cannot be confirmed.
      closeTimer=setTimeout(()=>{
        if(!closed)complete({family,seed,error:'campaign-close-timeout',stopReason:reason,cleanupConfirmed:false});
      },closeTimeoutMs);
    };
    const abort=()=>stop('campaign-interrupted');
    const timer=setTimeout(()=>stop('campaign-timeout'),timeoutMs);
    signal.addEventListener('abort',abort,{once:true});
    child.once('spawn',()=>options.onSpawn?.(child.pid!));
    child.stdout.on('data',part=>{
      if(reason||settled)return;
      bytes+=part.length;
      if(bytes>outputBytes)stop('output-limit');else stdout+=part.toString();
    });
    child.stderr.on('data',()=>{}); // Never persist raw input/error bodies.
    child.once('error',()=>stop('campaign-start-failed'));
    child.once('close',async(code,exitSignal)=>{
      closed=true;clearTimeout(timer);clearTimeout(closeTimer);
      const cleanupConfirmed=await finishGroup(child.pid,closeTimeoutMs);
      if(!cleanupConfirmed){complete({family,seed,error:'campaign-group-cleanup-failed',stopReason:reason,exitCode:code,signal:exitSignal,cleanupConfirmed:false});return;}
      if(reason){complete({family,seed,error:reason,exitCode:code,signal:exitSignal,cleanupConfirmed:true});return;}
      try {
        const summary=JSON.parse(stdout.trim().split('\n').at(-1)!);
        if(summary.family!==family||summary.seed!==seed||!Number.isSafeInteger(summary.cases)||summary.cases<1||!Array.isArray(summary.findings))throw Error();
        complete({...summary,exitCode:code,signal:exitSignal,cleanupConfirmed:true});
      } catch { complete({family,seed,error:'invalid-campaign-report',exitCode:code,signal:exitSignal,cleanupConfirmed:true}); }
    });
    // Catch a cancellation between the initial check and listener installation.
    if(signal.aborted)abort();
  });
}

export async function saveReport(path:string,result:unknown):Promise<boolean> {
  try { await mkdir(dirname(path),{recursive:true});await writeFile(path,JSON.stringify(result,null,2)+'\n');return true; }
  catch { return false; }
}
