create table public.farm_seasons(
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),name text not null,
 start_month integer not null check(start_month between 1 and 12),start_day integer not null check(start_day between 1 and 31),
 end_month integer not null check(end_month between 1 and 12),end_day integer not null check(end_day between 1 and 31),
 check(make_date(2000,start_month,start_day) is not null),check(make_date(2000,end_month,end_day) is not null),unique(farm_id,name),unique(farm_id,id)
);
alter table public.farm_seasons enable row level security;
create policy seasons_read on public.farm_seasons for select to authenticated using(public.can_access_farm(farm_id));
create policy seasons_manage on public.farm_seasons for all to authenticated using(public.can_manage_farm(farm_id)) with check(public.can_manage_farm(farm_id));
grant select,insert,update,delete on public.farm_seasons to authenticated;
alter table public.tasks drop constraint tasks_recurrence_check;
alter table public.tasks add constraint tasks_recurrence_check check(recurrence in ('One-time','Daily','Weekly','Monthly','Seasonal','Yearly','Custom'));
alter table public.tasks add column season_id uuid;
alter table public.tasks add foreign key(farm_id,season_id) references public.farm_seasons(farm_id,id);
alter table public.tasks add column interval_days integer check(interval_days>0);
create index tasks_season_idx on public.tasks(farm_id,season_id);
create function public.task_occurs(p_task public.tasks,p_date date) returns boolean language plpgsql stable security invoker set search_path='' as $$
declare target date;s public.farm_seasons;begin
 if p_date is null then return false;end if;
 if p_task.scheduled_date is not null and p_date<p_task.scheduled_date then return false;end if;
 case p_task.recurrence
 when 'One-time' then return p_task.scheduled_date=p_date;
 when 'Daily' then return true;
 when 'Weekly' then return extract(dow from p_date)::int=coalesce(p_task.weekday,extract(dow from p_task.scheduled_date)::int);
 when 'Monthly' then return p_task.scheduled_date is not null and extract(day from p_date)=least(extract(day from p_task.scheduled_date),extract(day from date_trunc('month',p_date)+interval '1 month - 1 day'));
 when 'Yearly' then return p_task.scheduled_date is not null and extract(month from p_date)=extract(month from p_task.scheduled_date) and extract(day from p_date)=least(extract(day from p_task.scheduled_date),extract(day from date_trunc('month',p_date)+interval '1 month - 1 day'));
 when 'Custom' then return p_task.scheduled_date is not null and p_task.interval_days is not null and (p_date-p_task.scheduled_date)%p_task.interval_days=0;
 when 'Seasonal' then select * into s from public.farm_seasons where id=p_task.season_id and farm_id=p_task.farm_id;
 return s.id is not null and extract(month from p_date)=s.start_month and extract(day from p_date)=least(s.start_day,extract(day from date_trunc('month',p_date)+interval '1 month - 1 day'));
 else return false;end case;
end $$;
create or replace function public.set_task_status(p_task_id uuid,p_date date,p_status text) returns void language plpgsql security definer set search_path='' as $$
declare t public.tasks;allowed boolean;begin
 select * into t from public.tasks where id=p_task_id for update;
 if t.id is null or auth.uid() is null then raise exception 'Task unavailable';end if;
 allowed:=public.can_manage_farm(t.farm_id) or exists(select 1 from public.task_assignees a join public.farm_members m on m.farm_id=a.farm_id and m.worker_id=a.worker_id where a.task_id=t.id and (m.user_id=auth.uid() or m.email=lower(auth.jwt()->>'email')));
 if not allowed then raise exception 'Task completion is limited to managers and assigned workers';end if;
 if p_status not in ('Open','In progress','Completed','Cancelled') then raise exception 'Invalid status';end if;
 if t.recurrence='One-time' then update public.tasks set status=p_status,completed_at=case when p_status='Completed' then now() end,completed_by=case when p_status='Completed' then auth.uid() end,completed_by_email=case when p_status='Completed' then auth.jwt()->>'email' end where id=t.id;
 else
 if not coalesce(public.task_occurs(t,p_date),false) then raise exception 'Date does not match recurrence';end if;
 insert into public.task_occurrences(farm_id,task_id,occurrence_date,status,completed_at,completed_by,completed_by_email)
 values(t.farm_id,t.id,p_date,p_status,case when p_status='Completed' then now() end,case when p_status='Completed' then auth.uid() end,case when p_status='Completed' then auth.jwt()->>'email' end)
 on conflict(task_id,occurrence_date) do update set status=excluded.status,completed_at=excluded.completed_at,completed_by=excluded.completed_by,completed_by_email=excluded.completed_by_email;
 end if;
