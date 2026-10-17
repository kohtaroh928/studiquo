// Run ONE reviewed variant. Check completion before starting the next variant.
import fs from 'node:fs';
import path from 'node:path';
import {capturePolicyProbe, productionProbeMetadata} from './evaluation-50-production.mjs';
import {runE50Stage} from './evaluation-50-live.mjs';
import {loadOpenAIKey} from './learning-openai-live.mjs';
try {
 if(process.env.STUDIQUO_RAG_POLICY_REMOTE!=='true')throw Error('remote_opt_in_required');
 const directory=process.argv[2],variant=process.argv[3];
 if(!directory||!path.isAbsolute(directory)||fs.realpathSync(path.dirname(directory))!==path.dirname(directory))throw Error('unsafe_directory');
 try{fs.lstatSync(directory);throw Error('policy_run_requires_audit');}catch(error){if(error.code!=='ENOENT')throw error;}
 const probe=capturePolicyProbe(variant);
 const result=await runE50Stage({directory,apiKey:loadOpenAIKey(),caseIds:productionProbeMetadata(probe).caseIds,productionProbe:probe,
  onProgress:p=>console.log(JSON.stringify(p))});
 console.log(JSON.stringify(result));
}catch{console.error('policy_evaluation_stopped');process.exitCode=1;}
