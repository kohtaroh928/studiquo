// Evaluation-only structural references. No semantic interpretation or transport.
import {createHash} from 'node:crypto';
const separators=new Set(['。','！','？','!','?','\r','\n','\u2028','\u2029']);
// Fixed ECMAScript WhiteSpace + LineTerminator set; no ICU segmentation.
const whitespace=/^[\u0009-\u000d\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]$/u;
const invalid=()=>{throw Error('question_units_invalid_input');};
export function createQuestionUnits(question){
 if(arguments.length!==1||typeof question!=='string'||!question.trim()||Buffer.byteLength(question)>16384||/[\uD800-\uDFFF]/u.test(question))invalid();
 const base={version:1,questionHash:createHash('sha256').update(question).digest('hex'),semanticCompleteness:'not_evaluated',releaseAccepted:false};
 const unsupported=()=>({...base,status:'unsupported',reason:'unit_limit',unitCountLowerBound:65,units:[]});
 const ranges=[];let start=0,index=0,content=false;
 while(index<question.length){
  const char=String.fromCodePoint(question.codePointAt(index));
  if(separators.has(char)){
   let end=index;
   // Only adjacent separator characters form a run; spaces break the run.
   while(end<question.length&&separators.has(question[end])){if(!whitespace.test(question[end]))content=true;end++;}
   if(content){ranges.push([start,end]);if(ranges.length>64)return unsupported();start=end;content=false;}
   index=end;
  }else{if(!whitespace.test(char))content=true;index+=char.length;}
 }
 if(start<question.length){
  if(!content&&ranges.length)ranges.at(-1)[1]=question.length;
  else{ranges.push([start,question.length]);if(ranges.length>64)return unsupported();}
 }
 const units=ranges.map(([start,end],i)=>({id:'u'+(i+1),start,end,text:question.slice(start,end)}));
 return {...base,status:'supported',unitCount:units.length,units};
}
