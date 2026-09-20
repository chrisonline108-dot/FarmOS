// Supabase is the source of truth. Only the authentication session is held in sessionStorage.
window.FarmDatabase=(()=>{
 const config=window.FARM_SUPABASE;let session=null;let refreshPromise=null;
 const sessionKey='green_peas_auth_session';
 try{session=JSON.parse(sessionStorage.getItem(sessionKey)||'null');}catch{}
 function store(value){session=value;if(value)sessionStorage.setItem(sessionKey,JSON.stringify(value));else sessionStorage.removeItem(sessionKey);}
 async function auth(path,body){
  if(!config.publishableKey)throw Error('Supabase publishable key has not been configured.');
  const res=await fetch(config.url+'/auth/v1/'+path,{method:'POST',headers:{apikey:config.publishableKey,'Content-Type':'application/json'},body:JSON.stringify(body)});
  const data=await res.json();if(!res.ok)throw Error(data.msg||data.message||data.error_description||'Sign-in failed');
  if(data.access_token)store({...data,expires_at:Math.floor(Date.now()/1000)+data.expires_in});return data;
 }
 async function token(){
  if(!session)throw Error('Sign in to access farm data.');
  if(session.expires_at<Date.now()/1000+60){refreshPromise??=auth('token?grant_type=refresh_token',{refresh_token:session.refresh_token}).finally(()=>{refreshPromise=null;});await refreshPromise;}
  return session.access_token;
 }
 async function request(path,{method='GET',body,prefer='return=representation',range}={}){
  const access=await token();const headers={apikey:config.publishableKey,Authorization:'Bearer '+access,'Content-Type':'application/json',Prefer:prefer};if(range)headers.Range=range;
  const res=await fetch(config.url+'/rest/v1/'+path,{method,headers,body:body===undefined?undefined:JSON.stringify(body)});
  const raw=await res.text();let data;try{data=raw?JSON.parse(raw):null;}catch{throw Error('Unexpected response from Supabase');}
  if(!res.ok)throw Error(data?.message||`Supabase request failed (${res.status})`);return data;
 }
 async function all(table,filter=''){let out=[];for(let offset=0;;offset+=1000){const rows=await request(table+'?select=*'+filter+'&order=id.asc&offset='+offset+'&limit=1000');out.push(...rows);if(rows.length<1000)return out;}}
 async function rows(table,filter=''){if(table==='task_occurrences')return request(table+'?select=*'+filter+'&order=occurrence_date.asc&limit=10000');return all(table,filter);}
 async function insert(table,data,options=''){return request(table+options,{method:'POST',body:data});}
 async function update(table,row,data){const result=await request(table+'?id=eq.'+row.id+(row.updated_at?'&updated_at=eq.'+encodeURIComponent(row.updated_at):''),{method:'PATCH',body:data});if(!result?.length)throw Error('This record changed on another device. Refresh and review it before saving again.');return result;}
 const rpc=(name,body)=>request('rpc/'+name,{method:'POST',body});
 return {rows,request,insert,update,rpc,hasSession:()=>!!session,email:()=>session?.user?.email,
  sendCode:email=>auth('otp',{email,create_user:true}),
  async verifyCode(email,input){let body={email,token:input,type:'email'};try{const url=new URL(input);const hash=url.searchParams.get('token_hash')||url.searchParams.get('token');if(hash)body={token_hash:hash,type:url.searchParams.get('type')||'magiclink'};}catch{}return auth('verify',body);},
  password:(email,password)=>auth('token?grant_type=password',{email,password}),
  async signOut(){try{if(session)await fetch(config.url+'/auth/v1/logout',{method:'POST',headers:{apikey:config.publishableKey,Authorization:'Bearer '+session.access_token}});}finally{store(null);}},
  async importLegacy(farmId){
   // One-time migration input only; never read or write operational state here after import.
   const raw=localStorage.getItem('green_peas_confirmed_v4');if(!raw)return;
   const payload=JSON.parse(raw);if(payload.version!==4)throw Error('Prior browser data needs review before import.');
   await rpc('import_legacy_farm',{p_farm_id:farmId,p_payload:payload});
   // The untouched browser copy remains a recovery backup; the database tracks the import fingerprint.
  }
 };
})();
