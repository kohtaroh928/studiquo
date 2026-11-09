// No dependency or real inputs: the seed and case index reproduce every byte.
export function random(seed:number){
  let state=seed>>>0;
  const uint=()=>state=(Math.imul(state,1664525)+1013904223)>>>0;
  return {uint,int:(n:number)=>uint()%n,bytes:(n:number)=>Uint8Array.from({length:n},()=>uint()>>>24)};
}
export function cbor(value:any):Buffer{
  const head=(major:number,n:number)=>n<24?Buffer.from([major*32+n]):n<256?Buffer.from([major*32+24,n]):n<65536?Buffer.from([major*32+25,n>>>8,n&255]):Buffer.from([major*32+26,n>>>24,(n>>>16)&255,(n>>>8)&255,n&255]);
  if(value===null)return Buffer.from([0xf6]);
  if(typeof value==='boolean')return Buffer.from([value?0xf5:0xf4]);
  if(typeof value==='number')return head(value<0?1:0,value<0?-1-value:value);
  if(typeof value==='string'){const bytes=Buffer.from(value);return Buffer.concat([head(3,bytes.length),bytes]);}
  if(value instanceof Uint8Array)return Buffer.concat([head(2,value.length),value]);
  if(Array.isArray(value))return Buffer.concat([head(4,value.length),...value.map(cbor)]);
  const entries=Object.entries(value);
  return Buffer.concat([head(5,entries.length),...entries.flatMap(([k,v])=>[cbor(k),cbor(v)])]);
}
export function tree(r:ReturnType<typeof random>,depth=0):any{
  const strings=['','ascii','資料','😀','\ufeffleading','__proto__','constructor','toString'];
  switch(r.int(depth>3?5:8)){
    case 0:return null;
    case 1:return r.int(2)===1;
    case 2:return r.int(65536)-32768;
    case 3:return strings[r.int(strings.length)];
    case 4:return r.bytes(r.int(65));
    case 5:return Array.from({length:r.int(5)},()=>tree(r,depth+1));
    default:return Object.fromEntries(Array.from({length:r.int(5)},(_,i)=>[strings[r.int(strings.length)]+(i===0?'':i),tree(r,depth+1)]));
  }
}
export function mutate(r:ReturnType<typeof random>,source:Uint8Array):Uint8Array{
  const b=Buffer.from(source);
  switch(r.int(5)){
    case 0:if(b.length)b[r.int(b.length)]^=1<<r.int(8);return b;
    case 1:return b.subarray(0,r.int(b.length+1));
    case 2:return Buffer.concat([b,r.bytes(1+r.int(8))]);
    case 3:return r.bytes(r.int(513));
    default:if(b.length)b[r.int(b.length)]=r.int(256);return b;
  }
}
export function der(tag:number,...parts:Uint8Array[]):Buffer{
  const b=Buffer.concat(parts);
  return Buffer.concat([Buffer.from(b.length<128?[tag,b.length]:b.length<256?[tag,0x81,b.length]:[tag,0x82,b.length>>>8,b.length&255]),b]);
}
export function positiveInteger(bytes:Uint8Array):Buffer{
  let b=Buffer.from(bytes);while(b.length>1&&b[0]===0)b=b.subarray(1);
  if(b[0]&128)b=Buffer.concat([Buffer.from([0]),b]);
  return der(2,b);
}
