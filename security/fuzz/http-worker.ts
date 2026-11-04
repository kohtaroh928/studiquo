import {createRequire} from 'node:module';
import {readFileSync} from 'node:fs';
import {fileURLToPath,URL} from 'node:url';
import {join} from 'node:path';
import {randomBytes,createHash} from 'node:crypto';
import {random,tree} from './generator.ts';
import {handleAppAttest,issueChallenge,bytesToBase64Url} from '../../mcp-server/src/app-attest.ts';
import {partialEnv} from '../../mcp-server/src/test-env.ts';

export async function httpCampaign(r:ReturnType<typeof random>,counts:{cases:number;accepted:number;rejected:number},finding:(code:string,index:number,input:Uint8Array|string)=>void){
  const root=fileURLToPath(new URL('../../',import.meta.url)),require=createRequire(join(root,'mcp-server/package.json'));
  const {Miniflare,convertV4MiniflareOptions,Log,LogLevel}=require('miniflare'),{build}=require('esbuild');
  const names=[...new Set(readFileSync(join(root,'mcp-server/src/env.ts'),'utf8').match(/RATE_LIMIT_[A-Z_]+/g)??[])];
  const source=`import worker from './mcp-server/src/worker.ts';export * from './mcp-server/src/worker.ts';export default {...worker,fetch(request,env,ctx){const testEnv={...env};for(const name of ${JSON.stringify(names)})testEnv[name]={limit:async()=>({success:true})};return worker.fetch(request,testEnv,ctx);}};`;
  const built=await build({stdin:{contents:source,loader:'ts',resolveDir:root,sourcefile:'fuzz-local-worker.ts'},bundle:true,write:false,format:'esm',platform:'neutral',conditions:['workerd','worker','browser'],mainFields:['browser','module','main'],nodePaths:[join(root,'mcp-server/node_modules')],external:['cloudflare:workers','node:*'],logLevel:'silent'});
  let outbound=0;
  const options={host:'127.0.0.1',port:0,cf:false,kvPersist:false,d1Persist:false,durableObjectsPersist:false,cachePersist:false,modules:true,script:built.outputFiles[0].text,compatibilityDate:'2026-07-30',compatibilityFlags:['nodejs_compat'],kvNamespaces:['STUDIQUO_DATA'],durableObjects:Object.fromEntries(['ChatRoom','UserRegistry','DocumentRoom','RateCounter','MCPInbox'].map((className,i)=>[['CHAT_ROOM','USER_REGISTRY','DOCUMENT_ROOM','RATE_COUNTER','MCP_INBOX'][i],{className,useSQLite:true}])),bindings:{PRIVACY_RETENTION_ENABLED:'false',AI_PROVIDER_APPROVED:'false',APP_ATTEST_MODE:'off'},outboundService:()=>{outbound++;return new Response('External calls disabled',{status:502});},log:new Log(LogLevel.NONE)};
  const mf=new Miniflare(convertV4MiniflareOptions?convertV4MiniflareOptions(options):options);
  try{
    await mf.ready;
    const kv=await mf.getKVNamespace('STUDIQUO_DATA');
    const issuedAt=Math.floor(Date.now()/1000),token=`${issuedAt}.${randomBytes(32).toString('hex')}`,key=createHash('sha256').update(token).digest('hex');
    await kv.put(`session:${key}`,JSON.stringify({sub:'fuzz-synthetic-account',issuedAt}));
    const send=(path:string,body:string)=>mf.dispatchFetch('http://localhost'+path,{method:'POST',headers:{authorization:'Bearer '+token,'content-type':'application/json'},body,redirect:'manual'});
    const positive=await send('/api/chat/me',JSON.stringify({name:'synthetic-control'}));
    if(positive.status!==200)throw Error('HTTP positive control failed');await positive.body?.cancel();
    const poisons:any[]=[{},null,[],true,1,'text',{toString:{}},{toString:null},{valueOf:{},toString:1},['a','b'],Object.fromEntries([['__proto__',{marker:1}]])];
    const routes=[
      {path:'/api/chat/me',body:(v:any)=>({name:v,bio:'synthetic'})},
      {path:'/api/chat/me/avatar',body:(v:any)=>({contentType:v,data:'not-base64!'})},
      {path:'/api/chat/friends',body:(v:any)=>({code:v})},
      {path:'/api/chat/friends/link-add',body:(v:any)=>({token:v})},
      {path:'/api/chat/friends/requests/accept',body:(v:any)=>({code:v})},
      {path:'/api/chat/groups',body:(v:any)=>({name:v,memberCodes:[]})},
      {path:'/api/passkeys/register/options',body:(v:any)=>({email:v})},
      {path:'/api/passkeys/register/verify',body:(v:any)=>({transaction:v,response:{}})},
      {path:'/oauth/register',body:(v:any)=>({redirect_uris:['https://example.invalid/callback'],client_name:v})},
      {path:'/oauth/pair',body:(v:any)=>({id:v,code:'invalid'})},
    ];
    for(let i=0;i<120;i++)for(const route of routes){
      const value=i<poisons.length?poisons[i]:JSON.parse(JSON.stringify(tree(r)));
      const body=i%6===5?['{','[','"unterminated','{"x":NaN}'][r.int(4)]:JSON.stringify(route.body(value));
      const response=await send(route.path,body);counts.cases++;
      if(response.status>=500)finding('http-5xx:'+route.path,i,body);
      else if(response.status<400)counts.accepted++;else counts.rejected++;
      await response.body?.cancel();
    }
    for(const route of routes.filter(route=>route.path.startsWith('/oauth/')||route.path.startsWith('/api/passkeys/'))){
      const body=JSON.stringify(route.body({toString:{}}));
      const response=await mf.dispatchFetch('http://localhost'+route.path,{method:'POST',headers:{'content-type':'application/json'},body,redirect:'manual'});
      counts.cases++;
      if(response.status>=500)finding('http-anonymous-5xx:'+route.path,0,body);else counts.rejected++;
      await response.body?.cancel();
    }
    if(outbound!==0)throw Error('External call attempted');
    const health=await mf.dispatchFetch('http://localhost/health');
    if(health.status!==200)throw Error('Worker failed liveness after fuzzing');await health.body?.cancel();
  }finally{await mf.dispose();}

  // A separate route-level test reaches the attestation decoder with a valid
  // local challenge. No key is registered and no Apple service is contacted.
  let stored=0;
  const attest=partialEnv({TOKEN_SIGNING_KEY:randomBytes(32).toString('base64'),APP_ATTEST_APP_ID:'TEAM.synthetic.fuzz',APP_ATTEST_MODE:'enforce',RATE_LIMIT_ATTEST_REGISTER:{limit:async()=>({success:true})},RATE_COUNTER:{getByName:()=>({attestRegister:async()=>{stored++;return true;}})}});
  const challenge=await issueChallenge(attest),keyId=bytesToBase64Url(r.bytes(32));
  for(let i=0;i<600;i++){
    const bytes=i<3?Buffer.from([[0xf6],[0xa0],[0x30,0]][i]):r.bytes(r.int(1025));
    const request=new Request('http://localhost/api/attest/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({keyId,challenge,attestation:bytesToBase64Url(bytes)})});
    try{
      const response=await handleAppAttest(new URL(request.url),request,attest);counts.cases++;
      if(response?.status!==400)finding('attestation-random-accepted-or-error',i,bytes);else counts.rejected++;
    }catch{counts.cases++;finding('attestation-route-uncaught',i,bytes);}
  }
  if(stored!==0)throw Error('Random attestation registered a key');
}
