const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const root=path.resolve(__dirname,'..'),out=path.join(root,'public');
const files=['index.html','farm-app.js','farm-database.js','schedule-core.js','supabase-config.js'];
for(const name of files.filter(f=>f.endsWith('.js')))new vm.Script(fs.readFileSync(path.join(root,name),'utf8'),{filename:name});
const html=fs.readFileSync(path.join(root,'index.html'),'utf8');const ids=[...html.matchAll(/\bid="([^"]+)"/g)].map(m=>m[1]);if(new Set(ids).size!==ids.length)throw Error('Duplicate HTML IDs');
if(/localStorage/.test(fs.readFileSync(path.join(root,'farm-app.js'),'utf8')))throw Error('Operational app still depends on localStorage');
fs.mkdirSync(out,{recursive:true});for(const name of files)fs.copyFileSync(path.join(root,name),path.join(out,name));
console.log('Validated app scripts and copied only public assets.');
