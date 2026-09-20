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
  const STORE = 'green_peas_confirmed_v4';
  const defaults = {version:4,workers:/* WORKERS */[],tasks:[],crops:[],inventory:/* INVENTORY */[],plans:[],birds:{},records:{},cleaning:[]};
  let state = structuredClone(defaults);
  let storageBlocked = false;
  function notice(message) { $('storageNotice').hidden=false; $('storageNotice').textContent=message; }
  try {
    const saved=localStorage.getItem(STORE);
    if(saved){const data=JSON.parse(saved);if(data.version!==4 || !data.records || !Array.isArray(data.cleaning))throw Error('Invalid saved data');state={...state,...data};}
    else if(localStorage.getItem('green_peas_farm_os_complete_v3')) notice('Earlier app data is preserved in this browser. This version starts with verified records only; old entries have not been assigned to coops or treated as confirmed. Keep the original file to review earlier entries.');
  } catch(e) { storageBlocked=true; notice('Saved data could not be read. Existing storage is preserved; changes cannot be saved until browser storage is available.'); }
  function toast(message) { $('toast').textContent=message; $('toast').classList.add('show');setTimeout(()=>$('toast').classList.remove('show'),3500); }
  function commit(next) {
    if(storageBlocked){toast('Not saved. Browser storage is unavailable.');return false;}
    try {localStorage.setItem(STORE,JSON.stringify(next));state=next;return true;}
    catch(e){notice('Not saved: browser storage is unavailable or full. Keep this page open and try again.');return false;}
  }
  function change(fn) {const next=structuredClone(state);fn(next);return commit(next);}
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
  $('birdForm').addEventListener('submit',e=>{
    e.preventDefault();const a=numberValue('birdsA'),b=numberValue('birdsB');
    if([a,b].some(n=>n!==null&&(!Number.isInteger(n)||n<0||n>90))||(a!==null&&b!==null&&a+b!==90)){toast('Observed counts must be whole numbers; both coops must total 90.');return;}
    if(change(s=>{s.birds={[COOPS[0]]:a,[COOPS[1]]:b};})){renderBirds();toast('Observed counts saved');}
  });
  $('birdsA').value=state.birds[COOPS[0]]??'';$('birdsB').value=state.birds[COOPS[1]]??'';
  $('dailyRecordForm').addEventListener('submit',e=>{
    e.preventDefault();const date=$('recordDate').value,coop=currentCoop();
    if(!date||date>today()){toast('Choose an actual record date, today or earlier.');return;}
    const rec=Object.fromEntries(fields.map(([field,type])=>[field,numeric.includes(field)?numberValue('rec_'+field):$('rec_'+field).value.trim()||null]));
    if(numeric.some(field=>rec[field]!==null&&(!Number.isFinite(rec[field])||rec[field]<0||(field!=='feed'&&!Number.isInteger(rec[field]))))){toast('Enter non-negative quantities and whole egg / bird counts.');return;}
    if(rec.morning!==null&&rec.evening!==null){const total=rec.morning+rec.evening;if(rec.total!==null&&rec.total!==total){toast('Eggs collected must equal morning plus evening eggs.');return;}rec.total=total;}
    if(rec.total!==null&&((rec.morning??0)+(rec.evening??0)>rec.total||(rec.saleable??0)+(rec.broken??0)>rec.total)){toast('Collection or grading counts exceed eggs collected.');return;}
    if(rec.total!==null&&rec.saleable!==null&&rec.broken!==null&&rec.saleable+rec.broken!==rec.total){toast('Saleable plus broken / dirty eggs must equal eggs collected.');return;}
    if(fields.every(([field])=>rec[field]===null)){toast('Enter at least one observation before saving.');return;}
    if(change(s=>{s.records[date]??={};s.records[date][coop]=rec;})){loadRecord();renderEggs();toast(coop+' daily record saved');}
  });
  function nextDate(date,type){const d=dateObject(date);if(type==='deep'){const day=d.getDate();d.setMonth(d.getMonth()+1,1);const last=new Date(d.getFullYear(),d.getMonth()+1,0).getDate();d.setDate(Math.min(day,last));}else d.setDate(d.getDate()+(type==='mini'?1:7));return dateKey(d);}
  $('cleanForm').addEventListener('submit',e=>{
    e.preventDefault();const type=$('cleanType').value,date=$('cleanDate').value,completion=$('cleanCompletion').value;
    if(!date||date>today()||!completion){toast('Enter a cleaning date today or earlier and completion status.');return;}
    const next=$('cleanNext').value||(completion==='Completed'?nextDate(date,type):null);
    if(next&&next<date){toast('Next cleaning due cannot be before the cleaning date.');return;}
    const rec={coop:currentCoop(),type,date,completion,next,worker:$('cleanWorker').value.trim()||null,notes:$('cleanNotes').value.trim()||null,savedAt:new Date().toISOString()};
    if(change(s=>s.cleaning.push(rec))){$('cleanForm').reset();$('cleanDate').value=$('recordDate').value;renderCleaning();toast('Cleaning record saved for '+rec.coop);}
  });
  $('activeCoop').addEventListener('change',loadRecord);$('recordDate').addEventListener('change',loadRecord);$('summaryDate').addEventListener('change',renderEggs);
  function renderOther() {
    const empty='<p class="meta">Not recorded yet</p>';
    const selected=$('taskOwner').value;
    $('taskOwner').innerHTML='<option value="">Worker TBC</option>'+state.workers.map(w=>`<option>${escape(w.name)}</option>`).join('');$('taskOwner').value=selected;
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
  document.addEventListener('click',e=>{
    const link=e.target.closest('[data-open-coop]');if(link){$('activeCoop').value=link.dataset.openCoop;loadRecord();}
    const b=e.target.closest('button');if(!b)return;
    if(b.dataset.editDate){$('recordDate').value=b.dataset.editDate;loadRecord();$('recordDate').scrollIntoView({behavior:'smooth'});return;}
    for(const [attr,list] of [['delWorker','workers'],['delTask','tasks'],['delPlan','plans']])if(b.dataset[attr]!==undefined){if(change(s=>s[list].splice(Number(b.dataset[attr]),1)))renderOther();return;}
    if(b.dataset.advance!==undefined){const stages=['Planned','Active','Vegetative','Flowering','Fruit development','Ready to harvest','Finished'];if(change(s=>{const c=s.crops[+b.dataset.advance];c.stage=stages[Math.min(stages.length-1,stages.indexOf(c.stage)+1)];}))renderOther();}
    if(b.dataset.count!==undefined){const i=+b.dataset.count,input=prompt('Enter the observed inventory quantity. Leave blank to keep TBC.',state.inventory[i].qty??'');if(input===null||input.trim()==='')return;const qty=Number(input);if(!Number.isFinite(qty)||qty<0){toast('Enter a non-negative quantity');return;}if(change(s=>s.inventory[i].qty=qty))renderOther();}
    for(const action of ['minus','plus'])if(b.dataset[action]!==undefined){const i=+b.dataset[action];if(state.inventory[i].qty==null)return;if(change(s=>s.inventory[i].qty=Math.max(0,Math.round((s.inventory[i].qty+(action==='plus'?1:-1))*100)/100)))renderOther();}
  });
  document.addEventListener('change',e=>{if(e.target.dataset.check!==undefined&&change(s=>s.tasks[+e.target.dataset.check].done=e.target.checked))renderOther();});
  function submit(id,fn){$(id).addEventListener('submit',e=>{e.preventDefault();if(change(fn)){e.target.reset();renderOther();toast('Saved');}});}
  submit('taskForm',s=>s.tasks.push({title:$('taskTitle').value.trim(),owner:$('taskOwner').value||null,time:$('taskTime').value||null,done:false}));
  submit('cropForm',s=>s.crops.push({name:$('cropName').value.trim(),location:$('cropLocation').value,planted:$('cropDate').value||null,stage:$('cropStage').value}));
  submit('workerForm',s=>s.workers.push({name:$('workerName').value.trim(),role:$('workerRole').value.trim(),phone:$('workerPhone').value.trim()}));
  submit('invForm',s=>s.inventory.push({item:$('invItem').value.trim(),category:$('invCategory').value,qty:numberValue('invQty'),min:numberValue('invMin')}));
  submit('planForm',s=>s.plans.push({crop:$('planCrop').value.trim(),area:$('planArea').value.trim(),date:$('planDate').value,notes:$('planNotes').value.trim()}));
  renderOther();loadRecord();renderEggs();renderBirds();
  if(!location.hash)location.hash='home';
})();
