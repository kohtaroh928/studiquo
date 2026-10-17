import json,re,unicodedata,statistics
from pathlib import Path
root=Path(__import__('sys').argv[1]);f=json.loads((root/'fixture.json').read_text());ps=json.loads((root/'extracted-pages.json').read_text())
def normalize(t): return re.sub(r'\s+','',unicodedata.normalize('NFKC',t))
def dist(a,b):
 prev=list(range(len(b)+1))
 for i,c in enumerate(a,1):
  row=[i]
  for j,d in enumerate(b,1): row.append(min(row[-1]+1,prev[j]+1,prev[j-1]+(c!=d)))
  prev=row
 return prev[-1]
rows=[]
for p,e in zip(f['pages'],ps):
 truth=normalize(p['text']);actual=normalize(e['text']);actual=re.sub(str(p['pageNumber'])+'$', '',actual)
 rows.append({'pageNumber':p['pageNumber'],'scan':p['scan'],'referenceCharacters':len(truth),'editDistance':dist(truth,actual),'factExact':normalize(p['fact']) in actual,'textLayerEmpty':e['textLayerEmpty'],'ocrMs':e.get('ocrMs')})
report={'pages':rows,'ocrCER':sum(x['editDistance'] for x in rows if x['scan'])/sum(x['referenceCharacters'] for x in rows if x['scan']),'layerCER':sum(x['editDistance'] for x in rows if not x['scan'])/sum(x['referenceCharacters'] for x in rows if not x['scan']),'ocrFactsExact':sum(x['factExact'] for x in rows if x['scan']),'layerFactsExact':sum(x['factExact'] for x in rows if not x['scan']),'medianOCRMs':statistics.median(x['ocrMs'] for x in rows if x['scan'])}
(root/'ocr-results.json').write_text(json.dumps(report,indent=2))
print({k:v for k,v in report.items() if k!='pages'})
