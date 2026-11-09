import assert from 'node:assert/strict';
import {createHash,randomBytes,generateKeyPairSync,sign} from 'node:crypto';
import {performance} from 'node:perf_hooks';
import {readFileSync} from 'node:fs';
import {URL} from 'node:url';
import {readTextLimited,readJSONLimited,isWellFormedBase64} from '../../mcp-server/src/http.ts';
import {bearerToken} from '../../mcp-server/src/auth.ts';
import {isExpired,remainingValiditySeconds,VALIDITY_SECONDS} from '../../mcp-server/src/token.ts';
import {sessionTokenAcceptable,accessTokenAcceptable,signSessionToken,signAccessToken} from '../../mcp-server/src/token-signature.ts';
import {decodeCBOR,parseCertificate,derSignatureToRaw,bytesToBase64Url,verifyAssertion,challengeIsValid,issueChallenge,handleAppAttest} from '../../mcp-server/src/app-attest.ts';
import {partialEnv} from '../../mcp-server/src/test-env.ts';
import {random,tree,cbor,mutate,der,positiveInteger} from './generator.ts';

const family=process.argv[2],seed=Number(process.argv[3]);
if(!['cbor','der','json','token','http'].includes(family)||!Number.isSafeInteger(seed)||seed<0||seed>0xffffffff)throw Error('Invalid campaign arguments');
const r=random(seed),started=performance.now();
const findings=new Map<string,{code:string;count:number;caseIndex:number;sha256:string}>();
const counts={cases:0,accepted:0,rejected:0};
function finding(code:string,index:number,input:Uint8Array|string){
  const previous=findings.get(code);if(previous){previous.count++;return;}
  findings.set(code,{code,count:1,caseIndex:index,sha256:createHash('sha256').update(input).digest('hex')});
}
function check(code:string,index:number,input:Uint8Array|string,condition:boolean){if(!condition)finding(code,index,input);}
function rejectOrValue(callback:()=>unknown){try{const value=callback();counts.accepted++;return {ok:true,value};}catch(e){counts.rejected++;if(!(e instanceof Error))throw e;return {ok:false,value:undefined};}}
function jsonTree(value:any):any{
  if(value instanceof Uint8Array)return [...value];
  if(Array.isArray(value))return value.map(jsonTree);
  if(value&&typeof value==='object')return Object.fromEntries(Object.entries(value).map(([k,v])=>[k,jsonTree(v)]));
  return value;
}
function cborDifference(expected:any,actual:any):string|null{
  if(expected instanceof Uint8Array)return actual instanceof Uint8Array&&Buffer.from(expected).equals(Buffer.from(actual))?null:'cbor-byte-string-changed';
  if(typeof expected==='string'&&actual!==expected&&expected.startsWith('\ufeff'))return 'cbor-leading-bom-removed';
  if(expected&&typeof expected==='object'){
    if(!actual||typeof actual!=='object'||Array.isArray(expected)!==Array.isArray(actual))return 'cbor-value-shape-changed';
    for(const key of Object.keys(expected)){
      if(!actual||!Object.hasOwn(actual,key))return key==='__proto__'?'cbor-prototype-key-lost':key.startsWith('\ufeff')?'cbor-leading-bom-key-removed':'cbor-map-key-lost';
      const diff=cborDifference(expected[key],actual[key]);if(diff)return diff;
    }
    return Object.keys(actual).length===Object.keys(expected).length?null:'cbor-map-keys-changed';
  }
  try{assert.deepEqual(actual,expected);return null;}catch{return 'cbor-valid-roundtrip';}
}

