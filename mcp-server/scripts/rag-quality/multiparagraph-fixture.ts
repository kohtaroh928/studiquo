// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
// Authored synthetic stress materials. No user documents, provider calls or production imports.
import {createHash} from 'node:crypto';
import {writeFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {validateFixture} from './citation-intent-evaluate.ts';
import {evaluateWitnessControls} from './paragraph-witness-evaluate.ts';
const reference=(id: any,sourceId: any,pageNumber: any,title: any,paragraphs: any)=>({id,sourceId,pageNumber,title,text:paragraphs.join('\n\n')});
function label(references: any,id: any,role: any,protectedFact: any,referenceId: any,quote: any){
 const r=references.find((r: any)=>r.id===referenceId),start=r?.text.indexOf(quote);
 if(start===undefined||start<0||r.text.indexOf(quote,start+1)>=0)throw Error('ambiguous_synthetic_label');
 return {id,role,protected:protectedFact,evidence:[{referenceId,start,end:start+quote.length,quote}]};
}
function sample(id: any,question: any,references: any,labels: any){
 return {id,split:'dev',question,references,facts:labels.map((args: any)=>label(references,...args))};
}
function freeze(value: any){if(value&&typeof value==='object'){for(const v of Object.values(value))freeze(v);Object.freeze(value);}return value;}
export const multiparagraphFixture=freeze(validateFixture({schemaVersion:1,labelStatus:'Authored synthetic stress labels; independent agent review applied; human/teacher review pending; no blind holdout.',cases:[
 sample('multi-input-output','光合成で使う材料とできる物、必要な条件を説明して。',[
  reference('r1','synthetic-reaction',2,'材料と反応の条件',[
   '光合成を学ぶときは、材料・生成物・反応条件を分けて整理する。これは評価用に作成した合成教材である。',
   '光合成では二酸化炭素と水を材料として使う。材料と条件は同じものではない。',
   '反応には光のエネルギーが必要である。光を材料そのものと混同しないようにする。',
   '二酸化炭素は気孔を通って葉に入り、水は根から吸収される。']),
  reference('r2','synthetic-reaction',3,'生成物と確認',[
   '反応後に何ができるかは、材料を扱う前ページと合わせて確認する。',
   '光合成では糖が作られ、酸素が生じる。材料と生成物を区別して説明する。',
   'この教材の余談として、植物を題材にした絵の展示について紹介する。',
   '水草の気泡を観察する実験は、生成物の確認例として使われる。'])
 ],[
  ['inputs','required',false,'r1','二酸化炭素と水を材料として使う。'],
  ['light','required',true,'r1','反応には光のエネルギーが必要である。'],
  ['outputs','required',false,'r2','糖が作られ、酸素が生じる。'],
  ['transport','supporting',false,'r1','二酸化炭素は気孔を通って葉に入り、水は根から吸収される。'],
  ['exhibition','off_intent',false,'r2','植物を題材にした絵の展示について紹介する。']
 ]),
 sample('multi-negated-comparison','植物の光合成と呼吸を比較して、夜に起こる働きも説明して。',[
  reference('r1','synthetic-day-night',4,'光合成の時間条件',[
   '昼と夜の違いを考える際には、二つの働きの条件に注目する。',
   '光合成は光のエネルギーを利用して糖を作る働きである。',
   '光がない暗所では光合成は起こらない。昼夜という呼び名だけで条件を決めない。',
   '葉緑体は光合成が行われる場所である。']),
  reference('r2','synthetic-day-night',5,'呼吸の時間条件',[
   '植物は夜も呼吸する。夜だから呼吸も止まるという説明は誤りである。',
   '呼吸は糖などを分解して、生命活動に使うエネルギーを取り出す働きである。',
   '植物は光合成を行う時間にも呼吸する。二つの働きが必ず交代するわけではない。',
   'このページは教材評価のための合成文であり、観察記録ではない。'])
 ],[
  ['photosynthesis','required',false,'r1','光のエネルギーを利用して糖を作る働きである。'],
  ['dark','required',true,'r1','光がない暗所では光合成は起こらない。'],
  ['respiration','required',false,'r2','糖などを分解して、生命活動に使うエネルギーを取り出す働きである。'],
  ['night','required',true,'r2','植物は夜も呼吸する。'],
  ['simultaneous','supporting',true,'r2','植物は光合成を行う時間にも呼吸する。']
 ]),
 sample('multi-formula-domain','直線上で向きを含めて扱う運動について、一定加速度の速度の式と各記号・単位、使える前提と使えない場合を説明して。',[
  reference('r1','synthetic-motion',7,'速度と一定加速度',[
   '直線上の運動を、向きを含めた速度と加速度で表す。',
   '時刻0からtまで加速度aが一定なら、速度はv = v0 + a tで求められる。',
   'この式でv0は時刻0の速度、tは時刻0からの経過時間を表す。',
   '単位をSIでそろえる場合、速度はm/s、加速度はm/s²、時間はsとする。']),
  reference('r2','synthetic-motion',8,'適用範囲と例',[
   '一定加速度の式を別の運動へ使うときは、前提を確認する。',
   '加速度が時間とともに変わる場合、一定値aを使うv = v0 + a tをそのまま適用しない。',
   '時刻0の速度が1 m/s、加速度が一定の2 m/s²なら、3 s後の速度は7 m/sになる。',
   '計算結果だけでなく、運動の向きをどう定めたかも確認する。'])
 ],[
  ['formula','required',false,'r1','速度はv = v0 + a tで求められる。'],
  ['constant','required',true,'r1','時刻0からtまで加速度aが一定なら'],
  ['symbols','required',false,'r1','この式でv0は時刻0の速度、tは時刻0からの経過時間を表す。'],
  ['units','required',true,'r1','速度はm/s、加速度はm/s²、時間はsとする。'],
  ['exception','required',true,'r2','加速度が時間とともに変わる場合、一定値aを使うv = v0 + a tをそのまま適用しない。'],
  ['worked-example','supporting',false,'r2','3 s後の速度は7 m/sになる。']
 ]),
 sample('multi-cross-source-exception','法人向け合成プランの料金・対象者・送料を説明して。個人も同条件で使える？',[
  reference('r1','synthetic-plan',10,'合成プランの案内',[
   '以下は実在する商品ではない評価用の合成プランである。',
   'このプランの利用料金は月額100円である。',
   '契約対象は法人に限る。個人向けサービスの料金表とは別に扱う。',
   '申込方法は別紙の案内を参照する。']),
  reference('r2','synthetic-terms',2,'対象者と配送の補足',[
   'これは合成プランの条件を補足する評価用文書である。',
   '個人の申込には月額100円の法人向け条件を適用しない。',
   '紙の教材を発送する場合、送料は利用料金に含まれず別途かかる。',
   '送料の具体額は配送地域で異なり、この資料では定めていない。']),
  reference('r3','synthetic-history',6,'案内冊子の余談',[
   'この冊子は評価用に作成した架空の案内である。',
   '表紙の色は創刊時の記念行事に合わせて選ばれた。',
   '次号では表紙のデザインが変わる予定である。'])
 ],[
  ['price','required',false,'r1','このプランの利用料金は月額100円である。'],
  ['corporate','required',true,'r1','契約対象は法人に限る。'],
  ['individual-excluded','required',true,'r2','個人の申込には月額100円の法人向け条件を適用しない。'],
  ['shipping','required',true,'r2','紙の教材を発送する場合、送料は利用料金に含まれず別途かかる。'],
  ['amount-unspecified','supporting',true,'r2','この資料では定めていない。'],
  ['cover-history','off_intent',false,'r3','表紙の色は創刊時の記念行事に合わせて選ばれた。']
 ])
]}));
export function multiparagraphControls(){
 return {...evaluateWitnessControls(multiparagraphFixture),fixtureHash:createHash('sha256').update(JSON.stringify(multiparagraphFixture)).digest('hex')};
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 const report=multiparagraphControls();if(process.argv[2])await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report.summary));
}
