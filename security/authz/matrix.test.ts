import assert from 'node:assert/strict';
import {before,after,test} from 'node:test';
import {runtime,hash,type Runtime,type Actor} from './runtime.ts';
import {routes,ROOM,UUID} from './routes.ts';

let h:Runtime;
// Miniflare RPC results carry an inspect Symbol with a fresh function. Compare
// transported data, not the client-side diagnostic function's identity.
const data=(value:unknown)=>JSON.parse(JSON.stringify(value));
before(async()=>{
  h=await runtime();
  const actors=Object.values(h.actors);
  // Everybody is friends, so friendship validation cannot mask a missing
  // room authorization check. Room membership remains independent.
  for(let i=0;i<actors.length;i++)for(let j=i+1;j<actors.length;j++){
    assert.equal((await h.request('/api/chat/friends',actors[i],'POST',{code:actors[j].code})).status,200);
    assert.equal((await h.request('/api/chat/friends/requests/accept',actors[j],'POST',{code:actors[i].code})).status,200);
  }
});
after(async()=>{if(h){try{assert.equal(h.stats.outbound,0,'no external request may be attempted');}finally{await h.close();}}});

test('route inventory contains unique method/path pairs',()=>{
  assert.equal(new Set(routes.map(r=>`${r.method} ${r.path}`)).size,routes.length);
});

const validBody={email:'authz-probe@example.invalid',code:'123456',name:'synthetic',response:{},throughID:0,text:'synthetic',ids:[1],data:'c3ludGhldGlj',contentType:'text/plain'};
for(const route of routes.filter(r=>r.policy!=='public')){
  for(const identity of ['anonymous','unissued','expired','revoked','ordinary-user'] as const){
    if(route.policy==='session'&&identity==='ordinary-user')continue;
    test(`${route.method} ${route.path}: rejects ${identity}`,async()=>{
      const actor=identity==='ordinary-user'?h.actors.outsider:identity==='anonymous'?null:identity==='expired'?`1.${'e'.repeat(64)}`:identity==='revoked'?`${Math.floor(Date.now()/1000)}.${'d'.repeat(64)}`:`${Math.floor(Date.now()/1000)}.${'f'.repeat(64)}`;
      if(identity==='expired'||identity==='revoked'){
        await h.kv.put(`session:${hash(actor as string)}`,JSON.stringify({sub:'authz-synthetic-rejected',issuedAt:identity==='expired'?1:Math.floor(Date.now()/1000)}));
        if(identity==='revoked')await h.kv.put(`revoked:${hash(actor as string)}`,'1');
      }
      let body:unknown=validBody;
      if(route.path==='/api/passkeys/register/verify'&&actor){
        const transaction=`matrix-${identity}`;
        await h.kv.put(`passkeys:challenge:${transaction}`,JSON.stringify({kind:'registration',userKey:hash(actor as string),email:'authz-probe@example.invalid',challenge:'synthetic'}));
        body={...validBody,transaction};
      }
      const response=await h.request(route.path,actor,route.method,['GET','HEAD'].includes(route.method)?undefined:body);
      const payload=await response.text();
      const permitted=route.policy==='access'?[route.path.endsWith('/screenshot')?401:403]:identity==='anonymous'&&['/api/passkeys/register/verify','/api/passkeys/register/options'].includes(route.path)?[400]:[401,403];
      assert.ok(permitted.includes(response.status),`${response.status}: ${payload}`);
    });
  }
}

test('local real runtime is available to authenticated owner',async()=>{
  assert.equal((await h.request('/api/actions',h.actors.owner)).status,200);
});

