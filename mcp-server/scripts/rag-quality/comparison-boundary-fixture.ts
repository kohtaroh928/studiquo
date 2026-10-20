// Synthetic development diagnostics. Separate from the frozen 50-question bank.
export function comparisonBoundaryFixture() {
 return {suiteId:'studiquo-comparison-boundary-20261014',syntheticOnly:true,humanGoldReview:'pending',cases:[
  {id:'boundary-explicit-metric',question:'合成灯Kについて、価格を点灯時間で割った値を単位付きで計算し、その指標の意味と、実際の電気代を示すのかを教えて。',history:[],
   pages:[{pageNumber:1,text:'合成灯Kの価格は1800円。合成灯Kの点灯時間は6時間。価格は本体の購入代金。点灯時間は1回の満充電で測定した連続点灯時間。'}],
   checks:['1800円÷6時間=300円/時間','購入価格と記載の満充電1回の点灯時間の比と説明','実際の電気代や継続使用の費用ではない','未記載の電力や電気料金を推定しない']},
  {id:'boundary-equal-category',question:'合成灯Lと合成灯Mの点灯時間と価格を比べ、使用場所も比較して。',history:[],
   pages:[{pageNumber:1,text:'合成灯Lは点灯6時間で価格1800円。合成灯Mは点灯6時間で価格1800円。合成灯Lの使用場所は屋内。合成灯Mの使用場所は屋外。'}],
   checks:['両方6時間で差がない','両方1800円で価格差がない','L屋内/M屋外を対応させる','カテゴリ属性の数量差を作らない']},
  {id:'boundary-different-conditions',question:'合成灯Nと合成灯Pの点灯時間と価格を比べて。時間と分の表記も確認し、お得な方を教えて。',history:[],
   pages:[{pageNumber:1,text:'合成灯Nは点灯6時間で価格2000円。合成灯Nの6時間は360分に相当し、最も弱い明るさで測定した値。合成灯Pは点灯2時間で価格2000円。合成灯Pの2時間は120分に相当し、最も強い明るさで測定した値。'}],
   checks:['N6時間/360分とP2時間/120分を正しく保持','N最弱/P最強の測定条件差を明示','価格同額2000円','条件が異なるため同条件の持続性能やお得さを確定しない','条件を無視した4時間の性能優位を主張しない']},
 ]};
}
