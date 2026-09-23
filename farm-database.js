// Supabase is the source of truth. Farm OS uses the project's public access policies.
window.FarmDatabase=(()=>{
 const config=window.FARM_SUPABASE;
 async function request(path,{method='GET',body,prefer='return=representation',range}={}){
  const headers={apikey:config.publishableKey,'Content-Type':'application/json',Prefer:prefer};if(range)headers.Range=range;
  const res=await fetch(config.url+'/rest/v1/'+path,{method,headers,body:body===undefined?undefined:JSON.stringify(body)});
  const raw=await res.text();let data;try{data=raw?JSON.parse(raw):null;}catch{throw Error('Unexpected response from Supabase');}
  if(!res.ok){const error=Error(data?.message||`Supabase request failed (${res.status})`);error.status=res.status;throw error;}return data;
 }
 async function all(table,filter=''){let out=[];const order=table==='task_occurrences'?'task_id.asc,occurrence_date.asc':table==='farm_members'?'email.asc':'id.asc';for(let offset=0;;offset+=1000){const rows=await request(table+'?select=*'+filter+'&order='+order+'&offset='+offset+'&limit=1000');out.push(...rows);if(rows.length<1000)return out;}}
 const rows=all;
 async function insert(table,data,options=''){return request(table+options,{method:'POST',body:data});}
 async function update(table,row,data){const result=await request(table+'?id=eq.'+row.id+(row.updated_at?'&updated_at=eq.'+encodeURIComponent(row.updated_at):''),{method:'PATCH',body:data});if(!result?.length)throw Error('This record changed on another device. Refresh and review it before saving again.');return result;}
 const rpc=(name,body)=>request('rpc/'+name,{method:'POST',body});
 return {rows,request,insert,update,rpc,
  async importLegacy(farmId){
   // One-time migration input only; never read or write operational state here after import.
   const raw=localStorage.getItem('green_peas_confirmed_v4');if(!raw)return;
   const payload=JSON.parse(raw);if(payload.version!==4)throw Error('Prior browser data needs review before import.');
   await rpc('import_legacy_farm',{p_farm_id:farmId,p_payload:payload});
   // The untouched browser copy remains a recovery backup; the database tracks the import fingerprint.
  }
 };
})();