let sequence=0;
async function documentFixture(){
  const id=hash(`document-fixture-${++sequence}`);
  const ns=await h.mf.getDurableObjectNamespace('DOCUMENT_ROOM');
  const room=ns.get(ns.idFromName(id));
  await room.initialize(h.actors.owner.chatKey,[{order:0,kind:'paragraph',text:'owner-original'}]);
  await room.invite(h.actors.owner.chatKey,h.actors.member.chatKey,'editor');
  await room.invite(h.actors.owner.chatKey,h.actors.reviewer.chatKey,'reviewer');
  await room.invite(h.actors.owner.chatKey,h.actors.removed.chatKey,'editor');
  await room.removeMember(h.actors.owner.chatKey,h.actors.removed.chatKey);
  const proposal=await room.proposeChange(h.actors.member.chatKey,0,'owner-original','member-proposed');
  return {id,room,proposal};
}
const documentCases=[
  {name:'state',method:'GET',path:(f:any)=>`/api/document/rooms/${f.id}/state`,body:undefined,allowed:['owner','member','reviewer']},
  {name:'participants',method:'GET',path:(f:any)=>`/api/document/rooms/${f.id}/participants`,body:undefined,allowed:['owner','member','reviewer']},
  {name:'propose',method:'POST',path:(f:any)=>`/api/document/rooms/${f.id}/propose`,body:{blockOrder:0,previousText:'owner-original',newText:'candidate'},allowed:['owner','member']},
  {name:'review',method:'POST',path:(f:any)=>`/api/document/rooms/${f.id}/changes/${f.proposal.id}/review`,body:{decision:'accept'},allowed:['owner','reviewer']},
  {name:'invite',method:'POST',path:(f:any)=>`/api/document/rooms/${f.id}/invite`,body:{role:'editor'},allowed:['owner']},
  {name:'remove',method:'DELETE',path:(f:any)=>`/api/document/rooms/${f.id}/participants/${h.actors.reviewer.chatKey}`,body:undefined,allowed:['owner']},
  {name:'leave',method:'POST',path:(f:any)=>`/api/document/rooms/${f.id}/leave`,body:{},allowed:['member','reviewer']},
];
for(const c of documentCases)for(const role of ['owner','member','reviewer','outsider','removed']){
  test(`document ${c.name}: ${role}`,async()=>{
    const f=await documentFixture(),actor=h.actors[role];
    const before=data(await f.room.getState(h.actors.owner.chatKey));
    const members=data(await f.room.listParticipants(h.actors.owner.chatKey));
    const body=c.name==='invite'?{...c.body,code:(role==='outsider'?h.actors.removed:h.actors.outsider).code}:c.body;
    const response=await h.request(c.path(f),actor,c.method,body);
    assert.equal(response.status,c.allowed.includes(role)?200:c.name==='leave'&&role==='owner'?400:403,await response.text());
    if(!c.allowed.includes(role)){
      assert.deepEqual(data(await f.room.getState(h.actors.owner.chatKey)),before,'denied write changed document');
      assert.deepEqual(data(await f.room.listParticipants(h.actors.owner.chatKey)),members,'denied write changed membership');
    }
  });
}

test('document initialization cannot replace an existing owner or contents',async()=>{
  const f=await documentFixture();
  const r=await h.request(`/api/document/rooms/${f.id}/init`,h.actors.outsider,'POST',{blocks:[{order:0,text:'injected'}]});
  assert.equal(r.status,200);
  assert.equal((await r.json()).status,'already_initialized');
  assert.equal(await f.room.roleOf(h.actors.outsider.chatKey),null);
  assert.equal((await f.room.getState(h.actors.owner.chatKey)).blocks[0].text,'owner-original');
});

