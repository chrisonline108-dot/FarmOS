(function(root){
 'use strict';
 const key=d=>`${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
 const parse=s=>new Date(s+'T12:00:00');
 const plus=(s,n)=>{const d=parse(s);d.setDate(d.getDate()+n);return key(d);};
 function range(mode,anchor){const d=parse(anchor);if(mode==='Today')return [anchor,anchor];if(mode==='Week'){d.setDate(d.getDate()-((d.getDay()+6)%7));return [key(d),plus(key(d),6)];}return [key(new Date(d.getFullYear(),d.getMonth(),1,12)),key(new Date(d.getFullYear(),d.getMonth()+1,0,12))];}
 function occurs(task,date){
  if(task.recurrence==='One-time')return task.scheduled_date===date;
  if(task.scheduled_date&&date<task.scheduled_date)return false;
  if(task.recurrence==='Daily')return true;
  if(task.recurrence==='Weekly')return parse(date).getDay()===(task.weekday??(task.scheduled_date?parse(task.scheduled_date).getDay():-1));
  if(task.recurrence==='Monthly'&&task.scheduled_date){const d=parse(date),day=Math.min(parse(task.scheduled_date).getDate(),new Date(d.getFullYear(),d.getMonth()+1,0).getDate());return d.getDate()===day;}
  return false;
 }
 function status(task,date,overrides){if(task.recurrence==='One-time')return task.status;return overrides.find(x=>x.task_id===task.id&&x.occurrence_date===date)?.status??(task.status==='Cancelled'?'Cancelled':'Open');}
 function taskEvents(tasks,overrides,start,end){const out=[];for(let date=start;date<=end;date=plus(date,1))for(const task of tasks)if(occurs(task,date))out.push({...task,date,status:status(task,date,overrides),source:'task',source_id:task.id});return out;}
 const api={key,parse,plus,range,occurs,status,taskEvents};if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.FarmSchedule=api;
})(typeof window!=='undefined'?window:globalThis);
