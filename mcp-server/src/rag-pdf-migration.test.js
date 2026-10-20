import test from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {readFileSync,readdirSync} from 'node:fs';
import {unstable_splitSqlQuery} from 'wrangler';

test('PDF migrations survive the deployed toolchain SQL splitter including CASE inside triggers',()=>{
 const db=new DatabaseSync(':memory:');
 try{
  const directory=new URL('../migrations/',import.meta.url);
  for(const name of readdirSync(directory).filter(n=>/^00(?:0[1-9]|1[0-7])_.*\.sql$/u.test(n)).sort())
   for(const statement of unstable_splitSqlQuery(readFileSync(new URL(name,directory),'utf8')))db.exec(statement);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM sqlite_master WHERE type='trigger' AND name LIKE 'rag_raw_pdf_%'").get().n,3);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM sqlite_master WHERE type='table' AND name='rag_pdf_job_recovery'").get().n,1);
  assert.equal(db.prepare('SELECT physical_purge_enabled FROM rag_pdf_retention_control').get().physical_purge_enabled,0);
 }finally{db.close();}
});
