import {createRequire} from 'node:module';
import {randomBytes, createHash} from 'node:crypto';
import {readFileSync,readdirSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';

export const root=fileURLToPath(new URL('../../',import.meta.url));
const require=createRequire(join(root,'mcp-server/package.json'));
const {generateKeyPair,exportJWK,SignJWT}=require('jose');
const {Miniflare,convertV4MiniflareOptions,Log,LogLevel}=require('miniflare');
const {build}=require('esbuild');
const {unstable_splitSqlQuery:splitSqlQuery}=require('wrangler');
export const hash=(s:string)=>createHash('sha256').update(s).digest('hex');
export type Actor={name:string;sub:string;token:string;key:string;chatKey:string;code?:string};
export async function runtime(){
  const keys=await generateKeyPair('ES256',{extractable:true});
  const jwk=await exportJWK(keys.publicKey);
  const access=async(aud='authz-test')=>new SignJWT({sub:'synthetic-admin'}).setProtectedHeader({alg:'ES256'}).setIssuer('https://authz-test.cloudflareaccess.com').setAudience(aud).setIssuedAt().setExpirationTime('1h').sign(keys.privateKey);
  // The wrapper supplies only local JWKS and non-throttling test limiters.
  // Authentication and authorization remain the actual production handlers.
  const compiled=await build({stdin:{contents:`import worker from './mcp-server/src/worker.ts'; import {createLocalJWKSet} from 'jose'; export * from './mcp-server/src/worker.ts'; const jwks=createLocalJWKSet(${JSON.stringify({keys:[{...jwk,alg:'ES256',use:'sig'}]})}); export default {...worker,fetch(request,env,ctx){const testEnv={...env,ACCESS_JWKS:jwks}; for(const name of ${JSON.stringify([...new Set(readFileSync(join(root,'mcp-server/src/env.ts'),'utf8').match(/RATE_LIMIT_[A-Z_]+/g)??[])])})testEnv[name]={limit:async()=>({success:true})}; return worker.fetch(request,testEnv,ctx);}};`,resolveDir:root,sourcefile:'authz-local-worker.ts',loader:'ts'},bundle:true,write:false,format:'esm',platform:'neutral',mainFields:['browser','module','main'],conditions:['workerd','worker','browser'],external:['cloudflare:workers','node:*'],nodePaths:[join(root,'mcp-server/node_modules')],logLevel:'silent'});
  const stats={outbound:0};
  const options={host:'127.0.0.1',port:0,cf:false,kvPersist:false,d1Persist:false,durableObjectsPersist:false,cachePersist:false,modules:true,script:compiled.outputFiles[0].text,compatibilityDate:'2026-07-30',compatibilityFlags:['nodejs_compat'],kvNamespaces:['STUDIQUO_DATA'],d1Databases:['ADMIN_DB'],durableObjects:Object.fromEntries(['ChatRoom','UserRegistry','DocumentRoom','RateCounter','MCPInbox'].map((className,i)=>[['CHAT_ROOM','USER_REGISTRY','DOCUMENT_ROOM','RATE_COUNTER','MCP_INBOX'][i],{className,useSQLite:true}])),bindings:{ACCESS_AUD:'authz-test',ACCESS_TEAM_DOMAIN:'authz-test.cloudflareaccess.com',PRIVACY_RETENTION_ENABLED:'false',AI_PROVIDER_APPROVED:'true',PAYWALL_ENABLED:'true',RAG_ENABLED:'true',RAG_AUTO_INDEX_ENABLED:'true',REQUIRE_SIGNED_TOKENS:'false',MCP_REFUSE_SESSION_TOKENS:'false'},outboundService:()=>{stats.outbound++;return new Response('External calls disabled',{status:502});},log:new Log(LogLevel.NONE)};
  const mf=new Miniflare(convertV4MiniflareOptions?convertV4MiniflareOptions(options):options);
  try{
    await mf.ready;
    const kv=await mf.getKVNamespace('STUDIQUO_DATA');
    const db=await mf.getD1Database('ADMIN_DB');
    for(const file of readdirSync(join(root,'mcp-server/migrations')).filter(f=>f.endsWith('.sql')).sort()){
      const sql=readFileSync(join(root,'mcp-server/migrations',file),'utf8');
      await db.batch(splitSqlQuery(sql).map((statement:string)=>db.prepare(statement)));
    }
    const actors:Record<string,Actor>={};
    for(const name of ['owner','member','reviewer','outsider','removed']){
      const issuedAt=Math.floor(Date.now()/1000),token=`${issuedAt}.${randomBytes(32).toString('hex')}`,sub=`authz-synthetic-${name}`,key=hash(token);
      await kv.put(`session:${key}`,JSON.stringify({sub,issuedAt}));
      actors[name]={name,sub,token,key,chatKey:hash(`chat-account:${sub}`)};
    }
    const request=async(path:string,actor:Actor|string|null=null,method='GET',body?:unknown,headers:Record<string,string>={})=>mf.dispatchFetch(`http://localhost${path}`,{method,headers:{...(actor?{authorization:`Bearer ${typeof actor==='string'?actor:actor.token}`}:{ }),'content-type':'application/json','X-Studiquo-AI-Consent':'openai-v1','X-Studiquo-Age':'adult','X-Studiquo-RAG-Consent':'rag-openai-v1',...headers},body:body===undefined?undefined:JSON.stringify(body),redirect:'manual'});
    for(const a of Object.values(actors)){
      const r=await request('/api/chat/me',a,'POST',{name:a.name});if(r.status!==200)throw Error(`register ${a.name}: ${r.status}`);
      a.code=(await r.json()).code;
    }
    return {mf,kv,db,actors,request,access,stats,close:()=>mf.dispose()};
  }catch(e){await mf.dispose();throw e;}
}
export type Runtime=Awaited<ReturnType<typeof runtime>>;
