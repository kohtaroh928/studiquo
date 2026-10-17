// Review registration only: no key loader, transport or automatic execution.
import {openUnitPlannerJournal} from './unit-task-planner-journal.mjs';
export function recordUnitPlannerReview(options){
 let journal;
 try{
  if(arguments.length!==1||!options||typeof options!=='object'||Array.isArray(options)||Object.keys(options).length!==2||!Object.hasOwn(options,'directory')||!Object.hasOwn(options,'review'))throw Error();
  journal=openUnitPlannerJournal(options.directory);const status=journal.recordReview(options.review);journal.close();journal=null;return status;
 }catch{try{journal?.close();}catch{}throw Error('unit_review_audit_required');}
}
