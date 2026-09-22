(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const display = value => value === null || value === undefined || value === '' ? 'Not recorded yet' : escape(value);
  const dateKey = d => `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
  const today = () => dateKey(new Date());
  const dateObject = s => new Date(s+'T12:00:00');
  const fmt = s => s ? dateObject(s).toLocaleDateString(undefined,{year:'numeric',month:'short',day:'numeric'}) : 'TBC';
  const COOPS = ['Chicken Coop A','Chicken Coop B'];
  const CLEAN = {mini:'Daily mini cleaning',normal:'Weekly normal cleaning',deep:'Monthly deep cleaning'};
  const api=window.FarmDatabase;
  const schedule=window.FarmSchedule;
  let tables={}, farm=null, loaded=false, saving=false, loading=false;
  let state={workers:[],tasks:[],crops:[],inventory:[],plans:[],birds:{},records:{},cleaning:[]};
  function notice(message) { $('storageNotice').hidden=!message; $('storageNotice').textContent=message; }
  function toast(message) { $('toast').textContent=message; $('toast').classList.add('show');setTimeout(()=>$('toast').classList.remove('show'),3500); }
  const byId=(table,id)=>tables[table]?.find(x=>x.id===id);
  const workerName=id=>byId('workers',id)?.name??null;
  const areaName=id=>byId('areas',id)?.name??null;
  const bedName=id=>byId('beds',id)?.code??null;
  const cropName=id=>byId('crops',id)?.name??null;
  function projectState(){
   state.workers=tables.workers.filter(x=>!x.archived);
   state.tasks=tables.tasks.map(t=>({...t,owner:workerName(t.worker_id),time:t.start_time?.slice(0,5)??null,done:schedule.status(t,today(),tables.task_occurrences)==='Completed'}));
   state.crops=tables.plantings.map(p=>({...p,name:cropName(p.crop_id),location:bedName(p.bed_id),planted:p.planted_on}));
   state.inventory=tables.inventory;
   state.plans=tables.planting_plans.map(p=>({...p,crop:cropName(p.crop_id),area:bedName(p.bed_id)||areaName(p.area_id),date:p.planned_on}));
   state.birds=Object.fromEntries(tables.coops.map(c=>[c.name,c.bird_count]));state.records={};
   for(const r of tables.coop_daily_records){const name=byId('coops',r.coop_id)?.name;if(!name)continue;state.records[r.record_date]??={};state.records[r.record_date][name]={...r,worker:workerName(r.worker_id)||r.worker_note};}
   state.cleaning=tables.coop_cleaning.map(c=>({...c,coop:byId('coops',c.coop_id)?.name,date:c.cleaning_date,next:c.next_due,worker:workerName(c.worker_id)||c.worker_note,savedAt:c.created_at}));
  }
  async function refresh({initial=false}={}){
   if(loading)return;loading=true;
   try{
    {const farms=await api.rows('farms','&slug=eq.green-peas');farm=farms[0];if(!farm)throw Error('Green Peas data is unavailable. Check the connection and use Refresh to try again.');}
    if(initial){try{await api.importLegacy(farm.id);}catch(e){notice('Prior data has not been imported: '+e.message);throw e;}}
    const names=['areas','beds','workers','coops','crops','plantings','planting_plans','tasks','task_occurrences','coop_daily_records','coop_cleaning','inventory','harvest_records','farm_records','task_assignees','crop_stage_history','chicken_count_history','farm_seasons','marketplace_products','marketplace_transactions','breakfast_items','breakfast_ingredients','breakfast_records','inventory_transactions'];
    const results=await Promise.all(names.map(async name=>[name,await api.rows(name,'&farm_id=eq.'+farm.id)]));
    tables=Object.fromEntries(results);projectState();loaded=true;$('syncStatus').textContent='Saved in Supabase';
    document.querySelectorAll('.view form button[type=submit]').forEach(b=>b.disabled=false);
    renderAllViews();if(initial){loadRecord();$('birdsA').value=state.birds[COOPS[0]]??'';$('birdsB').value=state.birds[COOPS[1]]??'';}
    notice('');
   }catch(e){notice(e.message);$('syncStatus').textContent='Not synced';throw e;}finally{loading=false;}
  }
  async function ensureCrop(name){const existing=tables.crops.find(c=>c.name===name);if(existing)return existing.id;const rows=await api.request('crops?on_conflict=farm_id,name',{method:'POST',body:{farm_id:farm.id,name},prefer:'resolution=merge-duplicates,return=representation'});return rows[0].id;}
  const workerId=name=>tables.workers.find(w=>w.name===name)?.id??null;
  const bedId=code=>tables.beds.find(b=>b.code===code)?.id??null;
  async function writeArray(before,after,table,mapper,{remove}={}){
   for(const row of after){const old=before.find(x=>x.id&&x.id===row.id);if(old&&JSON.stringify(old)===JSON.stringify(row))continue;const payload=await mapper(row,old);if(old)await api.update(table,old,payload);else await api.insert(table,{farm_id:farm.id,...payload});}
   for(const old of before)if(old.id&&!after.some(x=>x.id===old.id)){if(remove)await remove(old);else await api.request(table+'?id=eq.'+old.id,{method:'DELETE'});}
  }
  async function change(fn){
   if(!loaded){toast('Farm data is still loading. Please try again.');return false;}
   if(saving){toast('A save is in progress.');return false;}saving=true;
   const before=structuredClone(state),next=structuredClone(state);fn(next);
   try{
    await writeArray(before.workers,next.workers,'workers',w=>({name:w.name,role:w.role,phone:w.phone||null}),{remove:w=>api.update('workers',w,{archived:true})});
    for(const task of next.tasks){const old=before.tasks.find(x=>x.id&&x.id===task.id);if(!old)await api.rpc('save_scheduled_task',{p_farm_id:farm.id,p_id:null,p_data:{title:task.title,assignee_ids:task.assignee_ids,start_time:task.time,scheduled_date:task.scheduled_date||null,priority:task.priority,recurrence:'One-time'},p_status:'Open'});else if(task.done!==old.done)await api.rpc('set_task_status',{p_task_id:task.id,p_date:today(),p_status:task.done?'Completed':'Open'});}
    for(const task of before.tasks)if(!next.tasks.some(t=>t.id===task.id))await api.request('tasks?id=eq.'+task.id,{method:'DELETE'});
    await writeArray(before.crops,next.crops,'plantings',async c=>({crop_id:await ensureCrop(c.name),bed_id:bedId(c.location),area_id:byId('beds',bedId(c.location))?.area_id??null,planted_on:c.planted||null,stage:c.stage,nursery_start_on:c.nursery_start_on||null,transplant_on:c.transplant_on||null,expected_harvest_on:c.expected_harvest_on||null}));
    await writeArray(before.inventory,next.inventory,'inventory',x=>({item:x.item,category:x.category,qty:x.qty,min:x.min}));
    await writeArray(before.plans,next.plans,'planting_plans',async p=>{const [kind,id]=(p.selection||'').split(':');return {crop_id:await ensureCrop(p.crop),bed_id:kind==='bed'?id:p.bed_id||null,area_id:kind==='bed'?byId('beds',id)?.area_id:kind==='area'?id:p.area_id||null,planned_on:p.date,notes:p.notes||null};});
    if(JSON.stringify(before.birds)!==JSON.stringify(next.birds))await api.rpc('set_coop_counts',{p_farm_id:farm.id,p_a:next.birds[COOPS[0]],p_b:next.birds[COOPS[1]]});
    for(const [date,coops] of Object.entries(next.records))for(const [name,r] of Object.entries(coops)){
     const old=before.records[date]?.[name];if(JSON.stringify(old)===JSON.stringify(r))continue;
     const payload={coop_id:tables.coops.find(c=>c.name===name).id,record_date:date,worker_id:workerId(r.worker),worker_note:r.worker||null};
     for(const [field] of fields)if(field!=='worker')payload[field]=r[field]??null;
     if(old)await api.update('coop_daily_records',old,payload);else await api.insert('coop_daily_records',{farm_id:farm.id,...payload});
    }
    for(const c of next.cleaning)if(!c.id)await api.insert('coop_cleaning',{farm_id:farm.id,coop_id:tables.coops.find(x=>x.name===c.coop).id,type:c.type,cleaning_date:c.date,completion:c.completion,next_due:c.next,worker_id:workerId(c.worker),worker_note:c.worker,notes:c.notes});
    await refresh();return true;
   }catch(e){notice('Not saved: '+e.message);toast('Save failed; your form is unchanged.');return false;}finally{saving=false;}
  }
  const eggFields=[['morning','Morning eggs'],['evening','Evening eggs'],['total','Eggs collected'],['saleable','Saleable eggs'],['broken','Broken / dirty eggs'],['cafe','Café use'],['sold','Eggs sold'],['stock','Remaining egg stock']];
  const healthFields=[['feed','Feed used (kg)'],['water','Water check','select'],['sick','Sick / injured birds'],['mortality','Mortality'],['treatment','Treatments / medication','text'],['behaviour','Unusual behaviour','text']];
  const noteFields=[['worker','Worker responsible','text'],['notes','Notes','text']];
  const fields=[...eggFields,...healthFields,...noteFields];
  const numeric=fields.filter(f=>!f[2]).map(f=>f[0]);
  function fieldMarkup([id,label,type]) {
    const control=type==='text'?`<textarea id="rec_${id}" placeholder="Not recorded yet"></textarea>`:type==='select'?`<select id="rec_${id}"><option value="">Not recorded yet</option><option>Checked — OK</option><option>Checked — issue found</option><option>Not checked</option></select>`:`<input id="rec_${id}" type="number" min="0" step="${id==='feed'?'any':'1'}" placeholder="Not recorded yet">`;
    return `<label>${label}${control}</label>`;
  }
  $('eggFields').innerHTML=eggFields.map(fieldMarkup).join('');
  $('healthFields').innerHTML=healthFields.map(fieldMarkup).join('');
  $('noteFields').innerHTML=noteFields.map(fieldMarkup).join('');
  $('recordDate').value=today();$('cleanDate').value=today();$('summaryDate').value=today();
  $('todayLabel').textContent=fmt(today());
  const record = (date,coop) => state.records[date]?.[coop];
  const currentCoop = () => $('activeCoop').value;
  const numberValue = id => $(id).value==='' ? null : Number($(id).value);
  function combined(date,field) {
    const values=COOPS.map(coop=>record(date,coop)?.[field]);
    const entered=values.filter(v=>typeof v==='number');
    if(!entered.length)return 'Not recorded yet';
    const total=entered.reduce((a,b)=>a+b,0);
    return entered.length===2?String(total):`${total} recorded · partial; ${values[0]==null?'Coop A':'Coop B'}: Not recorded yet`;
  }
  function describe(rec) {return '<dl class="record-grid">'+fields.map(([field,label])=>`<div><dt>${label}</dt><dd>${display(rec[field])}</dd></div>`).join('')+'</dl>';}
  function loadRecord() {
    const rec=record($('recordDate').value,currentCoop());
    fields.forEach(([field])=>{$('rec_'+field).value=rec?.[field]??'';});
    $('recordStatus').textContent=rec?'Saved record loaded. Saving updates this coop and date.':'Not recorded yet';
    $('cleanForm').reset();$('cleanDate').value=$('recordDate').value;
    renderCleaning();renderDailyHistory();
  }
  function renderDailyHistory() {
    $('dailyHistoryCoop').textContent=currentCoop();
    const dates=Object.keys(state.records).filter(date=>record(date,currentCoop())).sort().reverse();
    $('dailyHistory').innerHTML=dates.length?dates.map(date=>`<details><summary>${fmt(date)} · ${display(record(date,currentCoop()).total)} eggs collected</summary>${describe(record(date,currentCoop()))}<button type="button" class="btn" data-edit-date="${date}">Edit this record</button></details>`).join(''):'<p class="meta">Not recorded yet</p>';
  }
  function latestCleaning(coop,type) {return state.cleaning.filter(r=>r.coop===coop&&r.type===type).sort((a,b)=>b.date.localeCompare(a.date)||b.savedAt.localeCompare(a.savedAt))[0];}
  function cleaningStatus(rec) {return !rec?'Not recorded yet':!rec.next?'Next due: TBC':rec.next<=today()?'Due':'Next due: '+fmt(rec.next);}
  function renderCleaning() {
    $('historyCoop').textContent=currentCoop();
    $('cleanCards').innerHTML=Object.entries(CLEAN).map(([type,name])=>{const rec=latestCleaning(currentCoop(),type);return `<div class="clean"><b>${name}</b><p class="status">${cleaningStatus(rec)}</p><dl><dt>Completion</dt><dd>${display(rec?.completion)}</dd><dt>Cleaning date</dt><dd>${rec?fmt(rec.date):'Not recorded yet'}</dd><dt>Worker responsible</dt><dd>${display(rec?.worker)}</dd><dt>Next cleaning due</dt><dd>${rec?.next?fmt(rec.next):'TBC'}</dd></dl></div>`;}).join('');
    const history=state.cleaning.filter(r=>r.coop===currentCoop()).sort((a,b)=>b.date.localeCompare(a.date)||b.savedAt.localeCompare(a.savedAt));
    $('cleanHistory').innerHTML=history.length?history.map(r=>`<details><summary>${fmt(r.date)} · ${CLEAN[r.type]} · ${escape(r.completion)}</summary><dl><dt>Worker responsible</dt><dd>${display(r.worker)}</dd><dt>Next cleaning due</dt><dd>${fmt(r.next)}</dd><dt>Notes</dt><dd>${display(r.notes)}</dd></dl></details>`).join(''):'<p class="meta">Not recorded yet</p>';
    let known=0,due=0;
    $('homeCleaning').innerHTML=COOPS.map(coop=>{let count=0,missing=0;Object.keys(CLEAN).forEach(type=>{const rec=latestCleaning(coop,type);if(rec?.next){known++;if(rec.next<=today()){count++;due++;}}else missing++;});return `<div class="row"><div><b>${coop}</b><div class="meta">${count} recorded due · ${missing?missing+' schedules TBC':'All schedules recorded'}</div></div></div>`;}).join('');
    $('kpiClean').textContent=known===0?'TBC':known<6?`${due} · partial`:due;
  }
  function renderEggs() {
    $('kpiEggs').textContent=combined(today(),'total');
    $('eggSummary').innerHTML=eggFields.map(([field,label])=>`<div class="clean"><div class="meta">${label}</div><p><b>${combined($('summaryDate').value,field)}</b></p></div>`).join('');
    const date=$('summaryDate').value;
    $('eggHistory').innerHTML=COOPS.map(coop=>`<details open><summary>${coop} · ${fmt(date)}</summary>${record(date,coop)?describe(record(date,coop)):'<p>Not recorded yet</p>'}</details>`).join('');
  }
  function renderBirds() { document.querySelectorAll('.birdSplit').forEach(el=>{el.textContent=COOPS.map(coop=>coop+': '+(state.birds[coop]??'TBC')).join(' · ');}); }
  $('birdForm').addEventListener('submit',async e=>{
    e.preventDefault();const a=numberValue('birdsA'),b=numberValue('birdsB');
    if([a,b].some(n=>n!==null&&(!Number.isInteger(n)||n<0))){toast('Observed counts must be non-negative whole numbers.');return;}
    if(await change(s=>{s.birds={[COOPS[0]]:a,[COOPS[1]]:b};})){renderBirds();toast('Observed counts saved');}
  });
  $('birdsA').value=state.birds[COOPS[0]]??'';$('birdsB').value=state.birds[COOPS[1]]??'';
  $('dailyRecordForm').addEventListener('submit',async e=>{
    e.preventDefault();const date=$('recordDate').value,coop=currentCoop();
    if(!date||date>today()){toast('Choose an actual record date, today or earlier.');return;}
    const rec=Object.fromEntries(fields.map(([field,type])=>[field,numeric.includes(field)?numberValue('rec_'+field):$('rec_'+field).value.trim()||null]));
    if(numeric.some(field=>rec[field]!==null&&(!Number.isFinite(rec[field])||rec[field]<0||(field!=='feed'&&!Number.isInteger(rec[field]))))){toast('Enter non-negative quantities and whole egg / bird counts.');return;}
    if(rec.morning!==null&&rec.evening!==null){const total=rec.morning+rec.evening;if(rec.total!==null&&rec.total!==total){toast('Eggs collected must equal morning plus evening eggs.');return;}rec.total=total;}
    if(rec.total!==null&&((rec.morning??0)+(rec.evening??0)>rec.total||(rec.saleable??0)+(rec.broken??0)>rec.total)){toast('Collection or grading counts exceed eggs collected.');return;}
    if(rec.total!==null&&rec.saleable!==null&&rec.broken!==null&&rec.saleable+rec.broken!==rec.total){toast('Saleable plus broken / dirty eggs must equal eggs collected.');return;}
    if(fields.every(([field])=>rec[field]===null)){toast('Enter at least one observation before saving.');return;}
    if(await change(s=>{s.records[date]??={};s.records[date][coop]=rec;})){loadRecord();renderEggs();toast(coop+' daily record saved');}
  });
  function nextDate(date,type){const d=dateObject(date);if(type==='deep'){const day=d.getDate();d.setMonth(d.getMonth()+1,1);const last=new Date(d.getFullYear(),d.getMonth()+1,0).getDate();d.setDate(Math.min(day,last));}else d.setDate(d.getDate()+(type==='mini'?1:7));return dateKey(d);}
  $('cleanForm').addEventListener('submit',async e=>{
    e.preventDefault();const type=$('cleanType').value,date=$('cleanDate').value,completion=$('cleanCompletion').value;
    if(!date||date>today()||!completion){toast('Enter a cleaning date today or earlier and completion status.');return;}
    const next=$('cleanNext').value||(completion==='Completed'?nextDate(date,type):null);
    if(next&&next<date){toast('Next cleaning due cannot be before the cleaning date.');return;}
    const rec={coop:currentCoop(),type,date,completion,next,worker:$('cleanWorker').value.trim()||null,notes:$('cleanNotes').value.trim()||null,savedAt:new Date().toISOString()};
    if(await change(s=>s.cleaning.push(rec))){$('cleanForm').reset();$('cleanDate').value=$('recordDate').value;renderCleaning();toast('Cleaning record saved for '+rec.coop);}
  });
  $('activeCoop').addEventListener('change',loadRecord);$('recordDate').addEventListener('change',loadRecord);$('summaryDate').addEventListener('change',renderEggs);
  function renderOther() {
    const empty='<p class="meta">Not recorded yet</p>';
    $('workerList').innerHTML=state.workers.map((w,i)=>`<div class="row"><div style="flex:1"><b>${escape(w.name)}</b><div class="meta">${display(w.role)} ${escape(w.phone)}</div></div><button class="btn danger" data-del-worker="${i}">Remove</button></div>`).join('')||empty;
    const taskMarkup=(t,i,controls)=>`<div class="row">${controls?`<input type="checkbox" aria-label="Complete ${escape(t.title)}" data-check="${i}" ${t.done?'checked':''} style="width:20px">`:''}<div style="flex:1"><b>${escape(t.title)}</b><div class="meta">${display(t.owner)} · ${display(t.time)} · ${t.done?'Completed':'Open'}</div></div>${controls?`<button class="btn danger" data-del-task="${i}">Remove</button>`:''}</div>`;
    $('taskList').innerHTML=state.tasks.map((t,i)=>taskMarkup(t,i,true)).join('')||empty;$('homeTasks').innerHTML=state.tasks.slice(0,5).map((t,i)=>taskMarkup(t,i,false)).join('')||empty;
    $('kpiTasks').textContent=state.tasks.length?state.tasks.filter(t=>!t.done).length:'Not recorded yet';
    $('cropRows').innerHTML=state.crops.map((c,i)=>`<tr><td>${escape(c.name)}</td><td>${escape(c.location)}</td><td>${fmt(c.planted)}</td><td>${escape(c.stage)}</td><td><button class="btn" data-advance="${i}">Advance</button></td></tr>`).join('')||'<tr><td colspan="5">Not recorded yet</td></tr>';
    $('homeCrops').innerHTML=state.crops.slice(0,4).map(c=>`<div class="clean"><b>${escape(c.name)}</b><p>${escape(c.location)} · ${escape(c.stage)}</p></div>`).join('')||empty;
    $('kpiCrops').textContent=state.crops.length?state.crops.filter(c=>!['Planned','Finished'].includes(c.stage)).length:'Not recorded yet';
    $('invRows').innerHTML=state.inventory.map((x,i)=>`<tr><td>${escape(x.item)}</td><td>${escape(x.category)}</td><td>${x.qty??'TBC'}</td><td>${x.min??'TBC'}</td><td>${x.qty==null||x.min==null?'TBC':x.qty<x.min?'Low':'OK'}</td><td><button class="btn" data-count="${i}">Record count</button> <button class="btn" data-minus="${i}" ${x.qty==null?'disabled':''}>−</button> <button class="btn" data-plus="${i}" ${x.qty==null?'disabled':''}>+</button></td></tr>`).join('');
    $('planList').innerHTML=state.plans.map((p,i)=>`<div class="row"><div style="flex:1"><b>${escape(p.crop)} · ${escape(p.area)}</b><p class="meta">${fmt(p.date)} · ${display(p.notes)}</p></div><button class="btn danger" data-del-plan="${i}">Remove</button></div>`).join('')||empty;
  }
  document.addEventListener('click',async e=>{
    const link=e.target.closest('[data-open-coop]');if(link){$('activeCoop').value=link.dataset.openCoop;loadRecord();}
    const b=e.target.closest('button');if(!b)return;
    if(b.dataset.editDate){$('recordDate').value=b.dataset.editDate;loadRecord();$('recordDate').scrollIntoView({behavior:'smooth'});return;}
    for(const [attr,list] of [['delWorker','workers'],['delTask','tasks'],['delPlan','plans']])if(b.dataset[attr]!==undefined){if(confirm('Remove this record?')&&await change(s=>s[list].splice(Number(b.dataset[attr]),1)))renderAllViews();return;}
    if(b.dataset.count!==undefined){const i=+b.dataset.count,input=prompt('Enter the observed inventory quantity. Leave blank to keep TBC.',state.inventory[i].qty??'');if(input===null||input.trim()==='')return;const qty=Number(input);if(!Number.isFinite(qty)||qty<0){toast('Enter a non-negative quantity');return;}if(await change(s=>s.inventory[i].qty=qty))renderAllViews();}
    for(const action of ['minus','plus'])if(b.dataset[action]!==undefined){const i=+b.dataset[action];if(state.inventory[i].qty==null)return;await perform(()=>api.rpc('adjust_inventory',{p_id:state.inventory[i].id,p_delta:action==='plus'?1:-1}),'Inventory updated');}
  });
  document.addEventListener('change',async e=>{if(e.target.dataset.check!==undefined&&await change(s=>s.tasks[+e.target.dataset.check].done=e.target.checked))renderAllViews();});
  function submit(id,fn){$(id).addEventListener('submit',async e=>{e.preventDefault();if(await change(fn)){e.target.reset();renderAllViews();toast('Saved');}});}
  submit('taskForm',s=>s.tasks.push({title:$('taskTitle').value.trim(),assignee_ids:selectedIds('taskOwner'),scheduled_date:$('taskDate').value||null,priority:$('taskPriority').value,time:$('taskTime').value||null,done:false}));
  submit('cropForm',s=>s.crops.push({name:$('cropName').value.trim(),location:$('cropLocation').value,planted:$('cropDate').value||null,expected_harvest_on:$('cropExpected').value||null,nursery_start_on:$('cropNursery').value||null,transplant_on:$('cropTransplant').value||null,stage:$('cropStage').value}));
  submit('workerForm',s=>s.workers.push({name:$('workerName').value.trim(),role:$('workerRole').value.trim(),phone:$('workerPhone').value.trim()}));
  submit('invForm',s=>s.inventory.push({item:$('invItem').value.trim(),category:$('invCategory').value,qty:numberValue('invQty'),min:numberValue('invMin')}));
  submit('planForm',s=>s.plans.push({crop:$('planCrop').value.trim(),selection:$('planArea').value,date:$('planDate').value,notes:$('planNotes').value.trim()}));
  let scheduleMode='Week',scheduleAnchor=today(),scheduleItems=[];
  const ordered=rows=>[...rows].sort((a,b)=>(a.code||a.name||'').localeCompare(b.code||b.name||'',undefined,{numeric:true}));
  function options(id,rows,label,placeholder){const el=$(id),selected=el.multiple?Array.from(el.selectedOptions).map(o=>o.value):[el.value];el.innerHTML=(el.multiple?'':'<option value="">'+placeholder+'</option>')+rows.map(r=>'<option value="'+r.id+'">'+escape(r[label])+'</option>').join('');Array.from(el.options).forEach(o=>o.selected=selected.includes(o.value));}
  function bedOptions(ids=false){return ordered(tables.areas.filter(a=>a.kind==='production')).map(a=>`<optgroup label="${escape(a.name+' · '+a.classification)}">${ordered(tables.beds.filter(b=>b.area_id===a.id)).map(b=>`<option value="${ids?b.id:escape(b.code)}" ${b.purpose==='Reserve / Habitat'?'disabled':''}>${escape(b.code)}${b.purpose==='Reserve / Habitat'?' · Reserve / Habitat':''}</option>`).join('')}</optgroup>`).join('');}
  function renderPickers(){
   if(!loaded)return;
   for(const [id,ids] of [['cropLocation',false],['scheduleBed',true]]){const selected=$(id).value;$(id).innerHTML='<option value="">'+(ids?'Bed optional':'Choose bed')+'</option>'+bedOptions(ids);$(id).value=selected;}
   options('scheduleWorker',state.workers,'name','Worker TBC');options('scheduleArea',ordered(tables.areas),'name','Location TBC');options('scheduleCrop',ordered(tables.crops),'name','Crop optional');
   const selected=$('scheduleCoop').value;$('scheduleCoop').innerHTML='<option value="">Coop optional</option>'+ordered(tables.coops).map(c=>`<option value="${c.id}">${escape(c.name.replace('Chicken ',''))}</option>`).join('');$('scheduleCoop').value=selected;
   options('scheduleTask',tables.tasks,'title','New scheduled task');
   const areaSelected=$('planArea').value;$('planArea').innerHTML='<option value="">Choose bed / area</option><optgroup label="Beds">'+ordered(tables.beds).filter(b=>b.purpose==='Production').map(b=>`<option value="bed:${b.id}">${escape(b.code)}</option>`).join('')+'</optgroup><optgroup label="Areas / Facilities">'+ordered(tables.areas).map(a=>`<option value="area:${a.id}">${escape(a.name)}</option>`).join('')+'</optgroup>';$('planArea').value=areaSelected;
  }
  function renderAreasAndBeds(){
   if(!loaded)return;
   $('facilityCards').innerHTML=ordered(tables.areas.filter(a=>a.kind==='facility')).map(a=>`<div class="card facility"><h3>${escape(a.name)}</h3><div class="meta">Dimensions: ${a.dimensions?escape(a.dimensions):'TBC'} · Capacity: ${a.capacity??'TBC'} · Coordinates: ${a.coordinates?escape(JSON.stringify(a.coordinates)):'TBC'} · Layout: ${a.layout?escape(a.layout):'TBC'}</div><p>Details: ${display(a.notes)}</p>${tables.coops.some(c=>c.area_id===a.id)?`<a class="btn" href="#coop" data-open-coop="${escape(a.name)}">Open coop records</a>`:''}</div>`).join('');
   $('productionAreas').innerHTML=ordered(tables.areas.filter(a=>a.kind==='production')).map(a=>`<tr><td>${escape(a.name)}</td><td>${display(a.classification)}</td></tr>`).join('');
   $('bedRows').innerHTML=ordered(tables.areas.filter(a=>a.kind==='production')).map(a=>{const beds=ordered(tables.beds.filter(b=>b.area_id===a.id));const active=state.crops.filter(c=>beds.some(b=>b.id===c.bed_id)&&!['Planned','Finished'].includes(c.stage));const measured=beds.every(b=>b.length_m!==null&&b.width_m!==null);return `<tr><td><b>${escape(a.name)}</b></td><td>${beds.map(b=>escape(b.code)).join(', ')}</td><td>${display(a.classification)}</td><td>${beds.map(b=>b.length_m==null||b.width_m==null?'TBC':b.length_m+' × '+b.width_m+' m').join('; ')}</td><td>${measured?beds.reduce((sum,b)=>sum+Number(b.length_m)*Number(b.width_m),0).toFixed(1)+' m²':'TBC'}</td><td>${active.length?active.map(c=>escape(c.location+' · '+c.name)).join('<br>'):'Not recorded yet'}</td></tr>`;}).join('');
   const measured=tables.beds.every(b=>b.length_m!=null&&b.width_m!=null),net=measured?tables.beds.reduce((s,b)=>s+Number(b.length_m)*Number(b.width_m),0):null;
   const productive=measured?tables.beds.filter(b=>b.purpose==='Production').reduce((s,b)=>s+Number(b.length_m)*Number(b.width_m),0):null;
   const stats={net:net?.toFixed(1)+' m²',productive:productive?.toFixed(1)+' m²',beds:tables.beds.length,productionBeds:tables.beds.filter(b=>b.purpose==='Production').length,reserve:net===null?'TBC':(net-productive).toFixed(1)+' m²',chickens:farm.total_chickens??'TBC',property:farm.total_property_area==null?'TBC':farm.total_property_area+' m²'};
   document.querySelectorAll('[data-farm-stat]').forEach(el=>{el.textContent=stats[el.dataset.farmStat]??'TBC';});
  }
  function tasksForToday(){return tables.tasks.filter(t=>t.recurrence==='One-time'?!!t.scheduled_date&&t.scheduled_date<=today():schedule.occurs(t,today(),tables.farm_seasons));}
  function renderTaskViews(){
   if(!loaded)return;
   const active=state.tasks.filter(t=>t.recurrence==='One-time'||schedule.occurs(t,today(),tables.farm_seasons)||(!t.scheduled_date&&t.recurrence==='Monthly'));
   const row=(t,controls)=>{const index=state.tasks.findIndex(x=>x.id===t.id);const unknown=t.recurrence==='Monthly'&&!t.scheduled_date;return `<div class="row">${controls?`<input type="checkbox" aria-label="Complete ${escape(t.title)}" data-check="${index}" ${t.done?'checked':''} ${unknown?'disabled':''} style="width:20px">`:''}<div style="flex:1"><b>${escape(t.title)}</b><div class="meta">${chips(assignedNames(t.id))} · ${t.scheduled_date?fmt(t.scheduled_date):t.recurrence==='One-time'||unknown?'Date TBC':t.recurrence} · ${display(t.time)} · ${t.done?'Completed':'Open'}</div></div>${controls?`<button class="btn" data-schedule-task="${t.id}">Schedule</button><button class="btn danger" data-del-task="${index}">Remove</button>`:''}</div>`;};
   $('taskList').innerHTML=active.map(t=>row(t,true)).join('')||'<p class="meta">Not recorded yet</p>';
   const todays=tasksForToday().map(t=>state.tasks.find(s=>s.id===t.id));$('homeTasks').innerHTML=todays.slice(0,8).map(t=>row(t,false)).join('')||'<p class="meta">Not recorded yet</p>';
   $('kpiTasks').textContent=active.filter(t=>!t.done&&!((t.status||'')==='Cancelled')&&!(t.recurrence==='Monthly'&&!t.scheduled_date)).length;
   $('workerList').innerHTML=state.workers.map((w,i)=>{const assigned=todays.filter(t=>assignedIds(t.id).includes(w.id)),done=assigned.filter(t=>t.done).length;return `<div class="row"><div style="flex:1"><b>${escape(w.name)}</b><div class="meta">${display(w.role)} ${escape(w.phone)}</div><div class="meta">${assigned.length?done+' / '+assigned.length+' dated duties complete':'Progress: Not recorded yet'}</div></div><button class="btn danger" data-del-worker="${i}">Remove</button></div>`;}).join('');
  }
  function collectEvents(start,end){
   const events=schedule.taskEvents(tables.tasks,tables.task_occurrences,start,end,tables.farm_seasons);
   const add=e=>{if(e.date&&e.date>=start&&e.date<=end)events.push(e);};
   for(const p of tables.plantings){const dates=[['planted_on','Planting'],['nursery_start_on','Nursery'],['transplant_on','Transplant'],['expected_harvest_on','Expected harvest']];for(const [field,type] of dates)add({...p,id:'planting:'+p.id+':'+field,source:'planting',source_id:p.id,title:type+' · '+cropName(p.crop_id),event_type:type,date:p[field],status:field==='expected_harvest_on'?'Planned':'Recorded'});}
   for(const p of tables.planting_plans)add({...p,id:'plan:'+p.id,source:'plan',source_id:p.id,title:'Planting plan · '+cropName(p.crop_id),event_type:'Planting',date:p.planned_on,status:'Planned'});
   for(const c of tables.coops)for(const type of Object.keys(CLEAN)){const r=latestCleaning(c.name,type);if(r?.next)add({id:'cleaning:'+r.id,source:'cleaning',source_id:r.id,title:CLEAN[type]+' · '+c.name,event_type:'Cleaning',date:r.next,coop_id:c.id,worker_id:r.worker_id,status:'Due'});}
   for(const h of tables.harvest_records)add({...h,id:'harvest:'+h.id,source:'harvest',source_id:h.id,title:'Harvest · '+(cropName(h.crop_id)||'Crop TBC'),event_type:'Harvest',date:h.harvest_date,status:'Recorded'});
   for(const r of tables.farm_records)if(r.record_type!=='Legacy browser import')add({...r,id:'record:'+r.id,source:'record',source_id:r.id,title:r.details?.title||r.record_type,event_type:r.record_type,date:r.record_date,status:'Recorded'});
   return events.sort((a,b)=>a.date.localeCompare(b.date)||(a.start_time||'').localeCompare(b.start_time||'')||a.title.localeCompare(b.title));
  }
  function eventHTML(e){const places=[areaName(e.area_id),bedName(e.bed_id),cropName(e.crop_id),byId('coops',e.coop_id)?.name].filter(Boolean);return `<div class="schedule-event"><b>${escape(e.title)}</b><div class="meta">${e.start_time?escape(e.start_time.slice(0,5)):'Time TBC'}${e.end_time?' – '+escape(e.end_time.slice(0,5)):''} · ${escape(e.event_type)}</div><div class="meta">${e.source==='task'?chips(assignedNames(e.source_id)):display(workerName(e.worker_id))}${places.length?' · '+places.map(escape).join(' · '):''}</div><div class="meta">${escape(e.status)}</div>${e.source==='task'?`<label class="row"><input type="checkbox" style="width:20px" data-event-task="${e.source_id}" data-event-date="${e.date}" ${e.status==='Completed'?'checked':''}>Completed</label><button class="btn" data-schedule-task="${e.source_id}" data-schedule-date="${e.date}">Edit</button>`:e.source==='cleaning'?`<button class="btn" data-cleaning-event="${e.source_id}">Record cleaning</button>`:`<a class="btn" href="#${e.source==='plan'?'planting':e.source==='planting'?'crops':'farm'}">Open record</a>`}</div>`;}
  function renderSchedule(){
   document.querySelectorAll('[data-schedule-mode]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.scheduleMode===scheduleMode)));
   const period=schedule.range(scheduleMode,scheduleAnchor,byId('farm_seasons',$('scheduleSeasonView').value));if(!period){$('scheduleRange').textContent='Season dates TBC';$('scheduleCalendar').innerHTML='<p class="meta">Add or select a farm season to view its schedule.</p>';return;}const [start,end]=period;$('scheduleRange').textContent=start===end?fmt(start):fmt(start)+' – '+fmt(end);$('scheduleAnchor').value=scheduleAnchor;
   if(!loaded){$('scheduleCalendar').innerHTML='<p class="meta">Loading Schedule…</p>';return;}
   scheduleItems=collectEvents(start,end);const dates=[];for(let date=start;date<=end;date=schedule.plus(date,1))dates.push(date);
   $('scheduleCalendar').className='schedule-calendar '+scheduleMode.toLowerCase();
   $('scheduleCalendar').innerHTML=dates.filter(date=>!['Season','Year'].includes(scheduleMode)||scheduleItems.some(e=>e.date===date)).map(date=>`<div class="schedule-day ${date===today()?'is-today':''}"><h3>${schedule.parse(date).toLocaleDateString(undefined,{weekday:'short',day:'numeric',month:'short'})}</h3>${scheduleItems.filter(e=>e.date===date).map(eventHTML).join('')||'<p class="meta">No scheduled records</p>'}</div>`).join('');
   const undated=tables.tasks.filter(t=>(!t.scheduled_date&&t.recurrence==='One-time')||(t.recurrence==='Monthly'&&!t.scheduled_date)||(t.recurrence==='Weekly'&&!t.scheduled_date&&t.weekday===null));
   $('unscheduledRoutines').innerHTML=undated.length?undated.map(t=>`<div class="row"><div style="flex:1"><b>${escape(t.title)}</b><div class="meta">${escape(t.recurrence)} · Date TBC</div></div><button class="btn" data-schedule-task="${t.id}">Schedule</button></div>`).join(''):'<p class="meta">No undated records</p>';
  }
  function renderAllViews(){renderOther();renderCleaning();renderEggs();renderBirds();renderDailyHistory();renderPickers();renderAreasAndBeds();renderTaskViews();renderUpgrades();renderSchedule();}
  function openSchedule(taskId,date){
   $('scheduleForm').reset();$('scheduleEditId').value=taskId||'';$('scheduleDate').value=date||today();$('scheduleStatus').value='Open';$('scheduleRecurrence').value='One-time';
   if(taskId){const t=byId('tasks',taskId);$('scheduleTask').value=t.id;$('scheduleTitle').value=t.title;$('scheduleType').value=t.event_type;$('scheduleDate').value=date||t.scheduled_date||today();$('scheduleStart').value=t.start_time||'';$('scheduleEnd').value=t.end_time||'';setSelected('scheduleWorker',assignedIds(t.id));$('schedulePriority').value=t.priority;$('scheduleCategory').value=t.category;$('scheduleSeason').value=t.season_id||'';$('scheduleInterval').value=t.interval_days||'';$('scheduleArea').value=t.area_id||'';$('scheduleBed').value=t.bed_id||'';$('scheduleCrop').value=t.crop_id||'';$('scheduleCoop').value=t.coop_id||'';$('scheduleNotes').value=t.notes||'';$('scheduleRecurrence').value=t.recurrence;$('scheduleStatus').value=schedule.status(t,date||t.scheduled_date||today(),tables.task_occurrences);}
   $('scheduleEditor').hidden=false;location.hash='schedule';$('scheduleEditor').scrollIntoView({behavior:'smooth'});
  }
  $('scheduleNew').addEventListener('click',()=>openSchedule());$('scheduleCancel').addEventListener('click',()=>$('scheduleEditor').hidden=true);
  $('scheduleTask').addEventListener('change',()=>openSchedule($('scheduleTask').value||null));
  $('scheduleBed').addEventListener('change',()=>{const bed=byId('beds',$('scheduleBed').value);if(bed)$('scheduleArea').value=bed.area_id;});
  $('scheduleCoop').addEventListener('change',()=>{const coop=byId('coops',$('scheduleCoop').value);if(coop)$('scheduleArea').value=coop.area_id;});
  $('scheduleForm').addEventListener('submit',async e=>{
   e.preventDefault();if(!loaded||saving)return;const id=$('scheduleEditId').value;const val=id=>$(id).value||null;
   const payload={title:$('scheduleTitle').value.trim(),event_type:val('scheduleType'),scheduled_date:val('scheduleDate'),start_time:val('scheduleStart'),end_time:val('scheduleEnd'),assignee_ids:selectedIds('scheduleWorker'),priority:val('schedulePriority'),category:val('scheduleCategory'),season_id:val('scheduleSeason'),interval_days:numberValue('scheduleInterval'),area_id:val('scheduleArea'),bed_id:val('scheduleBed'),crop_id:val('scheduleCrop'),coop_id:val('scheduleCoop'),notes:val('scheduleNotes'),recurrence:val('scheduleRecurrence')};
   if(payload.end_time&&payload.end_time<=payload.start_time){toast('End time must be after start time.');return;}
   if(payload.bed_id&&payload.area_id!==byId('beds',payload.bed_id)?.area_id){toast('The selected bed belongs to a different location.');return;}
   if(payload.coop_id&&payload.area_id&&payload.area_id!==byId('coops',payload.coop_id)?.area_id){toast('The selected coop belongs to a different location.');return;}
   if(payload.recurrence==='Seasonal'&&!payload.season_id){toast('Choose a configured farm season.');return;}if(payload.recurrence==='Custom'&&!payload.interval_days){toast('Enter a recurrence interval.');return;}payload.occurrence_date=payload.scheduled_date;const existing=id?byId('tasks',id):null;if(existing&&existing.recurrence===payload.recurrence&&existing.scheduled_date&&payload.recurrence!=='One-time')payload.scheduled_date=existing.scheduled_date;payload.weekday=payload.recurrence==='Weekly'?schedule.parse(payload.scheduled_date).getDay():null;
   saving=true;try{await api.rpc('save_scheduled_task',{p_farm_id:farm.id,p_id:id||null,p_data:payload,p_status:val('scheduleStatus'),p_expected_updated_at:id?byId('tasks',id).updated_at:null});await refresh();$('scheduleEditor').hidden=true;toast('Schedule saved');}catch(error){notice('Not saved: '+error.message);}finally{saving=false;}
  });
  document.addEventListener('click',e=>{
   const b=e.target.closest('button');if(!b)return;
   if(b.dataset.scheduleTask)openSchedule(b.dataset.scheduleTask,b.dataset.scheduleDate);
   if(b.dataset.scheduleMode){scheduleMode=b.dataset.scheduleMode;renderSchedule();}
   if(b.dataset.scheduleMove){const step=Number(b.dataset.scheduleMove);if(['Year','Season'].includes(scheduleMode)){const d=schedule.parse(scheduleAnchor);d.setFullYear(d.getFullYear()+step);scheduleAnchor=schedule.key(d);}else if(scheduleMode==='Month'){const d=schedule.parse(scheduleAnchor);d.setMonth(d.getMonth()+step,1);scheduleAnchor=schedule.key(d);}else scheduleAnchor=schedule.plus(scheduleAnchor,step*(scheduleMode==='Week'?7:1));renderSchedule();}
   if(b.id==='scheduleToday'){scheduleAnchor=today();renderSchedule();}
   if(b.dataset.cleaningEvent){const rec=byId('coop_cleaning',b.dataset.cleaningEvent);$('activeCoop').value=byId('coops',rec.coop_id).name;$('recordDate').value=today();loadRecord();$('cleanType').value=rec.type;location.hash='coop';$('cleanForm').scrollIntoView({behavior:'smooth'});}
  });
  $('scheduleAnchor').addEventListener('change',()=>{if($('scheduleAnchor').value){scheduleAnchor=$('scheduleAnchor').value;renderSchedule();}});
  document.addEventListener('change',async e=>{const box=e.target;if(!box.dataset.eventTask)return;box.disabled=true;try{await api.rpc('set_task_status',{p_task_id:box.dataset.eventTask,p_date:box.dataset.eventDate,p_status:box.checked?'Completed':'Open'});await refresh();toast('Task and Schedule updated');}catch(error){box.checked=!box.checked;notice(error.message);}finally{box.disabled=false;}});
  $('syncRefresh').addEventListener('click',()=>refresh().catch(()=>{}));
  document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible'&&loaded&&!saving)refresh().catch(()=>{});});
  setInterval(()=>{if(document.visibilityState==='visible'&&loaded&&!saving)refresh().catch(()=>{});},15000);

  const stages=['Planned','Active','Vegetative','Flowering','Fruit development','Ready to harvest','Finished'];
  const selectedIds=id=>Array.from($(id).selectedOptions).map(o=>o.value).filter(Boolean);
  const setSelected=(id,ids)=>Array.from($(id).options).forEach(o=>{o.selected=ids.includes(o.value);});
  const assignedIds=id=>(tables.task_assignees||[]).filter(a=>a.task_id===id).map(a=>a.worker_id);
  const assignedNames=id=>assignedIds(id).map(workerName).filter(Boolean);
  const chips=names=>names.length?names.map(n=>`<span class="chip">${escape(n)}</span>`).join(''):'<span class="meta">Worker TBC</span>';
  async function perform(fn,message='Saved'){
   if(!loaded||saving){toast(loaded?'A save is in progress.':'Farm data is still loading. Please try again.');return false;}
   saving=true;document.body.classList.add('saving');try{await fn();await refresh();toast(message);return true;}catch(e){notice('Not saved: '+e.message);return false;}finally{saving=false;document.body.classList.remove('saving');}
  }
  function renderCropViews(){
   $('cropRows').innerHTML=state.crops.map(c=>`<tr class="${c.stage==='Finished'?'finished-crop':''}"><td>${display(c.name)}</td><td>${display(c.location)}</td><td>${fmt(c.planted)}</td><td>${escape(c.stage)}</td><td>${c.stage_changed_at?escape(new Date(c.stage_changed_at).toLocaleString()):'Not recorded yet'}</td><td>${c.stage!==stages[0]?`<button class="btn" data-stage-id="${c.id}" data-direction="previous">${c.stage==='Finished'?'Reopen crop':'Previous stage'}</button>`:''}${c.stage!=='Finished'?`<button class="btn" data-stage-id="${c.id}" data-direction="advance">Advance</button>`:''}</td></tr>`).join('')||'<tr><td colspan="6">Not recorded yet</td></tr>';
   $('cropHistory').innerHTML=(tables.crop_stage_history||[]).slice().sort((a,b)=>b.changed_at.localeCompare(a.changed_at)).map(h=>`<p>${display(cropName(h.crop_id))} · ${display(bedName(h.bed_id))}: ${display(h.previous_stage)} → ${display(h.new_stage)} · ${escape(new Date(h.changed_at).toLocaleString())} · ${display(h.changed_by_email)} · ${display(h.reason)}</p>`).join('')||'<p class="meta">Not recorded yet</p>';
  }
  function renderUpgrades(){
   if(!loaded)return;renderCropViews();options('taskOwner',state.workers,'name','');
   for(const [id,chipId] of [['taskOwner','taskAssigneeChips'],['scheduleWorker','scheduleAssigneeChips']])$(chipId).innerHTML=chips(selectedIds(id).map(workerName).filter(Boolean));
   for(const id of ['chickenFrom','chickenTo'])options(id,tables.coops,'name','Choose coop');
   for(const id of ['scheduleSeason','scheduleSeasonView'])options(id,tables.farm_seasons,'name','Season TBC');
   $('seasonList').innerHTML=tables.farm_seasons.map(s=>`<p>${escape(s.name)} · ${s.start_month}/${s.start_day} – ${s.end_month}/${s.end_day} <button class="btn" data-edit-season="${s.id}">Edit</button></p>`).join('')||'<p class="meta">Not recorded yet</p>';
   $('chickenHistory').innerHTML=tables.chicken_count_history.slice().sort((a,b)=>b.created_at.localeCompare(a.created_at)).map(h=>`<p>${escape(new Date(h.created_at).toLocaleString())} · ${display(byId('coops',h.coop_id)?.name)} · ${escape(h.action)} · ${display(h.quantity)} · ${display(h.previous_count)} → ${display(h.new_count)} · ${display(h.reason)} · ${display(h.notes)} · ${display(h.changed_by_email)}</p>`).join('')||'<p class="meta">Not recorded yet</p>';
   renderCommerce();
  }
  function setChickenReasons(){const reasons={Add:['Purchased','Hatched','Returned','Correction','Other'],Remove:['Mortality','Sold','Culled','Missing','Correction','Other'],Transfer:['Coop transfer','Other']};$('chickenReason').innerHTML=reasons[$('chickenAction').value].map(r=>`<option>${r}</option>`).join('');$('chickenTo').disabled=$('chickenAction').value!=='Transfer';}
  setChickenReasons();$('chickenAction').addEventListener('change',setChickenReasons);
  $('chickenAdjustForm').addEventListener('submit',async e=>{e.preventDefault();if(!$('chickenFrom').value){toast('Choose a coop.');return;}if(!confirm('Record this chicken count adjustment?'))return;const ok=await perform(()=>api.rpc('adjust_chickens',{p_coop_id:$('chickenFrom').value,p_action:$('chickenAction').value,p_quantity:numberValue('chickenQuantity'),p_reason:$('chickenReason').value,p_notes:$('chickenNotes').value||null,p_to_coop:$('chickenAction').value==='Transfer'?$('chickenTo').value||null:null}),'Chicken counts updated');if(ok){e.target.reset();setChickenReasons();}});
  let editingSeason=null;
  $('seasonForm').addEventListener('submit',async e=>{e.preventDefault();const a=schedule.parse($('seasonStart').value),b=schedule.parse($('seasonEnd').value);const data={name:$('seasonName').value.trim(),start_month:a.getMonth()+1,start_day:a.getDate(),end_month:b.getMonth()+1,end_day:b.getDate()};const ok=await perform(()=>editingSeason?api.update('farm_seasons',byId('farm_seasons',editingSeason),data):api.insert('farm_seasons',{farm_id:farm.id,...data}));if(ok){editingSeason=null;e.target.reset();}});
  document.addEventListener('click',async e=>{const b=e.target.closest('button');if(!b)return;if(b.dataset.stageId){const previous=b.dataset.direction==='previous';if(previous&&!confirm('Move this crop to its previous stage? The change will be recorded in its history.'))return;const reason=previous?prompt('Reason for reopening or reverting this crop:',''):null;if(previous&&reason===null)return;await perform(()=>api.rpc('change_crop_stage',{p_id:b.dataset.stageId,p_direction:b.dataset.direction,p_reason:reason}),'Crop stage updated');}if(b.dataset.editSeason){editingSeason=b.dataset.editSeason;const s=byId('farm_seasons',editingSeason);$('seasonName').value=s.name;$('seasonStart').value=`2000-${String(s.start_month).padStart(2,'0')}-${String(s.start_day).padStart(2,'0')}`;$('seasonEnd').value=`2000-${String(s.end_month).padStart(2,'0')}-${String(s.end_day).padStart(2,'0')}`;}});
  for(const [id,chipId] of [['taskOwner','taskAssigneeChips'],['scheduleWorker','scheduleAssigneeChips']])$(id).addEventListener('change',()=>{$(chipId).innerHTML=chips(selectedIds(id).map(workerName).filter(Boolean));});
  $('scheduleSeasonView').addEventListener('change',renderSchedule);

  const emptyMarkup='<p class="meta">Not recorded yet</p>';
  const quantityText=n=>n==null?'TBC':escape(n);
  const card=(label,value)=>`<div class="card"><div class="meta">${label}</div><strong>${value}</strong></div>`;
  const totalKnown=(rows,field)=>rows.length?rows.every(r=>r[field]!=null)?rows.reduce((s,r)=>s+Number(r[field]),0):'TBC':'Not recorded yet';
  const imageMarkup=data=>data&&/^data:image\/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$/.test(data)?`<img class="product-image" src="${data}" alt="">`:'';
  async function readPhoto(id,max=250000){const file=$(id).files[0];if(!file)return null;if(!['image/jpeg','image/png','image/webp'].includes(file.type)||file.size>max)throw Error('Choose a JPEG, PNG or WebP image smaller than '+Math.floor(max/1000)+' KB.');return new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=()=>reject(Error('Photo could not be read'));reader.readAsDataURL(file);});}
  function revenue(rows,field){if(!rows.length)return 'Not recorded yet';const known=rows.filter(r=>r[field]!=null&&r.currency);const currencies=[...new Set(known.map(r=>r.currency))];return currencies.map(c=>escape(c)+' '+known.filter(r=>r.currency===c).reduce((s,r)=>s+Number(r[field]),0).toFixed(2)).join(' · ')+(known.length<rows.length?' · some prices/currencies TBC':'');}
  function renderCommerce(){
   const products=tables.marketplace_products.filter(p=>!p.archived),sales=tables.marketplace_transactions;
   $('marketplaceDashboard').innerHTML=card('Products',products.length)+card('Sales recorded',sales.length)+card('Recorded revenue',revenue(sales,'revenue'))+card('Stock source','Shared inventory');
   $('productList').innerHTML=products.map(p=>{const i=byId('inventory',p.inventory_id),q=i?.qty==null?null:Math.floor(Number(i.qty)/Number(p.stock_per_unit)*10000)/10000;return `<div class="card">${imageMarkup(p.image_data)}<h3>${escape(p.name)}</h3><p>${display(p.description)}</p><div class="meta">${display(p.category)} · ${escape(p.source)}</div><p>${quantityText(q)} ${display(p.unit)} available · ${quantityText(p.price)} ${display(p.currency)}</p><p>${q===0?'Out of Stock':p.status==='Hidden'?'Hidden':q!=null&&i.min!=null&&i.qty<i.min?'Low Stock':escape(p.status)}</p><p class="meta">${display(i?.item)} · ${quantityText(p.stock_per_unit)} inventory units per sale unit</p><button class="btn" data-product-edit="${p.id}">Edit</button> <button class="btn" data-product-stock="${p.id}">Adjust stock</button> <button class="btn primary" data-product-sale="${p.id}" ${q==null||q<=0||p.status==='Hidden'?'disabled':''}>Record sale</button> <button class="btn danger" data-product-delete="${p.id}">Archive</button></div>`;}).join('')||emptyMarkup;
   $('salesHistory').innerHTML=sales.slice().sort((a,b)=>b.record_date.localeCompare(a.record_date)).map(s=>`<p>${fmt(s.record_date)} · ${display(byId('marketplace_products',s.product_id)?.name)} · ${quantityText(s.quantity)} · ${quantityText(s.revenue)} ${display(s.currency)}</p>`).join('')||emptyMarkup;
   const menu=tables.breakfast_items,records=tables.breakfast_records;
   $('breakfastDashboard').innerHTML=card('Menu items',menu.length)+card('Available servings',totalKnown(menu,'quantity_available'))+card('Prepared servings',totalKnown(records.filter(r=>r.action==='Prepared'),'quantity'))+card('Served',totalKnown(records.filter(r=>r.action==='Served'),'quantity'));
   $('breakfastList').innerHTML=menu.map(m=>`<div class="card">${imageMarkup(m.image_data)}<h3>${escape(m.name)}</h3><p>${display(m.description)}</p><p>${m.active?'Active':'Inactive'} · ${quantityText(m.quantity_available)} servings available</p><p>${quantityText(m.selling_price)} ${display(m.currency)}</p><div>${tables.breakfast_ingredients.filter(r=>r.menu_item_id===m.id).map(r=>`<p class="meta">${display(byId('inventory',r.inventory_id)?.item)} · ${quantityText(r.quantity_per_serving)} ${display(byId('inventory',r.inventory_id)?.unit)} per serving</p>`).join('')||'<p class="meta">Recipe: Not recorded yet</p>'}</div><button class="btn" data-menu-edit="${m.id}">Edit</button> <button class="btn" data-menu-count="${m.id}">Record servings count</button> <button class="btn" data-menu-action="Prepared" data-menu-id="${m.id}">Prepare</button> <button class="btn" data-menu-action="Served" data-menu-id="${m.id}">Serve</button> <button class="btn danger" data-menu-toggle="${m.id}">${m.active?'Deactivate':'Activate'}</button></div>`).join('')||emptyMarkup;
   $('breakfastHistory').innerHTML=records.slice().sort((a,b)=>b.created_at.localeCompare(a.created_at)).map(r=>`<p>${fmt(r.record_date)} · ${display(byId('breakfast_items',r.menu_item_id)?.name)} · ${escape(r.action)} · ${quantityText(r.quantity)} servings</p>`).join('')||emptyMarkup;
   $('breakfastHistory').innerHTML+='<h3>Ingredient usage</h3>'+tables.inventory_transactions.filter(t=>t.type==='Breakfast Usage').slice().sort((a,b)=>b.created_at.localeCompare(a.created_at)).map(t=>`<p>${escape(new Date(t.created_at).toLocaleString())} · ${display(byId('inventory',t.inventory_id)?.item)} · ${quantityText(t.quantity==null?null:-t.quantity)} ${display(byId('inventory',t.inventory_id)?.unit)} · ${display(t.reason)}</p>`).join('');
   options('productInventory',state.inventory,'item','Create new inventory item');
   const existing=$('inventoryHistory');if(existing)existing.innerHTML=tables.inventory_transactions.slice().sort((a,b)=>b.created_at.localeCompare(a.created_at)).map(t=>`<p>${escape(new Date(t.created_at).toLocaleString())} · ${display(byId('inventory',t.inventory_id)?.item)} · ${display(t.type)} · ${quantityText(t.previous_quantity)} → ${quantityText(t.new_quantity)} · ${display(t.reason)}</p>`).join('')||emptyMarkup;
  }
  function openProduct(id){$('productForm').reset();$('productId').value=id||'';if(id){const p=byId('marketplace_products',id);for(const [field,el] of Object.entries({name:'Name',description:'Description',category:'Category',source:'Source',inventory_id:'Inventory',unit:'Unit',stock_per_unit:'Factor',price:'Price',currency:'Currency',status:'Status'}))$('product'+el).value=p[field]??'';if(!$('productUnit').value){$('productUnit').value='custom';$('productCustomUnit').value=p.unit;}}$('productEditor').hidden=false;}
  $('productNew').addEventListener('click',()=>openProduct());
  $('productForm').addEventListener('submit',async e=>{e.preventDefault();try{const id=$('productId').value,p=id?byId('marketplace_products',id):null,image=await readPhoto('productImage');const data={name:$('productName').value.trim(),description:$('productDescription').value||null,category:$('productCategory').value||null,source:$('productSource').value,inventory_id:$('productInventory').value||null,unit:$('productUnit').value==='custom'?$('productCustomUnit').value||null:$('productUnit').value,stock_per_unit:numberValue('productFactor'),quantity:numberValue('productQuantity'),price:numberValue('productPrice'),currency:$('productCurrency').value||null,status:$('productStatus').value,image_data:image||p?.image_data||null};if(data.source==='Eggs'&&!byId('inventory',data.inventory_id)?.coop_id)throw Error('Choose the shared Coop A or Coop B egg inventory.');const ok=await perform(()=>api.rpc('save_marketplace_product',{p_farm_id:farm.id,p_id:id||null,p_data:data}),'Product saved');if(ok)$('productEditor').hidden=true;}catch(e){notice(e.message);}});
  function ingredientRow(r={}){const div=document.createElement('div');div.className='row ingredient-row';div.innerHTML=`<label>Inventory item<select class="ingredient-id" required><option value="">Choose ingredient</option>${state.inventory.map(i=>`<option value="${i.id}">${escape(i.item)} (${display(i.unit)})</option>`).join('')}</select></label><label>Quantity per serving<input class="ingredient-qty" type="number" min="0.000001" step="any" required></label><button type="button" class="btn danger" data-remove-ingredient>Remove</button>`;div.querySelector('select').value=r.inventory_id||'';div.querySelector('input').value=r.quantity_per_serving??'';$('ingredientRows').append(div);}
  function openMenu(id){$('breakfastForm').reset();$('breakfastId').value=id||'';$('ingredientRows').innerHTML='';if(id){const m=byId('breakfast_items',id);for(const [field,el] of Object.entries({name:'Name',description:'Description',selling_price:'Price',currency:'Currency',quantity_available:'Quantity'}))$('breakfast'+el).value=m[field]??'';$('breakfastActive').value=m.active?'Active':'Inactive';tables.breakfast_ingredients.filter(r=>r.menu_item_id===id).forEach(ingredientRow);} $('breakfastQuantity').disabled=!!id;$('breakfastEditor').hidden=false;}
  $('breakfastNew').addEventListener('click',()=>openMenu());$('ingredientAdd').addEventListener('click',()=>ingredientRow());
  $('breakfastForm').addEventListener('submit',async e=>{e.preventDefault();try{const id=$('breakfastId').value,m=id?byId('breakfast_items',id):null,image=await readPhoto('breakfastImage');const data={name:$('breakfastName').value.trim(),description:$('breakfastDescription').value||null,selling_price:numberValue('breakfastPrice'),currency:$('breakfastCurrency').value||null,active:$('breakfastActive').value==='Active',quantity_available:numberValue('breakfastQuantity'),image_data:image||m?.image_data||null};const ingredients=Array.from($('ingredientRows').children).map(row=>({inventory_id:row.querySelector('select').value,quantity_per_serving:Number(row.querySelector('input').value)}));const ok=await perform(()=>api.rpc('save_breakfast_item',{p_farm_id:farm.id,p_id:id||null,p_data:data,p_ingredients:ingredients}),'Breakfast item saved');if(ok)$('breakfastEditor').hidden=true;}catch(e){notice(e.message);}});
  function enteredQuantity(message,current){const raw=prompt(message,current??'');if(raw==null||raw.trim()==='')return null;const n=Number(raw);if(!Number.isFinite(n)||n<0){toast('Enter a non-negative quantity.');return null;}return n;}
  document.addEventListener('click',async e=>{const b=e.target.closest('button');if(!b)return;
   if(b.hasAttribute('data-remove-ingredient'))b.closest('.ingredient-row').remove();
   if(b.dataset.productEdit)openProduct(b.dataset.productEdit);if(b.dataset.menuEdit)openMenu(b.dataset.menuEdit);
   if(b.dataset.productStock){const p=byId('marketplace_products',b.dataset.productStock),i=byId('inventory',p.inventory_id),q=enteredQuantity('Observed stock in '+(i.unit||'inventory units')+':',i.qty);if(q!==null)await perform(()=>api.update('inventory',i,{qty:q}),'Shared stock updated');}
   if(b.dataset.productSale){const q=enteredQuantity('Quantity sold (in the product’s sale unit):');if(q>0){const date=prompt('Actual sale date (YYYY-MM-DD):',today());if(date&&/^\d{4}-\d{2}-\d{2}$/.test(date))await perform(()=>api.rpc('record_marketplace_sale',{p_product_id:b.dataset.productSale,p_quantity:q,p_date:date,p_request_id:crypto.randomUUID()}),'Sale and stock recorded');}}
   if(b.dataset.productDelete&&confirm('Archive this product? Existing sales history will be kept.')){const p=byId('marketplace_products',b.dataset.productDelete);await perform(()=>api.rpc('save_marketplace_product',{p_farm_id:farm.id,p_id:p.id,p_data:{...p,archived:true}}),'Product archived');}
   if(b.dataset.menuToggle){const m=byId('breakfast_items',b.dataset.menuToggle);if(confirm((m.active?'Deactivate':'Activate')+' this menu item?'))await perform(()=>api.rpc('save_breakfast_item',{p_farm_id:farm.id,p_id:m.id,p_data:{...m,active:!m.active},p_ingredients:tables.breakfast_ingredients.filter(r=>r.menu_item_id===m.id)}));}
   if(b.dataset.menuCount){const m=byId('breakfast_items',b.dataset.menuCount),q=enteredQuantity('Actual servings available:',m.quantity_available);if(q!==null)await perform(()=>api.rpc('count_breakfast_servings',{p_id:m.id,p_quantity:q}));}
   if(b.dataset.menuAction){const q=enteredQuantity('Servings '+b.dataset.menuAction.toLowerCase()+':');if(q>0){const date=prompt('Actual date (YYYY-MM-DD):',today());if(date&&/^\d{4}-\d{2}-\d{2}$/.test(date))await perform(()=>api.rpc('record_breakfast',{p_menu_item_id:b.dataset.menuId,p_action:b.dataset.menuAction,p_quantity:q,p_date:date,p_request_id:crypto.randomUUID()}),'Breakfast and inventory updated');}}
  });

  let aiBusy=false,aiConversation=null,aiActions=[];
  async function assistantRequest(body){const response=await fetch('/api/ai',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});let result;try{result=await response.json();}catch{throw Error('Farm Assistant requires the Vercel app or the local server with /api/ai enabled.');}if(!response.ok)throw Error(result.error||'Farm Assistant unavailable');return result;}
  function actionDisplay(value,key){if(Array.isArray(value))return value.map(v=>actionDisplay(v,key==='assignee_ids'?'worker_id':key)).join(', ');if(value&&typeof value==='object')return Object.entries(value).map(([k,v])=>k.replaceAll('_',' ')+': '+actionDisplay(v,k)).join('\n');if(value===null||value==='')return 'TBC';const tablesByKey={task_id:'tasks',worker_id:'workers',area_id:'areas',bed_id:'beds',crop_id:'crops',coop_id:'coops',to_coop_id:'coops',inventory_id:'inventory',menu_item_id:'breakfast_items',season_id:'farm_seasons'};const row=byId(tablesByKey[key],value);return row?(row.name||row.title||row.code||row.item):String(value);}
  async function loadAI(){if(!loaded)return;const conversations=await api.rows('ai_conversations','&farm_id=eq.'+farm.id);options('aiConversation',conversations,'title','Choose conversation');if(aiConversation&&!conversations.some(c=>c.id===aiConversation))aiConversation=null;$('aiConversation').value=aiConversation||'';if(!aiConversation){$('aiMessages').innerHTML='<p class="meta">Start a conversation to ask about your farm.</p>';$('aiPending').innerHTML='';return;}const [messages,actions]=await Promise.all([api.rows('ai_messages','&conversation_id=eq.'+aiConversation),api.rows('ai_actions','&conversation_id=eq.'+aiConversation)]);$('aiMessages').innerHTML=messages.sort((a,b)=>a.created_at.localeCompare(b.created_at)).map(m=>`<div class="ai-message ${m.role}"><b>${m.role==='user'?'You':'Farm Assistant'}</b><div style="white-space:pre-wrap">${escape(m.content)}</div></div>`).join('');aiActions=actions;$('aiPending').innerHTML=actions.filter(a=>a.status==='Pending').map(a=>`<div class="card"><h3>Confirm: ${escape(a.summary)}</h3><pre style="white-space:pre-wrap">${escape(actionDisplay(a.arguments))}</pre><button class="btn primary" data-ai-confirm="${a.id}">Confirm</button> <button class="btn" data-ai-cancel="${a.id}">Cancel</button></div>`).join('');}
  async function newConversation(){if(!loaded){toast('Farm data is still loading. Please try again.');return;}const rows=await api.insert('ai_conversations',{farm_id:farm.id,title:'Farm conversation'});aiConversation=rows[0].id;await loadAI();}
  $('aiFloating').addEventListener('click',()=>{location.hash='assistant';loadAI().catch(e=>{$('aiStatus').textContent=e.message;});});
  window.addEventListener('hashchange',()=>{if(location.hash==='#assistant')loadAI().catch(e=>{$('aiStatus').textContent=e.message;});});
  $('aiNew').addEventListener('click',()=>newConversation().catch(e=>{$('aiStatus').textContent=e.message;}));
  $('aiConversation').addEventListener('change',()=>{aiConversation=$('aiConversation').value||null;loadAI().catch(e=>{$('aiStatus').textContent=e.message;});});
  $('aiRename').addEventListener('click',async()=>{if(!aiConversation)return;const title=prompt('Conversation name:');if(title?.trim())try{await api.update('ai_conversations',{id:aiConversation},{title:title.trim().slice(0,200)});await loadAI();}catch(e){$('aiStatus').textContent=e.message;}});
  $('aiDelete').addEventListener('click',async()=>{if(!aiConversation||!confirm('Delete this conversation and its messages? Action audit history is retained.'))return;try{await api.request('ai_conversations?id=eq.'+aiConversation,{method:'DELETE'});aiConversation=null;await loadAI();}catch(e){$('aiStatus').textContent=e.message;}});
  $('aiForm').addEventListener('submit',async e=>{e.preventDefault();if(aiBusy||!loaded)return;aiBusy=true;const button=e.target.querySelector('button[type=submit]');button.disabled=true;$('aiStatus').textContent='Farm Assistant is checking your farm records…';try{if(!aiConversation)await newConversation();const image=await readPhoto('aiImage',2000000);await assistantRequest({conversation_id:aiConversation,message:$('aiInput').value,image});$('aiInput').value='';$('aiImage').value='';$('aiStatus').textContent='';await loadAI();}catch(error){$('aiStatus').textContent=error.message;await loadAI().catch(()=>{});}finally{aiBusy=false;button.disabled=false;}});
  document.addEventListener('click',async e=>{const b=e.target.closest('button');if(!b)return;if(b.dataset.aiSuggestion){$('aiInput').value=b.dataset.aiSuggestion;location.hash='assistant';$('aiInput').focus();}const id=b.dataset.aiConfirm||b.dataset.aiCancel;if(id&&!aiBusy){aiBusy=true;b.disabled=true;try{const result=await assistantRequest({operation:'decide',action_id:id,confirm:!!b.dataset.aiConfirm});$('aiStatus').textContent='Action '+result.status.toLowerCase()+'.';await refresh();await loadAI();}catch(error){$('aiStatus').textContent=error.message;}finally{aiBusy=false;b.disabled=false;}}});

  function navigate(){const hash=location.hash.slice(1)||'home';document.querySelectorAll('.view').forEach(el=>el.classList.toggle('active',el.id===hash));document.querySelectorAll('nav a').forEach(el=>el.classList.toggle('active',el.hash===location.hash));}window.addEventListener('hashchange',navigate);if(!location.hash)location.hash='home';navigate();
  renderAllViews();loadRecord();document.querySelectorAll('.view form button[type=submit]').forEach(b=>b.disabled=true);refresh({initial:true}).catch(()=>{});
})();