async function chatFixture(group=false){
  const id=hash(`chat-fixture-${++sequence}`),ns=await h.mf.getDurableObjectNamespace('CHAT_ROOM'),room=ns.get(ns.idFromName(id));
  await room.initialize(id,[h.actors.owner.chatKey,h.actors.member.chatKey],group?{kind:'group',name:'synthetic group',creatorCode:h.actors.owner.code,creatorName:'owner'}:{});
  if(group){await room.addParticipant(h.actors.removed.chatKey,h.actors.removed.code,'removed');await room.removeParticipant(h.actors.owner.chatKey,h.actors.removed.chatKey);}
  const message=await room.sendMessage(h.actors.owner.chatKey,'owner-message');
  const attachment=await room.storeAttachment(h.actors.owner.chatKey,'text/plain',Buffer.from('owner-attachment').toString('base64'));
  return {id,room,message,attachment};
}
const chatCases=[
  {name:'messages-read',method:'GET',tail:(f:any)=>'messages',body:undefined},
  {name:'messages-write',method:'POST',tail:(f:any)=>'messages',body:{text:'candidate'}},
  {name:'read-position',method:'POST',tail:(f:any)=>'read',body:{throughID:1}},
  {name:'lookup',method:'POST',tail:(f:any)=>'messages/lookup',body:{ids:[1]}},
  {name:'edit',method:'POST',tail:(f:any)=>`messages/${f.message.id}/edit`,body:{text:'edited'}},
  {name:'cancel',method:'POST',tail:(f:any)=>`messages/${f.message.id}/cancel`,body:{}},
  {name:'report',method:'POST',tail:(f:any)=>`messages/${f.message.id}/report`,body:{reason:'synthetic'}},
  {name:'attachment-upload',method:'POST',tail:(f:any)=>'attachments',body:{contentType:'text/plain',data:'c3ludGhldGlj'}},
  {name:'attachment-download',method:'GET',tail:(f:any)=>`attachments/${f.attachment.id}`,body:undefined},
  {name:'block-status',method:'GET',tail:(f:any)=>'block-status',body:undefined},
  {name:'block',method:'POST',tail:(f:any)=>'block',body:{}},
  {name:'unblock',method:'POST',tail:(f:any)=>'unblock',body:{}},
];
for(const group of [false,true])for(const c of chatCases.filter(c=>!group||!['block','unblock','block-status'].includes(c.name)))for(const role of group?['owner','member','outsider','removed']:['owner','member','outsider']){
  test(`${group?'group':'direct'} chat ${c.name}: ${role}`,async()=>{
    const f=await chatFixture(group),before=data(await f.room.listMessages(h.actors.owner.chatKey,0));
    const response=await h.request(`/api/chat/rooms/${f.id}/${c.tail(f)}`,h.actors[role],c.method,c.body);
    const allowed=role!=='outsider'&&role!=='removed'&&(!(c.name==='edit'||c.name==='cancel')||role==='owner');
    const payload=await response.text();
    assert.equal(response.status,allowed?(c.name==='attachment-upload'?201:c.name==='report'&&role==='owner'?400:200):403,payload);
    if(c.name==='attachment-download'&&allowed)assert.equal(payload,'owner-attachment');
    if(!allowed)assert.deepEqual(data(await f.room.listMessages(h.actors.owner.chatKey,0)),before,'denied operation changed messages');
  });
}

const groupCases=[
  {name:'rename',method:'PATCH',tail:'',body:{name:'renamed'}},
  {name:'invite',method:'POST',tail:'/invites',body:{}},
  {name:'remove-member',method:'DELETE',tail:'/members/',body:undefined},
  {name:'avatar-upload',method:'POST',tail:'/avatar',body:{contentType:'image/png',data:'c3ludGhldGlj'}},
  {name:'avatar-read',method:'GET',tail:'/avatar',body:undefined},
];
for(const c of groupCases)for(const role of ['owner','member','outsider','removed']){
  test(`group ${c.name}: ${role}`,async()=>{
    const f=await chatFixture(true),before=data(await f.room.groupInfo(h.actors.owner.chatKey));
    await h.kv.put(`chat:group-avatar:${f.id}`,JSON.stringify({contentType:'image/png',data:'c3ludGhldGlj',updatedAt:Date.now()}));
    const body=c.name==='invite'?{code:h.actors.reviewer.code}:c.body;
    const tail=c.name==='remove-member'?c.tail+h.actors.member.code:c.tail;
    const r=await h.request(`/api/chat/groups/${f.id}${tail}`,h.actors[role],c.method,body);
    assert.equal(r.status,role==='owner'||role==='member'?200:403,await r.text());
    if(role==='outsider'||role==='removed')assert.deepEqual(data(await f.room.groupInfo(h.actors.owner.chatKey)),before);
  });
}