async function run(){
  if(family==='cbor'){
    const fixtures=[null,false,true,0,-1,23,24,255,256,65535,65536,'資料😀','\ufeffleading',Object.fromEntries([['__proto__',{marker:1}]]),{constructor:1,toString:2},[1,{nested:[null]}]];
    for(let i=0;i<5000;i++){
      const value=i<fixtures.length?fixtures[i]:tree(r),bytes=cbor(value);counts.cases++;
      try{const decoded=decodeCBOR(bytes);counts.accepted++;const diff=cborDifference(value,decoded);if(diff)finding(diff,i,bytes);}
      catch{counts.rejected++;finding('cbor-valid-rejected',i,bytes);}
      const malformed=mutate(r,bytes);counts.cases++;rejectOrValue(()=>decodeCBOR(malformed));
      const trailing=Buffer.concat([bytes,Buffer.from([0])]);counts.cases++;
      const result=rejectOrValue(()=>decodeCBOR(trailing));check('cbor-trailing-accepted',i,trailing,!result.ok);
    }
    for(const [i,bytes] of [Buffer.from([0x9a,255,255,255,255]),Buffer.from([0xba,255,255,255,255]),Buffer.from([0x7a,255,255,255,255]),Buffer.concat([Buffer.alloc(10,0x81),Buffer.from([0])])].entries()){
      counts.cases++;check('cbor-boundary-accepted',i,bytes,!rejectOrValue(()=>decodeCBOR(bytes)).ok);
    }
    check('global-prototype-modified',0,'prototype',!Object.hasOwn(Object.prototype,'marker'));
  }
  if(family==='der'){
    const source=readFileSync(new URL('../../mcp-server/src/app-attest.ts',import.meta.url),'utf8');
    const publicRoot=Buffer.from(source.match(/const APPLE_ROOT_DER_BASE64 = "([A-Za-z0-9+/=]+)"/)![1],'base64');
    // Public Apple trust anchor from the implementation: no private key or
    // client certificate is read. It reaches nested X.509 parsing paths.
    counts.cases++;check('x509-positive-root-failed',0,publicRoot,parseCertificate(publicRoot).point.length===97);
    for(let i=0;i<3000;i++){
      const left=r.bytes(1+r.int(32)),right=r.bytes(1+r.int(32));
      if(left.every(v=>v===0))left[left.length-1]=1;if(right.every(v=>v===0))right[right.length-1]=1;
      const encoded=der(0x30,positiveInteger(left),positiveInteger(right));counts.cases++;
      const raw=derSignatureToRaw(encoded,32),expected=Buffer.alloc(64);Buffer.from(left).copy(expected,32-left.length);Buffer.from(right).copy(expected,64-right.length);
      check('der-valid-roundtrip',i,encoded,Buffer.from(raw).equals(expected));counts.accepted++;
      const invalids=[
        ['der-trailing-accepted',Buffer.concat([encoded,Buffer.from([0])])],
        ['der-negative-integer-accepted',der(0x30,der(2,Buffer.from([0x80])),positiveInteger(right))],
        ['der-empty-integer-accepted',der(0x30,der(2,Buffer.alloc(0)),positiveInteger(right))],
        ['der-extra-integer-accepted',der(0x30,positiveInteger(left),positiveInteger(right),positiveInteger(Buffer.from([1])))],
        ['der-redundant-zero-accepted',der(0x30,der(2,Buffer.from([0,1])),positiveInteger(right))],
      ] as const;
      for(const [code,bytes] of invalids){counts.cases++;check(code,i,bytes,!rejectOrValue(()=>derSignatureToRaw(bytes,32)).ok);}
      counts.cases++;rejectOrValue(()=>derSignatureToRaw(mutate(r,encoded),32));
      counts.cases++;rejectOrValue(()=>parseCertificate(r.bytes(r.int(1025))));
      counts.cases++;rejectOrValue(()=>parseCertificate(mutate(r,publicRoot)));
    }
    // A real, locally generated signature proves the positive verification
    // path. Mutations never get the private key; none may forge new content.
    const appId='TEAM.synthetic.fuzz',clientData='POST\n/api/synthetic\n1';
    const keys=generateKeyPairSync('ec',{namedCurve:'prime256v1'});
    const auth=Buffer.concat([createHash('sha256').update(appId).digest(),Buffer.from([0,0,0,0,1])]);
    const digest=createHash('sha256').update(Buffer.concat([auth,createHash('sha256').update(clientData).digest()])).digest();
    const signature=sign('sha256',digest,keys.privateKey);
    const publicKey=bytesToBase64Url(keys.publicKey.export({type:'spki',format:'der'}).subarray(-65));
    const proof=cbor({signature,authenticatorData:auth});counts.cases++;
    check('assertion-positive-failed',0,proof,await verifyAssertion({assertion:proof,clientData,publicKey,storedCounter:0,appId})===1);
    let accepted=false;try{await verifyAssertion({assertion:proof,clientData:clientData+'tampered',publicKey,storedCounter:0,appId});accepted=true;}catch{}
    counts.cases++;check('assertion-content-forgery',0,proof,!accepted);
    const inherited=cbor(Object.fromEntries([['__proto__',{signature,authenticatorData:auth}]]));
    let inheritedAccepted=false;try{await verifyAssertion({assertion:inherited,clientData,publicKey,storedCounter:0,appId});inheritedAccepted=true;}catch{}
    counts.cases++;check('assertion-prototype-fields-accepted',0,inherited,!inheritedAccepted);
    const trailingProof=cbor({signature:Buffer.concat([signature,Buffer.from([0])]),authenticatorData:auth});
    let trailingAccepted=false;try{await verifyAssertion({assertion:trailingProof,clientData,publicKey,storedCounter:0,appId});trailingAccepted=true;}catch{}
    counts.cases++;check('assertion-trailing-der-accepted',0,trailingProof,!trailingAccepted);
  }
  if(family==='json'){
    const fixtures=['','{','null','[]','{}','{"__proto__":{"marker":1}}','"資料😀"','[1,2,3]','{"toString":{}}','true','1e999','\ufeff{}'];
    for(let i=0;i<4000;i++){
      const source=i<fixtures.length?Buffer.from(fixtures[i]):i%2?Buffer.from(JSON.stringify(jsonTree(tree(r)))):Buffer.from(r.bytes(r.int(2049)));
      const limit=i%3===0?source.length:Math.max(0,source.length+(r.int(9)-4));
      const chunk=1+r.int(31),declared=i%4===0?source.length+100:i%4===1?0:source.length;
      const request=()=>{let offset=0;return new Request('http://localhost/synthetic',{method:'POST',headers:{'content-length':String(declared)},body:new ReadableStream({pull(controller){if(offset>=source.length){controller.close();return;}controller.enqueue(source.subarray(offset,offset+chunk));offset+=chunk;}}),duplex:'half'} as RequestInit);};
      const text=await readTextLimited(request(),limit);counts.cases++;
      check('json-byte-limit-or-chunk-boundary',i,source,text===(source.length>limit?null:new TextDecoder().decode(source)));
      let expected:any=null;if(declared<=limit&&source.length<=limit){try{expected=JSON.parse(new TextDecoder().decode(source));}catch{}}
      const actual=await readJSONLimited(request(),limit);counts.cases++;
      try{assert.deepEqual(actual,expected);}catch{finding('json-parse-or-declared-limit',i,source);}
      counts.accepted++;
      const encoded=Buffer.from(r.bytes(r.int(129))).toString('base64');counts.cases++;
      check('base64-valid-rejected',i,encoded,isWellFormedBase64(encoded));
      counts.cases++;check('base64-invalid-accepted',i,encoded+'!',!isWellFormedBase64(encoded+'!'));
    }
    check('global-prototype-modified',0,'prototype',!Object.hasOwn(Object.prototype,'marker'));
  }
  if(family==='token'){
    const env=partialEnv({TOKEN_SIGNING_KEY:randomBytes(32).toString('base64'),REQUIRE_SIGNED_TOKENS:'true'});
    const payload=`${Math.floor(Date.now()/1000)}.${'a'.repeat(64)}`;
    const session=await signSessionToken(env,payload),access=await signAccessToken(env,'mcp_'+ 'b'.repeat(64));
    check('session-positive-rejected',0,session,await sessionTokenAcceptable(env,session));
    check('access-positive-rejected',0,access,await accessTokenAcceptable(env,access));
    for(let i=0;i<4000;i++){
      const original=i%2?session:access;
      const value=Buffer.from(mutate(r,Buffer.from(original))).toString('utf8');
      if(value===original)continue;
      counts.cases++;
      check('session-mutant-accepted',i,value,!await sessionTokenAcceptable(env,value));
      check('access-mutant-accepted',i,value,!await accessTokenAcceptable(env,value));
      const req=new Request('http://localhost/synthetic',{headers:{authorization:'Bearer '+Buffer.from(value).toString('base64')}});
      const extracted=bearerToken(req);check('bearer-length-invalid',i,value,extracted===null||(extracted.length>=32&&extracted.length<=256));
      isExpired(value);const remaining=remainingValiditySeconds(value);check('token-ttl-out-of-bounds',i,value,remaining>=60&&remaining<=VALIDITY_SECONDS);
    }
    const challenge=await issueChallenge(env);
    check('challenge-positive-rejected',0,challenge,await challengeIsValid(env,challenge));
    for(let i=0;i<1000;i++){
      const value=Buffer.from(mutate(r,Buffer.from(challenge))).toString('utf8');if(value===challenge)continue;
      counts.cases++;check('challenge-mutant-accepted',i,value,!await challengeIsValid(env,value));
    }
  }
  if(family==='http'){
    const {httpCampaign}=await import('./http-worker.ts');
    await httpCampaign(r,counts,(code,index,input)=>finding(code,index,input));
  }
}
try{
  await run();
  console.log(JSON.stringify({family,seed,...counts,elapsedMs:Math.round(performance.now()-started),maxRssKiB:process.resourceUsage().maxRSS,findings:[...findings.values()]}));
}catch(e){
  console.log(JSON.stringify({family,seed,...counts,error:e instanceof Error?e.name:'UnknownError',findings:[...findings.values()]}));process.exitCode=2;
}
