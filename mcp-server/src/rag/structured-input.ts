// Untrusted document metadata. Never use any field here as authorization.
import * as z from 'zod/v4';
import { sha256Hex } from '../auth.ts';
import { tokenCount } from './chunking.ts';
const fail=()=>{throw Error('invalid_structured_input');};
const hex=z.string().regex(/^[a-f0-9]{64}$/u);
const ref=z.string().min(1).max(512).regex(/^[A-Za-z0-9_/#:.\-]+$/u);
const number=z.number().finite().min(-1e9).max(1e9);
const integer=z.number().int().min(0).max(8_000_000);
const bbox=z.object({l:number,t:number,r:number,b:number,coordOrigin:z.string().max(128).optional()}).strict();
const provenance=z.object({pageNumber:z.number().int().min(1).max(10000),bbox:bbox.nullable(),charspan:z.tuple([integer,integer]).nullable().optional()}).strict();
const parser=z.object({name:z.string().min(1).max(128),version:z.string().min(1).max(128),profile:z.string().min(1).max(128)}).strict();
export const structuredDocumentSchema=z.object({
 parser,pdfSha256:hex,strategy:z.literal('structure-semantic-recursive-v1'),semanticApplied:z.boolean(),
 semanticModel:z.string().min(1).max(128).refine(v=>v.trim().length>0).nullable(),maxEstimatedTokens:z.number().int().min(1).max(400),
 maxOverlapEstimatedTokens:z.number().int().min(0).max(65),semanticDistanceThreshold:z.number().finite().min(0).max(2),
 semanticFallbackReason:z.enum(['no_vectors','not_needed']).nullable(),namespaceScope:z.literal('document_parser_only_not_authentication'),
 offsetUnit:z.literal('unicode_codepoint'),provenanceScope:z.literal('element'),
}).strict();
const recordMetadata=z.object({
 documentNamespace:hex,kind:z.enum(['text','paragraph','title','section_header','list_item','footnote','caption','table','formula']),
 elementId:ref,localId:ref,idSource:z.enum(['docling_self_ref','synthetic_unknown','unknown']),pageNumbers:z.array(z.number().int().min(1).max(10000)).length(1),
 provenanceScope:z.literal('element'),provenance:z.array(provenance).min(1).max(16),coordinateState:z.enum(['known','unknown']),
 headingPath:z.object({state:z.enum(['explicit','partial','unknown']),reason:z.enum(['complete','cycle','missing_parent','ancestry_limit','no_explicit_heading']),
  items:z.array(z.object({elementId:ref,text:z.string().max(300),level:z.number().int().min(1).max(100).nullable()}).strict()).max(16)}).strict(),
 contextRefs:z.array(z.object({role:z.enum(['parent','child','caption']),elementId:ref,resolved:z.boolean()}).strict()).max(32),
 review:z.object({needsReview:z.literal(false),needsOCR:z.literal(false),reviewRequired:z.literal(false),oversized:z.literal(false)}).strict(),
 source:z.object({start:integer,end:integer,offsetUnit:z.literal('unicode_codepoint'),textSha256:hex}).strict(),tableStructureSha256:hex.optional(),
}).strict();
export const storedMetadataSchema=z.object({version:z.literal(1),documentNamespace:hex,document:structuredDocumentSchema,record:recordMetadata}).strict();
const structureSchema=z.object({version:z.literal(1),document:structuredDocumentSchema,documentNamespace:hex}).strict();
const pageSchema=z.object({version:z.literal(1),records:z.array(z.object({text:z.string().min(1).max(6000),metadata:recordMetadata}).strict()).min(1).max(100)}).strict();
export function canonicalJSON(value: any): any{
 if(value===null||typeof value!=='object')return JSON.stringify(value);
 if(Array.isArray(value))return '['+value.map(canonicalJSON).join(',')+']';
 return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonicalJSON(value[k])).join(',')+'}';
}
const bytes=(value: any)=>new TextEncoder().encode(typeof value==='string'?value:canonicalJSON(value)).byteLength;
function semanticValid(document: any){
 if(document.semanticApplied ? (!document.semanticModel||document.semanticFallbackReason!==null) : !['no_vectors','not_needed'].includes(document.semanticFallbackReason))fail();
 if(document.maxOverlapEstimatedTokens>=document.maxEstimatedTokens)fail();
}
function recordValid(record: any,pageNumber: any){
 if(record.pageNumbers[0]!==pageNumber||record.provenance.some((p: any)=>p.pageNumber!==pageNumber||p.charspan&&p.charspan[0]>p.charspan[1]))fail();
 if(record.source.end<=record.source.start||record.headingPath.items.map((i: any)=>i.text).join(' / ').length>1000)fail();
 if(record.headingPath.state==='unknown'&&record.headingPath.items.length||record.headingPath.state==='explicit'&&(record.headingPath.items.length===0||record.headingPath.reason!=='complete')||record.headingPath.state==='partial'&&(record.headingPath.items.length===0||record.headingPath.reason==='complete'))fail();
 const known=record.provenance.every((p: any)=>p.bbox&&['TOPLEFT','BOTTOMLEFT'].includes(p.bbox.coordOrigin));
 if(record.coordinateState!==(known?'known':'unknown'))fail();
 if(bytes(record)>16*1024)fail();
}
export async function prepareStructuredInput(payload: any){
 try{
  const anyPage=payload.pages.some((p: any)=>p?.structured!==undefined);
  if(payload.structure===undefined&&!anyPage)return null;
  if(payload.structure===undefined||payload.pages.some((p: any)=>p?.structured===undefined))fail();
  const structure=structureSchema.parse(payload.structure);semanticValid(structure.document);
  const expected=await sha256Hex(canonicalJSON({parser:structure.document.parser,pdfSha256:structure.document.pdfSha256}));
  if(expected!==structure.documentNamespace)fail();
  const prepared=new Map();let total=bytes(structure);const localIds=new Set();
  for(const page of payload.pages){
   const structured=pageSchema.parse(page.structured);total+=bytes(structured);
   if(total>256*1024)fail();
   const children=[];
   for(const row of structured.records){
    const record=row.metadata;recordValid(record,page.pageNumber);
    if(record.documentNamespace!==structure.documentNamespace||!row.text.trim()||tokenCount(row.text)>500||Array.from(row.text).some(c=>c.length===1&&c.charCodeAt(0)>=0xD800&&c.charCodeAt(0)<=0xDFFF)||record.source.end-record.source.start!==Array.from(row.text).length||await sha256Hex(row.text)!==record.source.textSha256)fail();
    if(localIds.has(record.localId))fail();localIds.add(record.localId);
    const headingContext=record.headingPath.items.map(i=>i.text).join(' / ');
    const metadata={version:1,documentNamespace:structure.documentNamespace,document:structure.document,record};
    if(bytes(metadata)>16*1024)fail();
    children.push({text:row.text,headingContext,embeddingText:JSON.stringify({title:payload.title.slice(0,300),headings:headingContext,text:row.text}),metadataJSON:canonicalJSON(metadata)});
   }
   prepared.set(page.pageNumber,{children,pageHash:await sha256Hex(canonicalJSON([page.text,structured]))});
  }
  return {structure,contextBinding:canonicalJSON({mode:'structured',version:1,structure}),pages:prepared};
 }catch{fail();}
}
export function readStoredMetadata(row: any){
 if(row?.metadata_json===null||row?.metadata_json===undefined||row.metadata_json==='')return undefined;
 try{
  if(typeof row.metadata_json!=='string'||bytes(row.metadata_json)>16*1024)fail();
  const value=storedMetadataSchema.parse(JSON.parse(row.metadata_json));semanticValid(value.document);recordValid(value.record,row.page_number);
  if(value.documentNamespace!==value.record.documentNamespace||typeof row.text==='string'&&value.record.source.end-value.record.source.start!==Array.from(row.text).length)fail();
  return value;
 }catch{throw Error('invalid_metadata');}
}
export function structuredCitation(rows: any){
 if(!Array.isArray(rows)||rows.length<1||rows.length>3)throw Error('invalid_metadata');
 const values: any[]=rows.map(readStoredMetadata);
 if(values.every(v=>v===undefined))return undefined;
 if(values.some(v=>v===undefined)||values.some(v=>v!.documentNamespace!==values[0].documentNamespace||canonicalJSON(v!.document)!==canonicalJSON(values[0].document)))throw Error('invalid_metadata');
 if(rows.some(row=>typeof row.chunk_id!=='string'||!/^[a-f0-9]{64}$/u.test(row.chunk_id)))throw Error('invalid_metadata');
 const value={version:1,documentNamespace:values[0].documentNamespace,parser:values[0].document.parser,provenanceScope:'element',segments:rows.map((row,i)=>({chunkId:row.chunk_id,elementId:values[i].record.elementId,kind:values[i].record.kind,rangeScope:'stored_chunk_not_excerpt',start:values[i].record.source.start,end:values[i].record.source.end,offsetUnit:'unicode_codepoint',provenance:values[i].record.provenance.slice(0,4),provenanceTruncated:values[i].record.provenance.length>4}))};
 if(bytes(value)>8192)throw Error('invalid_metadata');
 return value;
}
