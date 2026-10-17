// Synthetic development probes, separate from the frozen 50-question bank.
// An oracle of requested operations, never an answer-generation input.
export function questionTaskFixture() {
 const items=[
  ['fees','一般料金と学生料金はいくらですか。学生料金の対象条件も教えてください。',[
   ['lookup','いくら','一般料金'],['lookup','いくら','学生料金'],['conditions','対象条件','学生料金']]],
  ['delivery','配送Xと配送Yの到着日数を比較し、急ぐ場合にどちらを選べるか教えてください。',[
   ['compare','比較','到着日数'],['recommend','どちらを選べる','配送方法']]],
  ['calculation','教材Aの注文部数と単価から、税抜の合計金額を計算してください。送料も含めた最終支払額はいくらですか。',[
   ['calculate','計算','税抜合計'],['lookup','いくら','最終支払額']]],
  ['exceptions','通常の返却期限と延長できる条件、職員が返却日を変更した場合の例外を教えてください。',[
   ['lookup','返却期限','通常返却期限'],['conditions','条件','延長'],['conditions','例外','職員変更時']]],
  ['learning','密度の式と各記号の意味を説明し、初心者向けに体積と質量の関係も解説してください。',[
   ['lookup','式','密度の式'],['explain','意味を説明','各記号'],['explain','解説','体積と質量の関係']]],
  ['conflicting_summary','案内Aと案内Bの利用規則を要約し、矛盾している点と一致している点を比較してください。',[
   ['summarize','要約','利用規則'],['compare','比較','矛盾点'],['compare','比較','一致点']]],
 ];
 return {version:1,syntheticOnly:true,split:'development',humanReview:'pending',cases:items.map(([id,question,requests])=>({
  id:'task-'+id,question,requirements:requests.map(([operation,quote,attribute],i)=>({
   id:'r'+(i+1),operation,attribute,questionSpan:{start:question.indexOf(quote),end:question.indexOf(quote)+quote.length,text:quote},
  })),
 }))};
}
