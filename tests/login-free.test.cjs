const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const {handle,propose}=require('../server/farm-assistant.cjs');

test('Database reads and writes need neither browser storage nor a user token',async()=>{
 const calls=[],window={FARM_SUPABASE:{url:'https://fixture.invalid',publishableKey:'fixture-public-key'}};
 const context=vm.createContext({window,fetch:async(url,options)=>{calls.push({url,options});return {ok:true,text:async()=>JSON.stringify([{id:'fixture'}])};}});
 vm.runInContext(fs.readFileSync('farm-database.js','utf8'),context);
 await window.FarmDatabase.rows('tasks');await window.FarmDatabase.insert('inventory',{item:'Test-only fixture',qty:null});await window.FarmDatabase.rpc('set_task_status',{p_task_id:'fixture',p_status:'Completed'});
 assert.equal(calls.length,3);assert(calls.every(c=>!c.url.includes('/auth/')));assert(calls.every(c=>c.options.headers.apikey==='fixture-public-key'&&!('Authorization' in c.options.headers)));
 assert.equal(window.FarmDatabase.hasSession,undefined);assert.equal(window.FarmDatabase.signOut,undefined);
});

test('App startup loads directly and the sign-in UI is absent',()=>{
 const html=fs.readFileSync('index.html','utf8'),app=fs.readFileSync('farm-app.js','utf8');
 assert.doesNotMatch(html,/authPanel|authForm|authEmail|authCode|signOut|Sign in to/);
 assert.doesNotMatch(app,/hasSession|api\.token|authSend|authForm|signOut/);
 assert.match(app,/refresh\(\{initial:true\}\)\.catch/);
 for(const section of ['tasks','schedule','coop','eggs','marketplace','breakfast','inventory','planting','assistant'])assert(html.includes('id="'+section+'"'));
});

const response=()=>({statusCode:200,setHeader(){},status(code){this.statusCode=code;return this;},json(body){this.body=body;return this;}});
test('Assistant confirms or cancels through the existing atomic RPC without a session',async t=>{
 const calls=[];t.mock.method(global,'fetch',async(url,options)=>{calls.push({url,options});return {ok:true,text:async()=>JSON.stringify(url.includes('/rpc/')?'Cancelled':[{id:'11111111-1111-4111-8111-111111111111'}])};});
 const res=response();await handle({method:'POST',headers:{host:'localhost'},body:{operation:'decide',action_id:'22222222-2222-4222-8222-222222222222',confirm:false}},res);
 assert.equal(res.statusCode,200);assert.equal(res.body.status,'Cancelled');assert.equal(calls.length,2);assert(calls[1].url.endsWith('/rpc/decide_ai_action'));assert.equal(JSON.parse(calls[1].options.body).p_confirm,false);assert(calls.every(c=>!c.options.headers.Authorization));
});

test('Assistant proposal still saves only a pending action, without performing its mutation',async()=>{
 const calls=[];const ctx={farm:{id:'farm'},conversationId:'conversation',proposals:[],db:async(path,options)=>{calls.push({path,options});return [{id:'proposal',status:'Pending'}];}};
 const result=await propose('create_task',{title:'Test-only fixture'},ctx);
 assert.equal(calls.length,1);assert.equal(calls[0].path,'ai_actions');assert.equal(result.status,'Pending confirmation');assert.equal(ctx.proposals.length,1);
});

test('Assistant retains same-origin protection without requiring sign-in',async()=>{
 const res=response();await handle({method:'POST',headers:{host:'farm.example',origin:'https://different.example'},body:{}},res);assert.equal(res.statusCode,403);assert.equal(res.body.error,'Origin rejected');
});
