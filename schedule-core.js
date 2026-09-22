(function(root){
 'use strict';
 const key=d=>`${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
 const parse=s=>new Date(s+'T12:00:00');
 const plus=(s,n)=>{const d=parse(s);d.setDate(d.getDate()+n);return key(d);};
 const monthDay=(year,month,day)=>key(new Date(year,month-1,Math.min(day,new Date(year,month,0).getDate()),12));
 function range(mode,anchor,season){const d=parse(anchor),year=d.getFullYear();if(mode==='Today')return [anchor,anchor];if(mode==='Week'){d.setDate(d.getDate()-((d.getDay()+6)%7));return [key(d),plus(key(d),6)];}if(mode==='Year')return [year+'-01-01',year+'-12-31'];if(mode==='Season'){if(!season)return null;const wraps=season.end_month*100+season.end_day<season.start_month*100+season.start_day;let y=year;if(wraps&&anchor<monthDay(y,season.start_month,season.start_day))y--;return [monthDay(y,season.start_month,season.start_day),monthDay(y+(wraps?1:0),season.end_month,season.end_day)];}return [key(new Date(year,d.getMonth(),1,12)),key(new Date(year,d.getMonth()+1,0,12))];}
 function occurs(task,date,seasons=[]){
  if(task.recurrence==='One-time')return task.scheduled_date===date;
  if(task.scheduled_date&&date<task.scheduled_date)return false;
  if(task.recurrence==='Daily')return true;
  if(task.recurrence==='Weekly')return parse(date).getDay()===(task.weekday??(task.scheduled_date?parse(task.scheduled_date).getDay():-1));
  if(task.recurrence==='Monthly'&&task.scheduled_date){const d=parse(date),day=Math.min(parse(task.scheduled_date).getDate(),new Date(d.getFullYear(),d.getMonth()+1,0).getDate());return d.getDate()===day;}
  if(task.recurrence==='Yearly'&&task.scheduled_date){const start=parse(task.scheduled_date);return date===monthDay(parse(date).getFullYear(),start.getMonth()+1,start.getDate());}
  if(task.recurrence==='Seasonal'){const s=seasons.find(s=>s.id===task.season_id);return !!s&&date===monthDay(parse(date).getFullYear(),s.start_month,s.start_day);}
  if(task.recurrence==='Custom'&&task.scheduled_date&&task.interval_days>0)return Math.round((Date.parse(date+'T12:00:00Z')-Date.parse(task.scheduled_date+'T12:00:00Z'))/86400000)%task.interval_days===0;
  return false;
 }
 function status(task,date,overrides){if(task.recurrence==='One-time')return task.status;return overrides.find(x=>x.task_id===task.id&&x.occurrence_date===date)?.status??(task.status==='Cancelled'?'Cancelled':'Open');}
 function taskEvents(tasks,overrides,start,end,seasons=[]){const out=[];for(let date=start;date<=end;date=plus(date,1))for(const task of tasks)if(occurs(task,date,seasons))out.push({...task,date,status:status(task,date,overrides),source:'task',source_id:task.id});return out;}
 const api={key,parse,plus,range,occurs,status,taskEvents};if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.FarmSchedule=api;
})(typeof window!=='undefined'?window:globalThis);
