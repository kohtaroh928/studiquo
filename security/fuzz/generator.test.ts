import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath,URL} from 'node:url';
import {random,cbor,der,positiveInteger,mutate} from './generator.ts';

test('seed reproduces bytes and mutations',()=>{
  const a=random(123),b=random(123);
  for(let i=0;i<100;i++){
    const left=a.bytes(a.int(256)),right=b.bytes(b.int(256));
    assert.deepEqual(left,right);assert.deepEqual(mutate(a,left),mutate(b,right));
  }
});
test('CBOR generator agrees with independently specified wire examples',()=>{
  for(const [value,hex] of [[null,'f6'],[false,'f4'],[true,'f5'],[24,'1818'],[-25,'3818'],['a','6161'],[[1,2],'820102'],[{a:1},'a1616101']] as const)assert.equal(cbor(value).toString('hex'),hex);
  assert.equal(cbor(Object.fromEntries([['__proto__',{x:1}]]))[0],0xa1);
});
test('DER generator pads unsigned values and emits complete TLVs',()=>{
  assert.equal(positiveInteger(Buffer.from([0x80])).toString('hex'),'02020080');
  assert.equal(der(0x30,positiveInteger(Buffer.from([1])),positiveInteger(Buffer.from([2]))).toString('hex'),'3006020101020102');
});
for(const args of [['--unknown'],['--seed'],['--output'],['--seed','-1'],['--seed','NaN'],['--seed','4294967296']])test(`CLI rejects invalid arguments ${args.join(' ')}`,()=>{
  const result=spawnSync(process.execPath,[fileURLToPath(new URL('./run.ts',import.meta.url)),...args],{timeout:3000,encoding:'utf8'});
  assert.notEqual(result.status,0);assert.equal(result.signal,null);
});
