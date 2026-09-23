// Run with PGLITE_MODULE pointing to @electric-sql/pglite (or install it locally).
// Uses real PostgreSQL in memory; never connects to a live farm.
const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..');
async function setup(){
 const db=new PGlite();
 await db.exec(`create role anon;create role authenticated;create schema auth;
 create table auth.users(id uuid primary key,email text);
 create function auth.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
 create function auth.uid() returns uuid language sql stable as $$ select (auth.jwt()->>'sub')::uuid $$;
 grant usage on schema public,auth to anon,authenticated;
 grant execute on all functions in schema auth to anon,authenticated;`);
 for(const file of ['20260921170618_green_peas_persistence_schedule.sql','20260921174104_farm_assistant_confirmed_actions.sql','20260922174606_green_peas_login_free_access.sql'])await db.exec(fs.readFileSync(path.join(root,'supabase/migrations',file),'utf8'));
 await db.exec(fs.readFileSync(path.join(root,'supabase/migrations/20260923230000_crop_harvest_inventory.sql'),'utf8'));
 return db;
}
module.exports={setup};
async function main(){
 const db=await setup();
 try{
  const before=(await db.query('select count(*)::int n from farms')).rows[0].n;
  for(const file of ['harvest-rollback.sql','temporary-access-rollback.sql']){
   await db.exec(fs.readFileSync(path.join(__dirname,file),'utf8'));console.log('PASS: '+file);
  }
  console.log('PASS: PostgreSQL harvest, inventory, assignment, retry, lifecycle, rollback and permission checks.');
  assert.equal((await db.query("select count(*)::int n from farms")).rows[0].n,before);
 }finally{await db.close();}
}
if(require.main===module)main().catch(e=>{console.error(e.message,e.where||'');process.exitCode=1;});
