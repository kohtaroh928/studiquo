// Separate diagnostic only. Never replace the original bank or its results.
import {loadEvaluation50} from './evaluation-50.ts';

export function explicitOldRuleDiagnostic() {
 const bank=loadEvaluation50();
 bank.suiteId+='-explicit-old-rule-diagnostic';
 const c=bank.cases.find((c: any)=>c.id==='e50-versions-03');
 c.pages[0].text+='\nここで従来便とは改訂前の同じ合成輸送便を指す。2027年3月31日までの出発分には従来の出発2日前締切を適用する。';
 return bank;
}
