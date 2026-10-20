// Bounded, conservative observations from the final authorized excerpts only.
// This recognizes a limited syntax; absence of a condition is never equality.
const escape=(s: any)=>s.replace(/[.*+?^${}()|[\]\\]/gu,'\\$&');
const unsafe=/指示|命令|system|ignore|回答して|と答え|捏造|偽造|不明|未記載|ではない|でない|ではなく|でなく/iu;
const spans=(text: any)=>[...text.matchAll(/[^。！？\n]+[。！？]?/gu)].map(m=>({quote:m[0],start:m.index,end:m.index+m[0].length}));
const number=(s: any)=>Number(s.replaceAll(',',''));

export function organizeComparisonEvidence(references: any,subjects: any) {
 if(!Array.isArray(subjects)||subjects.length<2||subjects.length>3||!Array.isArray(references)||references.length>5)return null;
 const facts=[];
 for(const [referenceIndex,reference] of references.entries()) {
  if(typeof reference.text!=='string'||reference.text.length>24000)return null;
  const rows=spans(reference.text);
  for(const [index,row] of rows.entries()) {
   if(row.quote.length>300||unsafe.test(row.quote))continue;
   const owners=subjects.filter(subject=>new RegExp('^\\s*'+escape(subject)+'(?:の|は|が|[:：])','iu').test(row.quote));
   if(owners.length!==1)continue;
   const subject=owners[0];
   // Do not attach a condition if a sentence also names another subject.
   const exclusive=!subjects.some(s=>s!==subject&&row.quote.toLowerCase().includes(s.toLowerCase()));
   if(!exclusive)continue;
   const evidence={referenceIndex,citation:{...reference.citation},quote:row.quote,start:row.start,end:row.end};
   const prefix='^\\s*'+escape(subject);
   const price=new RegExp(prefix+'(?:の価格(?:は|が|[:：])?|は(?:点灯(?:時間)?(?:は)?\\s*\\d+(?:\\.\\d+)?(?:時間|分|秒)で)?価格(?:は|が|[:：])?)\\s*([\\d,]+(?:\\.\\d+)?)円[。]?$','iu').exec(row.quote);
   const duration=new RegExp(prefix+'(?:の点灯時間|は点灯(?:時間)?)(?:は|が|[:：])?\\s*(\\d+(?:\\.\\d+)?)(時間|分|秒)(?=[。、,\\s]|で価格|$)','iu').exec(row.quote);
   for(const [facet,match,unit] of [['price',price,'円'],['duration',duration,duration?.[2]]]) {
    if(!match||!Number.isFinite(number(match[1]))||number(match[1])<0)continue;
    if(facet==='duration'&&[...row.quote.matchAll(/\d+(?:\.\d+)?(?:時間|分|秒)/gu)].length!==1)continue;
    const fact={subject,facet,value:number(match[1]),unit,...evidence,conditions:[] as any[],conditionRecognition:'absent'};
    if(facet==='duration'&&exclusive) {
     const candidates=[row];
     const next=rows[index+1];
     // Adjacent same-paragraph, same-named subject, same explicit value/unit.
     // Never remove an unsafe sentence then stitch its neighbors together.
     if(next&&!/\n\s*\n/u.test(reference.text.slice(row.end,next.start))&&!unsafe.test(next.quote)&&next.quote.length<=300&&
      new RegExp('^\\s*'+escape(subject)+'の'+escape(match[1])+escape(unit),'iu').test(next.quote)&&
      !subjects.some(s=>s!==subject&&next.quote.toLowerCase().includes(s.toLowerCase())))candidates.push(next);
     for(const candidate of candidates) {
      const proof={referenceIndex,citation:{...reference.citation},quote:candidate.quote,start:candidate.start,end:candidate.end};
      if(!/測定/u.test(candidate.quote))continue;
      // Consume the complete condition clause, not only its final temperature
      // or brightness. Unknown methods/qualifiers stay unknown.
      const owner=candidate===row?escape(duration![0])+'[、,]':
       '\\s*'+escape(subject)+'の'+escape(match[1])+escape(unit)+'(?:は\\d+(?:\\.\\d+)?(?:時間|分|秒)に相当し)?[、,]?';
      const condition=new RegExp('^'+owner+'(最も弱い明るさ|最弱の明るさ|最も強い明るさ|最強の明るさ|-?\\d+(?:\\.\\d+)?(?:℃|°C))で測定(?:した値|した)?[。]?$','iu').exec(candidate.quote);
      if(!condition){fact.conditionRecognition='unrecognized';continue;}
      const value=condition[1];
      fact.conditions.push({dimension:/℃|°C/iu.test(value)?'temperature':'brightness',
       value:/℃|°C/iu.test(value)?Number.parseFloat(value):/弱/u.test(value)?'minimum':'maximum',...proof});
      if(fact.conditionRecognition!=='unrecognized')fact.conditionRecognition='recognized';
     }
    }
    facts.push(fact);if(facts.length>12)return null;
   }
  }
 }
 if(!facts.some(f=>f.conditions.length||f.conditionRecognition==='unrecognized'))return null; // No recognized measurement syntax: retain legacy behavior, never claim equal conditions.
 const result={version:1,scope:'recognized_lighting_duration_and_price_only',facts};
 return new TextEncoder().encode(JSON.stringify(result)).length<=6000?result:null;
}

export function assessComparisonEvidence(evidence: any,subjects: any) {
 if(!evidence)return null;
 const durations=subjects.map((subject: any)=>evidence.facts.filter((f: any)=>f.subject===subject&&f.facet==='duration'));
 let status=durations.some((rows: any)=>rows.length===0)?'missing':'unknown';
 const values=durations.map((rows: any)=>rows.flatMap((f: any)=>f.conditions));
 // Multiple observations, including conflicting values, are not one experiment.
 const single=durations.every((rows: any)=>rows.length===1&&rows[0].conditionRecognition!=='unrecognized');
 if(single) {
  const dimensions=['brightness','temperature'].filter(d=>values.some((rows: any)=>rows.some((c: any)=>c.dimension===d)));
  const sets=dimensions.map(d=>values.map((rows: any)=>[...new Set(rows.filter((c: any)=>c.dimension===d).map((c: any)=>c.value))]));
  const complete=dimensions.length>0&&sets.every(rows=>rows.every((v: any)=>v.length===1));
  if(complete)status=sets.some(rows=>new Set(rows.map((v: any)=>v[0])).size>1)?'mismatch':'comparable';
 }
 const prices=subjects.map((subject: any)=>evidence.facts.filter((f: any)=>f.subject===subject&&f.facet==='price'));
 const result={...evidence,durationComparison:status,
  interpretation:'Comparable covers only recognized explicit conditions; it is not proof that every experimental condition matches.',
  performanceDifferenceAllowed:status==='comparable',
  recordedPriceDurationRatioAllowed:status==='comparable'&&durations.every((rows: any)=>rows[0].value>0)&&prices.every((rows: any)=>rows.length===1),
  costEffectivenessRankingAllowed:false}; // A ratio alone cannot establish overall value.
 return new TextEncoder().encode(JSON.stringify(result)).length<=6000?result:null;
}
