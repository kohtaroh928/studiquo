import {canonicalJSON,prepareStructuredInput} from './structured-input.js';
const exact=(v,keys)=>v&&typeof v==='object'&&!Array.isArray(v)&&Object.keys(v).sort().join(',')===[...keys].sort().join(',');
const fail=()=>{throw Error('pdf_manifest_invalid');};
// Private RPC output is still untrusted. This performs final Worker validation,
// beyond the service's transport envelope validator. No index write or embedding.
export async function validateRawPDFManifest(value,digest){
 try{
  if(!exact(value,['version','integration','batches']))fail();
  const encoded=JSON.stringify(value);if(new TextEncoder().encode(encoded).byteLength>4*1024*1024)fail();
  const manifest=JSON.parse(encoded);
  if(manifest.version!==1||manifest.integration!=='prepared_only_no_upload'||!Array.isArray(manifest.batches)||manifest.batches.length<1||manifest.batches.length>20)fail();
  let next=1,total,common;const localIds=new Set();
  for(const b of manifest.batches){
   if(!exact(b,['structure','totalPages','pages'])||!Number.isInteger(b.totalPages)||b.totalPages<1||b.totalPages>20||!Array.isArray(b.pages)||b.pages.length<1||b.pages.length>5)fail();
   if(b.structure?.document?.pdfSha256!==digest)fail();
   const doc=b.structure.document;
   if(doc.parser?.name!=='docling'||doc.parser.version!=='2.139.0'||doc.parser.profile!=='native-layout-table-v1'||doc.semanticApplied!==false)fail();
   const binding=canonicalJSON(b.structure);
   if(total!==undefined&&(total!==b.totalPages||common!==binding))fail();
   total=b.totalPages;common=binding;
   for(const page of b.pages){
    if(!exact(page,['pageNumber','text','structured'])||page.pageNumber!==next++||typeof page.text!=='string'||!page.text.trim()||page.text.length>100000)fail();
   }
   await prepareStructuredInput({...b,title:''});
   for(const page of b.pages)for(const r of page.structured.records){
    if(localIds.has(r.metadata.localId))fail();localIds.add(r.metadata.localId);
   }
  }
  if(next!==total+1)fail();return manifest;
 }catch{fail();}
}