for(const kind of ['document','group'])for(const decision of ['accept',kind==='document'?'decline':'reject']){
  test(`${kind} invite ${decision}: only the intended invitee consumes it`,async()=>{
    const f=kind==='document'?await documentFixture():await chatFixture(true);
    const target=h.actors.outsider;
    const invitePath=kind==='document'?`/api/document/rooms/${f.id}/invite`:`/api/chat/groups/${f.id}/invites`;
    assert.equal((await h.request(invitePath,h.actors.owner,'POST',{code:target.code,role:'editor'})).status,200);
    const responsePath=kind==='document'?`/api/document/rooms/${f.id}/invite/${decision}`:`/api/chat/groups/${f.id}/invites/${decision}`;
    assert.equal((await h.request(responsePath,h.actors.removed,'POST',{})).status,404);
    assert.equal((await h.request(responsePath,target,'POST',{})).status,200);
    assert.equal((await h.request(responsePath,target,'POST',{})).status,404,'invitation replay must fail');
  });
}

test('actions read/delete are scoped to the caller despite supplied victim identifiers',async()=>{
  for(const actor of [h.actors.owner,h.actors.outsider])await h.kv.put(`actions:${actor.key}`,JSON.stringify([{type:'synthetic',owner:actor.name}]));
  const query=`?sub=${h.actors.owner.sub}&key=${h.actors.owner.key}`;
  const r=await h.request('/api/actions'+query,h.actors.outsider);
  assert.deepEqual(await r.json(),[{type:'synthetic',owner:'outsider'}]);
  assert.equal((await h.request('/api/actions'+query,h.actors.outsider,'DELETE',{sub:h.actors.owner.sub,key:h.actors.owner.key})).status,200);
  assert.deepEqual(JSON.parse(await h.kv.get(`actions:${h.actors.owner.key}`)),[{type:'synthetic',owner:'owner'}]);
});

for(const route of routes.filter(r=>r.policy==='access')){
  test(`${route.method} ${route.path}: wrong Access audience is refused`,async()=>{
    const r=await h.request(route.path,null,route.method,['GET','HEAD'].includes(route.method)?undefined:validBody,{'cf-access-jwt-assertion':await h.access('wrong-audience')});
    assert.equal(r.status,route.path.endsWith('/screenshot')?401:403);
  });
  if(route.method!=='GET')test(`${route.method} ${route.path}: authenticated cross-site admin write is refused`,async()=>{
    const r=await h.request(route.path,null,route.method,validBody,{'cf-access-jwt-assertion':await h.access(),Origin:'https://attacker.invalid','sec-fetch-site':'cross-site'});
    assert.equal(r.status,403);
  });
}
for(const path of ['/api/admin/stats','/api/admin/announcements','/api/admin/issue-reports','/api/admin/chat-reports','/api/admin/app-errors','/api/admin/audit-log','/api/admin/accounts/suspended']){
  test(`positive Access control ${path}`,async()=>{
    const r=await h.request(path,null,'GET',undefined,{'cf-access-jwt-assertion':await h.access()});
    assert.equal(r.status,200,await r.text());
  });
}

test('MCP inbox list/acknowledgement cannot read or consume another account item',async()=>{
  const ns=await h.mf.getDurableObjectNamespace('MCP_INBOX');
  const inbox=(a:Actor)=>ns.get(ns.idFromName(hash(`mcp-account:${a.sub}`)));
  const id=crypto.randomUUID();
  await inbox(h.actors.owner).enqueue(id,'create_document',{title:'owner-private'},'synthetic');
  const list=await h.request('/api/mcp/inbox',h.actors.outsider);
  assert.deepEqual(await list.json(),[]);
  const wrong=await h.request(`/api/mcp/inbox/${id}`,h.actors.outsider,'POST',{});
  assert.equal((await wrong.json()).status,'missing');
  assert.equal((await (await h.request('/api/mcp/inbox',h.actors.owner)).json())[0].id,id);
  const right=await h.request(`/api/mcp/inbox/${id}`,h.actors.owner,'POST',{});
  assert.equal((await right.json()).status,'imported');
});

