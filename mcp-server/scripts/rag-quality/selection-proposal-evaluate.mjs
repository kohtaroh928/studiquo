import {readFile,writeFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {validateFixture,measureSelection} from './citation-intent-evaluate.mjs';
import {proposalTask,runProposal} from './selection-proposal.mjs';
// Hand-authored simulations, not model outputs. They test the validator's limits.
const simulations=[
 ['biology-comparison',['r1','r3']],['biology-input-output',['r3']],
 ['split-materials',['r1']],['hidden-condition',['r1']],
 ['formula-scope',['r1']],['negated-distinction',['r1']],
 ['same-page-overlap',['r2']],['cross-source-confirmation',['r2']],
];
export async function evaluateProposals(input){
 const fixture=validateFixture(input),cases=[];
 for(const [id,retained] of simulations){
  const c=fixture.cases.find(c=>c.id===id);if(!c)throw Error('missing_simulation_case');
  const task=proposalTask(c.question,c.references.slice(0,5));
  const out=await runProposal(task,async()=>JSON.stringify({version:1,snapshot:task.snapshot,decision:'select',decisions:task.references.map(r=>({referenceId:r.id,action:retained.includes(r.id)?'retain':'omit',reason:retained.includes(r.id)?'answer':'supplementary',spans:[{start:0,end:Math.min(r.text.length,100),quote:r.text.slice(0,100)}]}))}));
  cases.push({id,status:out.status,productionEligible:out.productionEligible,safe:measureSelection(c,out.safeReferences),shadow:measureSelection(c,out.shadowReferences)});
 }
 return {schemaVersion:1,method:'Hand-authored proposal simulations. NO model calls or model-quality measurement. Labels are evaluation-only; they never enter proposalTask or messages. Structural validity does not imply complete answers.',labelStatus:fixture.labelStatus,
  summary:{simulations:cases.length,structurallyValid:cases.filter(c=>c.status==='shadow').length,validButMissingRequired:cases.filter(c=>c.status==='shadow'&&c.shadow.missingRequired.length).length,safeMissingRequired:cases.filter(c=>c.safe.missingRequired.length).length,productionEligible:cases.filter(c=>c.productionEligible).length},cases};
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 const fixture=JSON.parse(await readFile(new URL('./citation-intent-fixture.json',import.meta.url),'utf8')),report=await evaluateProposals(fixture);
 if(process.argv[2])await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');
 console.log(JSON.stringify(report.summary));
}
