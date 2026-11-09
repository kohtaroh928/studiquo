// Synthetic supervisor fixture; it never imports or calls application code.
import {spawn} from 'node:child_process';
const [family,seed,mode]=process.argv.slice(2);
const report={family,seed:Number(seed),cases:1,findings:[]};
if(mode==='normal')console.log(JSON.stringify(report));
else if(mode==='hang')setInterval(()=>{},1000);
else if(mode==='spam'){process.stdout.write('x'.repeat(8192));setInterval(()=>{},1000);}
else if(mode==='descendant'){
  spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{stdio:'ignore'}).unref();
  console.log(JSON.stringify(report));
} else throw Error('Unknown fixture');