test('MCP connection list/revoke uses the caller namespace even with a known foreign grant id',async()=>{
  const id=hash('synthetic-client'),key=`mcp:grant:${hash(h.actors.owner.sub)}:${id}`;
  await h.kv.put(key,JSON.stringify({clientName:'owner-only',kind:'other',createdAt:Date.now(),nonce:'synthetic-generation'}));
  assert.deepEqual(await (await h.request('/api/mcp/connections',h.actors.outsider)).json(),[]);
  assert.equal((await h.request(`/api/mcp/connections/${id}`,h.actors.outsider,'DELETE')).status,200);
  assert.notEqual(await h.kv.get(key),null,'foreign revoke removed owner grant');
  assert.equal((await (await h.request('/api/mcp/connections',h.actors.owner)).json())[0].id,id);
  assert.equal((await h.request(`/api/mcp/connections/${id}`,h.actors.owner,'DELETE')).status,200);
  assert.equal(await h.kv.get(key),null);
});

test('library-id is derived from authenticated identity, ignoring a foreign query parameter',async()=>{
  const owner=await (await h.request('/api/account/library-id',h.actors.owner)).json();
  const outsider=await (await h.request(`/api/account/library-id?sub=${h.actors.owner.sub}`,h.actors.outsider)).json();
  assert.notEqual(owner.libraryID,outsider.libraryID);
  assert.ok(owner.libraryID&&outsider.libraryID);
});

test('passkey registration cannot bind a foreign verified mailbox; matching owner has a positive control',async()=>{
  const email='mailbox-owner@example.invalid';
  await h.kv.put(`email-account-owner:${email}`,h.actors.owner.sub);
  // A test mailbox proof for the owner's authenticated token, not a bypass of
  // the route's mailbox ownership or session checks.
  await h.kv.put(`passkey-email-proof:${h.actors.owner.key}`,email);
  const wrong=await h.request('/api/passkeys/register/options',h.actors.outsider,'POST',{email});
  assert.equal(wrong.status,403);
  const right=await h.request('/api/passkeys/register/options',h.actors.owner,'POST',{email});
  assert.equal(right.status,200,await right.clone().text());
  const registration=await right.json();
  const stolen=await h.request('/api/passkeys/register/verify',h.actors.outsider,'POST',{transaction:registration.transaction,response:{}});
  assert.equal(stolen.status,400);
  assert.notEqual(await h.kv.get(`passkeys:challenge:${registration.transaction}`),null,'foreign request consumed owner challenge');
});

test('private report screenshot requires Access even for its reporter',async()=>{
  const id=crypto.randomUUID();
  await h.kv.put(`issue-report:${id}`,JSON.stringify({id,createdAt:Date.now(),reporterKey:h.actors.owner.key}));
  await h.kv.put(`issue-report-screenshot:${id}`,JSON.stringify({contentType:'image/png',data:'c3ludGhldGlj'}));
  for(const actor of [null,h.actors.owner,h.actors.outsider])assert.equal((await h.request(`/api/issue-reports/${id}/screenshot`,actor)).status,401);
  const r=await h.request(`/api/issue-reports/${id}/screenshot`,null,'GET',undefined,{'cf-access-jwt-assertion':await h.access()});
  assert.equal(r.status,200);assert.equal(await r.text(),'synthetic');
});

test('profile avatar allows self/friend and hides it from a registered non-friend',async()=>{
  const actor=h.actors.owner;
  assert.equal((await h.request('/api/chat/me/avatar',actor,'POST',{contentType:'image/png',data:'c3ludGhldGlj'})).status,200);
  assert.equal((await h.request(`/api/chat/avatar/${actor.code}`,actor)).status,200);
  assert.equal((await h.request(`/api/chat/avatar/${actor.code}`,h.actors.member)).status,200);
  assert.equal((await h.request(`/api/chat/friends/${actor.code}`,h.actors.outsider,'DELETE')).status,200);
  assert.equal((await h.request(`/api/chat/avatar/${actor.code}`,h.actors.outsider)).status,404);
});