end $$;
drop policy farm_read on public.tasks;
create policy task_read on public.tasks for select to authenticated using(public.can_manage_farm(farm_id) or exists(select 1 from public.task_assignees a join public.farm_members m on m.farm_id=a.farm_id and m.worker_id=a.worker_id where a.task_id=tasks.id));
create function public.save_scheduled_task(p_farm_id uuid,p_id uuid,p_data jsonb,p_status text,p_expected_updated_at timestamptz default null) returns uuid language plpgsql security invoker set search_path='' as $$
declare t public.tasks;taskid uuid;wid uuid;begin
 if not public.can_manage_farm(p_farm_id) then raise exception 'Manager access required';end if;
 if p_id is not null then select * into t from public.tasks where id=p_id and farm_id=p_farm_id for update;
 if not found or (p_expected_updated_at is not null and t.updated_at<>p_expected_updated_at) then raise exception 'Task changed on another device; refresh before saving';end if;end if;
 if nullif(p_data->>'bed_id','') is not null and not exists(select 1 from public.beds where id=(p_data->>'bed_id')::uuid and farm_id=p_farm_id and (nullif(p_data->>'area_id','') is null or area_id=(p_data->>'area_id')::uuid)) then raise exception 'Bed/location mismatch';end if;
 if nullif(p_data->>'coop_id','') is not null and nullif(p_data->>'area_id','') is not null and not exists(select 1 from public.coops where id=(p_data->>'coop_id')::uuid and area_id=(p_data->>'area_id')::uuid and farm_id=p_farm_id) then raise exception 'Coop/location mismatch';end if;
 taskid:=coalesce(p_id,gen_random_uuid());
 insert into public.tasks(id,farm_id,title,event_type,scheduled_date,start_time,end_time,area_id,bed_id,crop_id,coop_id,notes,recurrence,weekday,priority,category,season_id,interval_days)
 values(taskid,p_farm_id,p_data->>'title',coalesce(p_data->>'event_type','Farm task'),nullif(p_data->>'scheduled_date','')::date,nullif(p_data->>'start_time','')::time,nullif(p_data->>'end_time','')::time,nullif(p_data->>'area_id','')::uuid,nullif(p_data->>'bed_id','')::uuid,nullif(p_data->>'crop_id','')::uuid,nullif(p_data->>'coop_id','')::uuid,p_data->>'notes',coalesce(p_data->>'recurrence','One-time'),(p_data->>'weekday')::integer,coalesce(p_data->>'priority','Normal'),coalesce(p_data->>'category','General'),nullif(p_data->>'season_id','')::uuid,(p_data->>'interval_days')::integer)
 on conflict(id) do update set title=excluded.title,event_type=excluded.event_type,scheduled_date=excluded.scheduled_date,start_time=excluded.start_time,end_time=excluded.end_time,area_id=excluded.area_id,bed_id=excluded.bed_id,crop_id=excluded.crop_id,coop_id=excluded.coop_id,notes=excluded.notes,recurrence=excluded.recurrence,weekday=excluded.weekday,priority=excluded.priority,category=excluded.category,season_id=excluded.season_id,interval_days=excluded.interval_days;
 delete from public.task_assignees where task_id=taskid;
 for wid in select value::text::uuid from jsonb_array_elements_text(coalesce(p_data->'assignee_ids','[]')) loop
 insert into public.task_assignees(farm_id,task_id,worker_id) values(p_farm_id,taskid,wid) on conflict do nothing;
 end loop;
 select * into t from public.tasks where id=taskid;
 if t.recurrence='One-time' or public.task_occurs(t,coalesce(nullif(p_data->>'occurrence_date','')::date,t.scheduled_date)) then
 perform public.set_task_status(taskid,coalesce(nullif(p_data->>'occurrence_date','')::date,t.scheduled_date),p_status);
 elsif p_status<>'Open' then raise exception 'Choose an occurrence date matching the recurrence to set its status';end if;
 return taskid;
end $$;
revoke all on function public.task_occurs(public.tasks,date),public.save_scheduled_task(uuid,uuid,jsonb,text,timestamptz) from public;
grant execute on function public.task_occurs(public.tasks,date),public.save_scheduled_task(uuid,uuid,jsonb,text,timestamptz) to authenticated;
revoke update on public.farms from authenticated;
grant update(name,total_property_area,profile) on public.farms to authenticated;
