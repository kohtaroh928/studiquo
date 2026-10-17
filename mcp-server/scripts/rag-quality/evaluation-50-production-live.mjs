import fs from 'node:fs';
import path from 'node:path';
import {captureProductionProbe,productionProbeMetadata} from './evaluation-50-production.mjs';
import {runE50Stage} from './evaluation-50-live.mjs';
import {loadOpenAIKey} from './learning-openai-live.mjs';
try {
 if(process.env.STUDIQUO_RAG_E50_PRODUCTION_REMOTE!=='true')throw Error('remote_opt_in_required');
 const directory=process.argv[2];
 // Fresh local indexing creates new citation generation IDs. Never recapture
 // into an existing run or create a replacement directory after uncertainty.
 if(!directory||!path.isAbsolute(directory)||fs.realpathSync(path.dirname(directory))!==path.dirname(directory))throw Error('unsafe_directory');
 try {fs.lstatSync(directory);throw Error('production_run_requires_audit');} catch(error) {if(error.code!=='ENOENT')throw error;}
 const productionProbe=await captureProductionProbe(process.env.STUDIQUO_RAG_E50_PRODUCTION_SUITE??'development');
 const result=await runE50Stage({directory,apiKey:loadOpenAIKey(),caseIds:productionProbeMetadata(productionProbe).caseIds,productionProbe,onProgress:p=>console.log(JSON.stringify(p))});
 console.log(JSON.stringify(result));
}catch{console.error('production_evaluation_stopped');process.exitCode=1;}