async function prepareRAG(actor:Actor,documentId:string){
  const current=await (await h.request('/api/rag/consent',actor)).json();
  if(!current.enabled){
    const enabled=await h.request('/api/rag/consent',actor,'POST',{enabled:true,expectedEpoch:current.consentEpoch});
    assert.equal(enabled.status,200,await enabled.clone().text());
  }
  const consent=await (await h.request('/api/rag/consent',actor)).json();
  const response=await h.request('/api/rag/documents/prepare',actor,'POST',{documentId,requestId:crypto.randomUUID(),expectedGeneration:0,consentEpoch:consent.consentEpoch,sourceHash:hash('synthetic-content'),title:`private-${actor.name}`,totalPages:1});
  assert.equal(response.status,200,await response.clone().text());
  const doc=await response.json();
  await h.db.prepare('INSERT INTO rag_sources(account_key,source_id,title,kind,source_hash,total_pages,complete) VALUES(?,?,?,\'pdf\',?,1,1)').bind(hash(`rag-account:${actor.sub}`),doc.sourceId,`private-${actor.name}`,hash('synthetic-content')).run();
  return doc;
}

test('RAG read/status/readiness and state invalidation are account-scoped for a known foreign document',async()=>{
  const documentId='synthetic-private-document';
  const doc=await prepareRAG(h.actors.owner,documentId);
  const ownerState=await (await h.request(`/api/rag/documents/${documentId}/state`,h.actors.owner)).json();
  assert.equal(ownerState.title,'private-owner');
  const foreign=await (await h.request(`/api/rag/documents/${documentId}/state`,h.actors.outsider)).json();
  assert.equal(foreign.state,'missing');assert.equal(foreign.title,undefined);
  const ownStatus=await (await h.request('/api/rag/status',h.actors.owner)).json();
  assert.ok(ownStatus.sources.some((s:any)=>s.sourceId===doc.sourceId));
  const otherStatus=await (await h.request('/api/rag/status',h.actors.outsider)).json();
  assert.ok(!otherStatus.sources.some((s:any)=>s.sourceId===doc.sourceId));
  const ready=await h.request(`/api/rag/sources/${doc.sourceId}/readiness`,h.actors.outsider);
  assert.equal(ready.status,200);assert.equal((await ready.json()).state,'missing');
  const ownReady=await h.request(`/api/rag/sources/${doc.sourceId}/readiness`,h.actors.owner);
  assert.equal(ownReady.status,200);
  assert.deepEqual(await ownReady.json(),{state:'empty',sourceHash:hash('synthetic-content')});
  const consent=await h.request('/api/rag/consent',h.actors.outsider,'POST',{enabled:true,expectedEpoch:0});assert.equal(consent.status,200);
  const bad=await h.request(`/api/rag/documents/${documentId}/state`,h.actors.outsider,'POST',{state:'excluded',expectedGeneration:doc.generation,consentEpoch:1,accountKey:hash(`rag-account:${h.actors.owner.sub}`)});
  assert.equal(bad.status,409);
  assert.deepEqual(await (await h.request(`/api/rag/documents/${documentId}/state`,h.actors.owner)).json(),ownerState);
  const good=await h.request(`/api/rag/documents/${documentId}/state`,h.actors.owner,'POST',{state:'excluded',expectedGeneration:doc.generation,consentEpoch:doc.consentEpoch});
  assert.equal(good.status,200);
});

for(const route of ['resource','body'])test(`RAG source delete (${route}) cannot delete another account's source`,async()=>{
  const doc=await prepareRAG(h.actors.owner,`delete-${route}`),key=hash(`rag-account:${h.actors.owner.sub}`);
  const path=route==='resource'?`/api/rag/sources/${doc.sourceId}`:'/api/rag/source';
  const r=await h.request(path,h.actors.outsider,'DELETE',{sourceId:doc.sourceId,accountKey:key});
  assert.equal(r.status,200,await r.text());
  assert.equal((await h.db.prepare('SELECT deleted FROM rag_sources WHERE account_key=? AND source_id=?').bind(key,doc.sourceId).first()).deleted,0);
  const own=await h.request(path,h.actors.owner,'DELETE',{sourceId:doc.sourceId});
  assert.equal(own.status,200,await own.text());
  assert.equal((await h.db.prepare('SELECT deleted FROM rag_sources WHERE account_key=? AND source_id=?').bind(key,doc.sourceId).first())?.deleted??1,1);
});
