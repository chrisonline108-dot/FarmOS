-- Green Peas Farm OS: relational persistence for the existing app.
create table public.farms (
 id uuid primary key default gen_random_uuid(), slug text not null unique, name text not null,
 total_chickens integer check(total_chickens>=0), total_property_area numeric check(total_property_area>=0),
 profile jsonb not null default '{}'::jsonb
);
create table public.farm_members (
 farm_id uuid not null references public.farms(id), email text not null check(email=lower(email)),
 user_id uuid references auth.users(id), role text not null check(role in ('owner','member')),
 primary key(farm_id,email)
);
create index farm_members_user_idx on public.farm_members(user_id);
alter table public.farm_members enable row level security;
create policy member_self on public.farm_members for select to authenticated
 using (email=lower((select auth.jwt()->>'email')) or user_id=(select auth.uid()));
grant select on public.farm_members to authenticated;
create function public.can_access_farm(p_farm_id uuid) returns boolean language sql stable security invoker set search_path='' as $$
 select exists(select 1 from public.farm_members where farm_id=p_farm_id
 and (user_id=(select auth.uid()) or email=lower((select auth.jwt()->>'email'))))
$$;
revoke all on function public.can_access_farm(uuid) from public;
grant execute on function public.can_access_farm(uuid) to authenticated;
alter table public.farms enable row level security;
create policy farm_member_read on public.farms for select to authenticated using(public.can_access_farm(id));
create policy farm_owner_update on public.farms for update to authenticated
 using(exists(select 1 from public.farm_members where farm_id=id and role='owner'))
 with check(exists(select 1 from public.farm_members where farm_id=id and role='owner'));
grant select,update on public.farms to authenticated;
create table public.areas (
 id uuid primary key default gen_random_uuid(), farm_id uuid not null references public.farms(id),
 name text not null, kind text not null check(kind in ('facility','production')), classification text,
 dimensions text, capacity numeric, coordinates jsonb, layout text, notes text,
 unique(farm_id,name), unique(farm_id,id)
);
create table public.beds (
 id uuid primary key default gen_random_uuid(), farm_id uuid not null references public.farms(id),
 area_id uuid not null, code text not null, length_m numeric check(length_m>0), width_m numeric check(width_m>0),
 purpose text not null default 'Production' check(purpose in ('Production','Reserve / Habitat')),
 foreign key(farm_id,area_id) references public.areas(farm_id,id), unique(farm_id,code),unique(farm_id,id)
);
create table public.workers (
 id uuid primary key default gen_random_uuid(), farm_id uuid not null references public.farms(id),
 name text not null, role text, phone text, archived boolean not null default false,
 unique(farm_id,name),unique(farm_id,id)
);
create table public.coops (
 id uuid primary key default gen_random_uuid(), farm_id uuid not null references public.farms(id),
 area_id uuid not null, name text not null check(name in ('Chicken Coop A','Chicken Coop B')),
 bird_count integer check(bird_count>=0), foreign key(farm_id,area_id) references public.areas(farm_id,id),
 unique(farm_id,name),unique(farm_id,id)
);
create table public.crops (
 id uuid primary key default gen_random_uuid(), farm_id uuid not null references public.farms(id),name text not null,
 unique(farm_id,name),unique(farm_id,id)
);
create table public.plantings (
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),
 crop_id uuid not null,bed_id uuid,area_id uuid,planted_on date,nursery_start_on date,transplant_on date,expected_harvest_on date,
 stage text not null default 'Planned' check(stage in ('Planned','Active','Vegetative','Flowering','Fruit development','Ready to harvest','Finished')),
 notes text,legacy_key text,
 foreign key(farm_id,crop_id) references public.crops(farm_id,id),foreign key(farm_id,bed_id) references public.beds(farm_id,id),
 foreign key(farm_id,area_id) references public.areas(farm_id,id),unique(farm_id,legacy_key),unique(farm_id,id)
);
create table public.planting_plans (
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),crop_id uuid not null,
 bed_id uuid,area_id uuid,planned_on date,notes text,legacy_key text,
 foreign key(farm_id,crop_id) references public.crops(farm_id,id),foreign key(farm_id,bed_id) references public.beds(farm_id,id),
 foreign key(farm_id,area_id) references public.areas(farm_id,id),unique(farm_id,legacy_key),unique(farm_id,id)
);
create table public.tasks (
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),title text not null check(length(trim(title))>0),
 event_type text not null default 'Farm task' check(event_type in ('Farm task','Planting','Harvest','Irrigation','Scouting','Fertility','Maintenance','Coop','Cleaning','Nursery','Other')),
 scheduled_date date,start_time time,end_time time,worker_id uuid,area_id uuid,bed_id uuid,crop_id uuid,coop_id uuid,notes text,
 recurrence text not null default 'One-time' check(recurrence in ('One-time','Daily','Weekly','Monthly')),
 weekday integer check(weekday between 0 and 6),status text not null default 'Open' check(status in ('Open','In progress','Completed','Cancelled')),
 routine_key text,legacy_key text,
 foreign key(farm_id,worker_id) references public.workers(farm_id,id),foreign key(farm_id,area_id) references public.areas(farm_id,id),
 foreign key(farm_id,bed_id) references public.beds(farm_id,id),foreign key(farm_id,crop_id) references public.crops(farm_id,id),
 foreign key(farm_id,coop_id) references public.coops(farm_id,id),
 check(end_time is null or (start_time is not null and end_time>start_time)),
 unique(farm_id,routine_key),unique(farm_id,legacy_key),unique(farm_id,id)
);
create table public.task_occurrences (
 farm_id uuid not null references public.farms(id),task_id uuid not null,occurrence_date date not null,
 status text not null check(status in ('Open','In progress','Completed','Cancelled')),
 foreign key(farm_id,task_id) references public.tasks(farm_id,id) on delete cascade,primary key(task_id,occurrence_date)
);
create table public.coop_daily_records (
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),coop_id uuid not null,record_date date not null,
 morning integer check(morning>=0),evening integer check(evening>=0),total integer check(total>=0),saleable integer check(saleable>=0),
 broken integer check(broken>=0),cafe integer check(cafe>=0),sold integer check(sold>=0),stock integer check(stock>=0),
 feed numeric check(feed>=0),water text,sick integer check(sick>=0),mortality integer check(mortality>=0),treatment text,behaviour text,
 worker_id uuid,worker_note text,notes text,
 foreign key(farm_id,coop_id) references public.coops(farm_id,id),foreign key(farm_id,worker_id) references public.workers(farm_id,id),
 check(morning is null or evening is null or total=morning+evening),
 check(total is null or coalesce(morning,0)+coalesce(evening,0)<=total),
 check(total is null or coalesce(saleable,0)+coalesce(broken,0)<=total),
 check(total is null or saleable is null or broken is null or total=saleable+broken),
 unique(coop_id,record_date),unique(farm_id,id)
);
create table public.coop_cleaning (
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),coop_id uuid not null,
 type text not null check(type in ('mini','normal','deep')),cleaning_date date not null,
 completion text not null check(completion in ('Completed','Partial','Not completed')),next_due date,
 worker_id uuid,worker_note text,notes text,created_at timestamptz not null default now(),legacy_key text,
 foreign key(farm_id,coop_id) references public.coops(farm_id,id),foreign key(farm_id,worker_id) references public.workers(farm_id,id),
 check(next_due is null or next_due>=cleaning_date),unique(farm_id,legacy_key),unique(farm_id,id)
);
create table public.inventory (
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),item text not null,category text not null,
 qty numeric check(qty>=0),min numeric check(min>=0),unit text,notes text,unique(farm_id,item,category),unique(farm_id,id)
);
create table public.harvest_records (
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),planting_id uuid,crop_id uuid,bed_id uuid,
 area_id uuid,worker_id uuid,harvest_date date not null,quantity numeric check(quantity>=0),unit text,notes text,
 foreign key(farm_id,planting_id) references public.plantings(farm_id,id),foreign key(farm_id,crop_id) references public.crops(farm_id,id),
 foreign key(farm_id,bed_id) references public.beds(farm_id,id),foreign key(farm_id,area_id) references public.areas(farm_id,id),
 foreign key(farm_id,worker_id) references public.workers(farm_id,id),unique(farm_id,id)
);
create table public.farm_records (
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),record_type text not null,
 record_date date,area_id uuid,bed_id uuid,crop_id uuid,coop_id uuid,worker_id uuid,inventory_id uuid,
 details jsonb not null default '{}'::jsonb,notes text,
 foreign key(farm_id,area_id) references public.areas(farm_id,id),foreign key(farm_id,bed_id) references public.beds(farm_id,id),
 foreign key(farm_id,crop_id) references public.crops(farm_id,id),foreign key(farm_id,coop_id) references public.coops(farm_id,id),
 foreign key(farm_id,worker_id) references public.workers(farm_id,id),foreign key(farm_id,inventory_id) references public.inventory(farm_id,id)
);
create table public.legacy_imports (
 farm_id uuid not null references public.farms(id),fingerprint text not null,imported_at timestamptz not null default now(),
 primary key(farm_id,fingerprint)
);
-- All operational tables use the same explicit farm membership boundary.
do $$ declare t text; begin
 foreach t in array array['areas','beds','workers','coops','crops','plantings','planting_plans','tasks','task_occurrences','coop_daily_records','coop_cleaning','inventory','harvest_records','farm_records','legacy_imports'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('create policy farm_access on public.%I for all to authenticated using (public.can_access_farm(farm_id)) with check (public.can_access_farm(farm_id))',t);
 execute format('grant select,insert,update,delete on public.%I to authenticated',t);
 execute format('revoke all on public.%I from anon',t);
 execute format('create index %I on public.%I(farm_id)',t||'_farm_idx',t);
 end loop;
end $$;
create index tasks_date_idx on public.tasks(farm_id,scheduled_date);
create index task_occurrences_date_idx on public.task_occurrences(farm_id,occurrence_date);
create index coop_cleaning_latest_idx on public.coop_cleaning(coop_id,type,cleaning_date desc,created_at desc);
-- Index all composite relationship keys, including their farm boundary.
do $$ declare r record; begin
 for r in select c.table_name,c.column_name from information_schema.columns c
 where c.table_schema='public' and c.column_name in ('area_id','bed_id','worker_id','crop_id','coop_id','planting_id','inventory_id') loop
 execute format('create index %I on public.%I(farm_id,%I)',r.table_name||'_'||r.column_name||'_idx',r.table_name,r.column_name);
 end loop;
end $$;
create view public.feed_logs with(security_invoker=true) as select id,farm_id,coop_id,record_date,feed,worker_id,notes from public.coop_daily_records where feed is not null;
create view public.coop_treatments with(security_invoker=true) as select id,farm_id,coop_id,record_date,treatment,worker_id from public.coop_daily_records where treatment is not null;
grant select on public.feed_logs,public.coop_treatments to authenticated;
create function public.set_task_status(p_task_id uuid,p_date date,p_status text) returns void
 language plpgsql security invoker set search_path='' as $$
 declare t public.tasks; valid boolean; target_day integer;
 begin
 select * into t from public.tasks where id=p_task_id for update;
 if not found then raise exception 'Task unavailable'; end if;
 if p_status not in ('Open','In progress','Completed','Cancelled') then raise exception 'Invalid status';end if;
 if t.recurrence='One-time' then update public.tasks set status=p_status where id=t.id;
 else
 if p_date is null or (t.scheduled_date is not null and p_date<t.scheduled_date) then raise exception 'Invalid occurrence date';end if;
 valid:=t.recurrence='Daily';
 if t.recurrence='Weekly' then valid:=extract(dow from p_date)::int=coalesce(t.weekday,extract(dow from t.scheduled_date)::int);end if;
 if t.recurrence='Monthly' and t.scheduled_date is not null then
 target_day:=least(extract(day from t.scheduled_date)::int,extract(day from (date_trunc('month',p_date)+interval '1 month - 1 day'))::int);
 valid:=extract(day from p_date)::int=target_day;
 end if;
 if not coalesce(valid,false) then raise exception 'Date does not match recurrence';end if;
 insert into public.task_occurrences(farm_id,task_id,occurrence_date,status) values(t.farm_id,t.id,p_date,p_status)
 on conflict(task_id,occurrence_date) do update set status=excluded.status;
 end if;
 end $$;
create function public.adjust_inventory(p_id uuid,p_delta numeric) returns void language plpgsql security invoker set search_path='' as $$
 begin
 update public.inventory set qty=greatest(0,qty+p_delta) where id=p_id and qty is not null;
 if not found then raise exception 'Record an observed quantity first';end if;
 end $$;
create function public.set_coop_counts(p_farm_id uuid,p_a integer,p_b integer) returns void language plpgsql security invoker set search_path='' as $$
 declare total integer;begin
 select total_chickens into total from public.farms where id=p_farm_id for update;
 if not found then raise exception 'Farm unavailable';end if;
 if p_a<0 or p_b<0 or p_a>total or p_b>total or (p_a is not null and p_b is not null and p_a+p_b<>total) then raise exception 'Observed counts must total the confirmed flock';end if;
 update public.coops set bird_count=case name when 'Chicken Coop A' then p_a when 'Chicken Coop B' then p_b end where farm_id=p_farm_id;
 end $$;
revoke all on function public.set_task_status(uuid,date,text),public.adjust_inventory(uuid,numeric),public.set_coop_counts(uuid,integer,integer) from public;
grant execute on function public.set_task_status(uuid,date,text),public.adjust_inventory(uuid,numeric),public.set_coop_counts(uuid,integer,integer) to authenticated;

create function public.import_legacy_farm(p_farm_id uuid,p_payload jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare fingerprint text:=md5(p_payload::text);x jsonb;idx bigint;w uuid;b uuid;a uuid;c uuid;cp uuid;d text;n text;r jsonb;k text;
begin
 if not public.can_access_farm(p_farm_id) then raise exception 'Farm access required';end if;
 if p_payload->>'version'<>'4' then raise exception 'Only verified version 4 records can be imported';end if;
 insert into public.legacy_imports(farm_id,fingerprint) values(p_farm_id,fingerprint) on conflict do nothing;
 if not found then return jsonb_build_object('already_imported',true);end if;
 -- Preserve the complete prior state, including fields without a structured equivalent.
 insert into public.farm_records(farm_id,record_type,details) values(p_farm_id,'Legacy browser import',p_payload);
 for x in select value from jsonb_array_elements(coalesce(p_payload->'workers','[]')) loop
 insert into public.workers(farm_id,name,role,phone) values(p_farm_id,x->>'name',nullif(x->>'role',''),nullif(x->>'phone','')) on conflict(farm_id,name) do nothing;
 end loop;
 for x,idx in select value,ordinality from jsonb_array_elements(coalesce(p_payload->'tasks','[]')) with ordinality loop
 select id into w from public.workers where farm_id=p_farm_id and name=x->>'owner';
 k:=md5(coalesce(x->>'title','')||':'||coalesce(x->>'owner','')||':'||coalesce(x->>'time','')||':'||idx);
 insert into public.tasks(farm_id,title,worker_id,start_time,status,legacy_key) values(p_farm_id,x->>'title',w,
 case when x->>'time' ~ '^\d{2}:\d{2}' then (x->>'time')::time else null end,
 case when (x->>'done')::boolean then 'Completed' else 'Open' end,k) on conflict(farm_id,legacy_key) do nothing;
 end loop;
 for x,idx in select value,ordinality from jsonb_array_elements(coalesce(p_payload->'crops','[]')) with ordinality loop
 insert into public.crops(farm_id,name) values(p_farm_id,x->>'name') on conflict(farm_id,name) do nothing;
 select id into c from public.crops where farm_id=p_farm_id and name=x->>'name';
 select id,area_id into b,a from public.beds where farm_id=p_farm_id and code=x->>'location';
 insert into public.plantings(farm_id,crop_id,bed_id,area_id,planted_on,stage,legacy_key)
 values(p_farm_id,c,b,a,nullif(x->>'planted','')::date,x->>'stage',md5(coalesce(x->>'name','')||':'||coalesce(x->>'location','')||':'||idx)) on conflict(farm_id,legacy_key) do nothing;
 end loop;
 for x,idx in select value,ordinality from jsonb_array_elements(coalesce(p_payload->'plans','[]')) with ordinality loop
 insert into public.crops(farm_id,name) values(p_farm_id,x->>'crop') on conflict(farm_id,name) do nothing;
 select id into c from public.crops where farm_id=p_farm_id and name=x->>'crop';
 select id,area_id into b,a from public.beds where farm_id=p_farm_id and code=x->>'area';
 if a is null then select id into a from public.areas where farm_id=p_farm_id and name=x->>'area';end if;
 insert into public.planting_plans(farm_id,crop_id,bed_id,area_id,planned_on,notes,legacy_key)
 values(p_farm_id,c,b,a,nullif(x->>'date','')::date,nullif(x->>'notes',''),md5(coalesce(x->>'crop','')||':'||coalesce(x->>'area','')||':'||coalesce(x->>'date','')||':'||idx)) on conflict(farm_id,legacy_key) do nothing;
 end loop;
 for x in select value from jsonb_array_elements(coalesce(p_payload->'inventory','[]')) loop
 insert into public.inventory(farm_id,item,category,qty,min) values(p_farm_id,x->>'item',x->>'category',(x->>'qty')::numeric,(x->>'min')::numeric)
 on conflict(farm_id,item,category) do update set qty=coalesce(public.inventory.qty,excluded.qty),min=coalesce(public.inventory.min,excluded.min);
 end loop;
 for d,r in select key,value from jsonb_each(coalesce(p_payload->'records','{}')) loop
 for n,x in select key,value from jsonb_each(r) loop
 select id into cp from public.coops where farm_id=p_farm_id and name=n;
 if cp is null then raise exception 'Unrecognized coop in prior data';end if;
 select id into w from public.workers where farm_id=p_farm_id and name=x->>'worker';
 insert into public.coop_daily_records(farm_id,coop_id,record_date,morning,evening,total,saleable,broken,cafe,sold,stock,feed,water,sick,mortality,treatment,behaviour,worker_id,worker_note,notes)
 values(p_farm_id,cp,d::date,(x->>'morning')::integer,(x->>'evening')::integer,(x->>'total')::integer,(x->>'saleable')::integer,(x->>'broken')::integer,(x->>'cafe')::integer,(x->>'sold')::integer,(x->>'stock')::integer,(x->>'feed')::numeric,x->>'water',(x->>'sick')::integer,(x->>'mortality')::integer,x->>'treatment',x->>'behaviour',w,x->>'worker',x->>'notes') on conflict(coop_id,record_date) do nothing;
 end loop;end loop;
 for x,idx in select value,ordinality from jsonb_array_elements(coalesce(p_payload->'cleaning','[]')) with ordinality loop
 select id into cp from public.coops where farm_id=p_farm_id and name=x->>'coop';
 select id into w from public.workers where farm_id=p_farm_id and name=x->>'worker';
 insert into public.coop_cleaning(farm_id,coop_id,type,cleaning_date,completion,next_due,worker_id,worker_note,notes,created_at,legacy_key)
 values(p_farm_id,cp,x->>'type',(x->>'date')::date,x->>'completion',(x->>'next')::date,w,x->>'worker',x->>'notes',coalesce((x->>'savedAt')::timestamptz,now()),md5(x::text||':'||idx)) on conflict(farm_id,legacy_key) do nothing;
 end loop;
 if coalesce(p_payload->'birds','{}')<>'{}'::jsonb then
 perform public.set_coop_counts(p_farm_id,
 coalesce((select bird_count from public.coops where farm_id=p_farm_id and name='Chicken Coop A'),(p_payload->'birds'->>'Chicken Coop A')::int),
 coalesce((select bird_count from public.coops where farm_id=p_farm_id and name='Chicken Coop B'),(p_payload->'birds'->>'Chicken Coop B')::int));
 end if;
 return jsonb_build_object('imported',true);
end $$;
revoke all on function public.import_legacy_farm(uuid,jsonb) from public;
grant execute on function public.import_legacy_farm(uuid,jsonb) to authenticated;
create function public.farm_record_updated_at() returns trigger language plpgsql security invoker set search_path='' as $$begin new.updated_at=clock_timestamp();return new;end$$;
revoke all on function public.farm_record_updated_at() from public;
do $$ declare t text;begin
 foreach t in array array['areas','beds','workers','coops','crops','plantings','planting_plans','tasks','task_occurrences','coop_daily_records','coop_cleaning','inventory','harvest_records','farm_records'] loop
 execute format('alter table public.%I add column updated_at timestamptz not null default now()',t);
 execute format('create trigger set_updated_at before update on public.%I for each row execute function public.farm_record_updated_at()',t);
 end loop;
end $$;

-- Phase A: reversible crop lifecycle, shared task assignments, audited flock changes.
alter table public.farm_members drop constraint farm_members_role_check;
alter table public.farm_members add constraint farm_members_role_check check(role in ('owner','manager','worker'));
alter table public.farm_members add column worker_id uuid;
alter table public.farm_members add foreign key(farm_id,worker_id) references public.workers(farm_id,id);
create index farm_members_worker_idx on public.farm_members(farm_id,worker_id);
create function public.can_manage_farm(p_farm_id uuid) returns boolean language sql stable security invoker set search_path='' as $$
 select exists(select 1 from public.farm_members where farm_id=p_farm_id and role in ('owner','manager')
 and (user_id=(select auth.uid()) or email=lower((select auth.jwt()->>'email')))) $$;
revoke all on function public.can_manage_farm(uuid) from public;
grant execute on function public.can_manage_farm(uuid) to authenticated;
create table public.task_assignees(
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),task_id uuid not null,worker_id uuid not null,
 assigned_at timestamptz not null default now(),foreign key(farm_id,task_id) references public.tasks(farm_id,id) on delete cascade,
 foreign key(farm_id,worker_id) references public.workers(farm_id,id),unique(task_id,worker_id)
);
create index task_assignees_worker_idx on public.task_assignees(farm_id,worker_id);
alter table public.tasks add column priority text not null default 'Normal' check(priority in ('Low','Normal','High','Urgent'));
alter table public.tasks add column category text not null default 'General';
alter table public.tasks add column completed_at timestamptz;
alter table public.tasks add column completed_by uuid references auth.users(id);
alter table public.tasks add column completed_by_email text;
alter table public.task_occurrences add column completed_at timestamptz;
alter table public.task_occurrences add column completed_by uuid references auth.users(id);
alter table public.task_occurrences add column completed_by_email text;
create table public.crop_stage_history(
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),planting_id uuid not null,crop_id uuid not null,bed_id uuid,
 previous_stage text,new_stage text not null,changed_by uuid references auth.users(id),changed_by_email text,changed_at timestamptz not null default now(),reason text,
 foreign key(farm_id,planting_id) references public.plantings(farm_id,id),foreign key(farm_id,crop_id) references public.crops(farm_id,id),foreign key(farm_id,bed_id) references public.beds(farm_id,id)
);
create index crop_stage_history_planting_idx on public.crop_stage_history(planting_id,changed_at desc);
alter table public.plantings add column stage_changed_at timestamptz;
create function public.audit_crop_stage() returns trigger language plpgsql security definer set search_path='' as $$
declare stages text[]:=array['Planned','Active','Vegetative','Flowering','Fruit development','Ready to harvest','Finished'];begin
 if old.stage is distinct from new.stage then
 if auth.uid() is not null and not public.can_manage_farm(new.farm_id) then raise exception 'Manager access required';end if;
 if abs(array_position(stages,new.stage)-array_position(stages,old.stage))<>1 then raise exception 'Only adjacent lifecycle stages are valid';end if;
 new.stage_changed_at:=now();
 insert into public.crop_stage_history(farm_id,planting_id,crop_id,bed_id,previous_stage,new_stage,changed_by,changed_by_email,reason)
 values(new.farm_id,new.id,new.crop_id,new.bed_id,old.stage,new.stage,auth.uid(),auth.jwt()->>'email',nullif(current_setting('farm.stage_reason',true),''));
 end if;return new;end $$;
revoke all on function public.audit_crop_stage() from public;
create trigger audit_stage before update on public.plantings for each row execute function public.audit_crop_stage();
create function public.change_crop_stage(p_id uuid,p_direction text,p_reason text default null) returns void language plpgsql security invoker set search_path='' as $$
declare p public.plantings;stages text[]:=array['Planned','Active','Vegetative','Flowering','Fruit development','Ready to harvest','Finished'];i int;begin
 select * into p from public.plantings where id=p_id for update;if not found or not public.can_manage_farm(p.farm_id) then raise exception 'Manager access required';end if;
 i:=array_position(stages,p.stage)+case p_direction when 'advance' then 1 when 'previous' then -1 else 0 end;
 if p_direction not in ('advance','previous') or i<1 or i>array_length(stages,1) then raise exception 'No valid stage in that direction';end if;
 perform set_config('farm.stage_reason',coalesce(p_reason,''),true);update public.plantings set stage=stages[i] where id=p.id;
end $$;
create table public.chicken_count_history(
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),coop_id uuid not null,
 action text not null check(action in ('Count','Add','Remove','Transfer in','Transfer out')),quantity integer check(quantity>=0),previous_count integer,new_count integer check(new_count>=0),
 reason text not null,notes text,transfer_id uuid,changed_by uuid references auth.users(id),changed_by_email text,created_at timestamptz not null default now(),
 foreign key(farm_id,coop_id) references public.coops(farm_id,id)
);
create index chicken_history_coop_idx on public.chicken_count_history(coop_id,created_at desc);
create or replace function public.set_coop_counts(p_farm_id uuid,p_a integer,p_b integer) returns void language plpgsql security definer set search_path='' as $$
declare c public.coops;observed integer;begin
 if not public.can_manage_farm(p_farm_id) then raise exception 'Manager access required';end if;
 perform 1 from public.farms where id=p_farm_id for update;
 if p_a<0 or p_b<0 then raise exception 'Chicken counts cannot be negative';end if;
 for c in select * from public.coops where farm_id=p_farm_id order by id for update loop
 observed:=case c.name when 'Chicken Coop A' then p_a else p_b end;
 if c.bird_count is distinct from observed then
 if observed is null and c.bird_count is not null then raise exception 'Use an adjustment to change a known count';end if;
 insert into public.chicken_count_history(farm_id,coop_id,action,quantity,previous_count,new_count,reason,changed_by,changed_by_email)
 values(p_farm_id,c.id,'Count',case when c.bird_count is null then null else abs(observed-c.bird_count) end,c.bird_count,observed,'Observed count',auth.uid(),auth.jwt()->>'email');
 update public.coops set bird_count=observed where id=c.id;
 end if;end loop;
 if p_a is not null and p_b is not null then update public.farms set total_chickens=p_a+p_b where id=p_farm_id;
 elsif greatest(p_a,p_b)>(select total_chickens from public.farms where id=p_farm_id) then update public.farms set total_chickens=null where id=p_farm_id;end if;
end $$;
create function public.adjust_chickens(p_coop_id uuid,p_action text,p_quantity integer,p_reason text,p_notes text default null,p_to_coop uuid default null) returns void language plpgsql security definer set search_path='' as $$
declare c public.coops;dest public.coops;new_count int;transfer uuid:=gen_random_uuid();begin
 select * into c from public.coops where id=p_coop_id;
 if not found or not public.can_manage_farm(c.farm_id) then raise exception 'Manager access required';end if;
 perform 1 from public.farms where id=c.farm_id for update;
 select * into c from public.coops where id=p_coop_id for update;
 if p_quantity is null or p_quantity<=0 or nullif(trim(p_reason),'') is null then raise exception 'Positive quantity and reason required';end if;
 if c.bird_count is null then raise exception 'Record the observed coop count first';end if;
 if p_action='Add' then new_count:=c.bird_count+p_quantity;
 elsif p_action in ('Remove','Transfer') then new_count:=c.bird_count-p_quantity;
 else raise exception 'Invalid action';end if;
 if new_count<0 then raise exception 'Not enough chickens in this coop';end if;
 if p_action='Transfer' then
 select * into dest from public.coops where id=p_to_coop and farm_id=c.farm_id for update;
 if not found or dest.id=c.id or dest.bird_count is null then raise exception 'Choose a different coop with an observed count';end if;
 update public.coops set bird_count=dest.bird_count+p_quantity where id=dest.id;
 insert into public.chicken_count_history(farm_id,coop_id,action,quantity,previous_count,new_count,reason,notes,transfer_id,changed_by,changed_by_email)
 values(c.farm_id,dest.id,'Transfer in',p_quantity,dest.bird_count,dest.bird_count+p_quantity,p_reason,p_notes,transfer,auth.uid(),auth.jwt()->>'email');
 else update public.farms set total_chickens=total_chickens+case p_action when 'Add' then p_quantity else -p_quantity end where id=c.farm_id;end if;
 update public.coops set bird_count=new_count where id=c.id;
 insert into public.chicken_count_history(farm_id,coop_id,action,quantity,previous_count,new_count,reason,notes,transfer_id,changed_by,changed_by_email)
 values(c.farm_id,c.id,case p_action when 'Transfer' then 'Transfer out' else p_action end,p_quantity,c.bird_count,new_count,p_reason,p_notes,case when p_action='Transfer' then transfer end,auth.uid(),auth.jwt()->>'email');
end $$;
-- A worker may read the farm, but only managers can change operational records directly.
do $$declare t text;begin
 foreach t in array array['areas','beds','workers','coops','crops','plantings','planting_plans','tasks','task_occurrences','coop_daily_records','coop_cleaning','inventory','harvest_records','farm_records','legacy_imports'] loop
 execute format('drop policy farm_access on public.%I',t);
 execute format('create policy farm_read on public.%I for select to authenticated using(public.can_access_farm(farm_id))',t);
 execute format('create policy farm_manage on public.%I for all to authenticated using(public.can_manage_farm(farm_id)) with check(public.can_manage_farm(farm_id))',t);
 end loop;
 foreach t in array array['task_assignees','crop_stage_history','chicken_count_history'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('create policy farm_read on public.%I for select to authenticated using(public.can_access_farm(farm_id))',t);
 execute format('grant select on public.%I to authenticated',t);
 execute format('create index %I on public.%I(farm_id)',t||'_farm_idx',t);
 end loop;
end $$;
create policy assignee_manage on public.task_assignees for all to authenticated using(public.can_manage_farm(farm_id)) with check(public.can_manage_farm(farm_id));
grant insert,update,delete on public.task_assignees to authenticated;
-- Persist initial single-worker assignments from imported task records as relationships.
create function public.sync_initial_assignee() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.worker_id is not null then insert into public.task_assignees(farm_id,task_id,worker_id) values(new.farm_id,new.id,new.worker_id) on conflict do nothing;end if;return new;end $$;
revoke all on function public.sync_initial_assignee() from public;
create trigger initial_task_assignee after insert on public.tasks for each row execute function public.sync_initial_assignee();
revoke all on function public.change_crop_stage(uuid,text,text),public.adjust_chickens(uuid,text,integer,text,text,uuid) from public;
grant execute on function public.change_crop_stage(uuid,text,text),public.adjust_chickens(uuid,text,integer,text,text,uuid) to authenticated;
revoke update on public.coops from authenticated;

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

insert into public.farms(slug,name,total_chickens,total_property_area,profile) values('green-peas','Green Peas',90,null,'{"location":"Jeita, Lebanon","elevation_approx_m":400}'::jsonb);
insert into public.farm_members(farm_id,email,role) select id,'chrisonline108@gmail.com','owner' from public.farms where slug='green-peas';
insert into public.areas(farm_id,name,kind) select id,'Ruin','facility' from public.farms where slug='green-peas';
insert into public.areas(farm_id,name,kind) select id,'Cellar','facility' from public.farms where slug='green-peas';
insert into public.areas(farm_id,name,kind) select id,'Chicken Coop A','facility' from public.farms where slug='green-peas';
insert into public.areas(farm_id,name,kind) select id,'Chicken Coop B','facility' from public.farms where slug='green-peas';
insert into public.areas(farm_id,name,kind) select id,'Toolshed','facility' from public.farms where slug='green-peas';
insert into public.areas(farm_id,name,kind) select id,'Irrigation Station','facility' from public.farms where slug='green-peas';
insert into public.areas(farm_id,name,kind) select id,'Marketplace / Breakfast Section','facility' from public.farms where slug='green-peas';
insert into public.areas(farm_id,name,kind) select id,'Zone 5','facility' from public.farms where slug='green-peas';
insert into public.areas(farm_id,name,kind) select id,'Compost System','facility' from public.farms where slug='green-peas';
insert into public.areas(farm_id,name,kind) select id,'Sheep and Goat House','facility' from public.farms where slug='green-peas';
insert into public.areas(farm_id,name,kind) select id,'Ferre House','facility' from public.farms where slug='green-peas';
insert into public.areas(farm_id,name,kind) select id,'Ducks House','facility' from public.farms where slug='green-peas';
insert into public.areas(farm_id,name,kind) select id,'Vehicle Shed','facility' from public.farms where slug='green-peas';
insert into public.areas(farm_id,name,kind) select id,'Nursery','facility' from public.farms where slug='green-peas';
insert into public.areas(farm_id,name,kind) select id,'Storage','facility' from public.farms where slug='green-peas';
insert into public.areas(farm_id,name,kind,classification) select id,'Z1','production','Greenhouse' from public.farms where slug='green-peas';
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z1-B1',23,0.8,'Production' from public.areas where name='Z1' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z1-B2',23,0.8,'Production' from public.areas where name='Z1' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z1-B3',23,0.8,'Production' from public.areas where name='Z1' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z1-B4',23,0.8,'Production' from public.areas where name='Z1' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z1-B5',23,0.8,'Production' from public.areas where name='Z1' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.areas(farm_id,name,kind,classification) select id,'Z2','production','Greenhouse' from public.farms where slug='green-peas';
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z2-B1',28,0.8,'Production' from public.areas where name='Z2' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z2-B2',28,0.8,'Production' from public.areas where name='Z2' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z2-B3',28,0.8,'Production' from public.areas where name='Z2' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z2-B4',28,0.8,'Production' from public.areas where name='Z2' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z2-B5',28,0.8,'Production' from public.areas where name='Z2' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.areas(farm_id,name,kind,classification) select id,'Z7','production','Polytunnel' from public.farms where slug='green-peas';
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z7-B1',20,0.8,'Production' from public.areas where name='Z7' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z7-B2',20,0.8,'Production' from public.areas where name='Z7' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z7-B3',10,0.8,'Production' from public.areas where name='Z7' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.areas(farm_id,name,kind,classification) select id,'Z8','production','Polytunnel' from public.farms where slug='green-peas';
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z8-B1',16,0.8,'Production' from public.areas where name='Z8' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z8-B2',16,0.8,'Production' from public.areas where name='Z8' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.areas(farm_id,name,kind,classification) select id,'Z9','production','Polytunnel' from public.farms where slug='green-peas';
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z9-B1',25,0.8,'Production' from public.areas where name='Z9' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z9-B2',25,0.8,'Production' from public.areas where name='Z9' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.areas(farm_id,name,kind,classification) select id,'Z10','production','Polytunnel' from public.farms where slug='green-peas';
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z10-B1',35,0.8,'Production' from public.areas where name='Z10' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z10-B2',35,0.8,'Production' from public.areas where name='Z10' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.areas(farm_id,name,kind,classification) select id,'Z13','production','Open Field' from public.farms where slug='green-peas';
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z13-B1',30,0.8,'Production' from public.areas where name='Z13' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z13-B2',30,0.8,'Production' from public.areas where name='Z13' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z13-B3',30,0.8,'Production' from public.areas where name='Z13' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.areas(farm_id,name,kind,classification) select id,'Z14','production','Open Field' from public.farms where slug='green-peas';
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z14-B1',15,0.8,'Production' from public.areas where name='Z14' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z14-B2',15,0.8,'Production' from public.areas where name='Z14' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Z14-B3',15,0.8,'Production' from public.areas where name='Z14' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.areas(farm_id,name,kind,classification) select id,'Y1','production','Polytunnel' from public.farms where slug='green-peas';
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Y1-B1',15,0.8,'Production' from public.areas where name='Y1' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Y1-B2',15,0.8,'Production' from public.areas where name='Y1' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Y1-B3',15,0.8,'Production' from public.areas where name='Y1' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.areas(farm_id,name,kind,classification) select id,'Y2','production','Open Field' from public.farms where slug='green-peas';
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Y2-B1',15,0.8,'Production' from public.areas where name='Y2' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'Y2-B2',15,0.8,'Production' from public.areas where name='Y2' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.areas(farm_id,name,kind,classification) select id,'S1','production','Polytunnel' from public.farms where slug='green-peas';
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'S1',6,1.5,'Production' from public.areas where name='S1' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.areas(farm_id,name,kind,classification) select id,'S2','production','Polytunnel' from public.farms where slug='green-peas';
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'S2',6,1.5,'Production' from public.areas where name='S2' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.areas(farm_id,name,kind,classification) select id,'S3','production','Polytunnel' from public.farms where slug='green-peas';
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'S3',6,1.5,'Production' from public.areas where name='S3' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.areas(farm_id,name,kind,classification) select id,'S4','production','Polytunnel' from public.farms where slug='green-peas';
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'S4',6,1.5,'Production' from public.areas where name='S4' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.areas(farm_id,name,kind,classification) select id,'S5','production','Polytunnel' from public.farms where slug='green-peas';
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'S5',6,1.5,'Production' from public.areas where name='S5' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.areas(farm_id,name,kind,classification) select id,'S6','production','Open Field' from public.farms where slug='green-peas';
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'S6',6,1.5,'Production' from public.areas where name='S6' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.areas(farm_id,name,kind,classification) select id,'S7','production','Polytunnel' from public.farms where slug='green-peas';
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'S7',6,1.5,'Production' from public.areas where name='S7' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.areas(farm_id,name,kind,classification) select id,'S8','production','Reserve / Habitat' from public.farms where slug='green-peas';
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'S8',6,1.5,'Reserve / Habitat' from public.areas where name='S8' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.areas(farm_id,name,kind,classification) select id,'S9','production','Reserve / Habitat' from public.farms where slug='green-peas';
insert into public.beds(farm_id,area_id,code,length_m,width_m,purpose) select farm_id,id,'S9',6,1.5,'Reserve / Habitat' from public.areas where name='S9' and farm_id=(select id from public.farms where slug='green-peas');
insert into public.coops(farm_id,area_id,name) select farm_id,id,name from public.areas where name='Chicken Coop A';
insert into public.coops(farm_id,area_id,name) select farm_id,id,name from public.areas where name='Chicken Coop B';
insert into public.workers(farm_id,name,role,phone) select id,'Haidar','Farm operations',null from public.farms where slug='green-peas';
insert into public.workers(farm_id,name,role,phone) select id,'Soufe','Farm operations',null from public.farms where slug='green-peas';
insert into public.workers(farm_id,name,role,phone) select id,'Fady','Farm operations',null from public.farms where slug='green-peas';
insert into public.workers(farm_id,name,role,phone) select id,'Koussai','Farm operations',null from public.farms where slug='green-peas';
insert into public.workers(farm_id,name,role,phone) select id,'Omran','Farm operations',null from public.farms where slug='green-peas';
insert into public.workers(farm_id,name,role,phone) select id,'Yamen','Farm operations',null from public.farms where slug='green-peas';
insert into public.workers(farm_id,name,role,phone) select id,'Amjat','Farm operations',null from public.farms where slug='green-peas';
insert into public.workers(farm_id,name,role,phone) select id,'Hsein','Farm operations',null from public.farms where slug='green-peas';
insert into public.workers(farm_id,name,role,phone) select id,'Jassem','Farm operations',null from public.farms where slug='green-peas';
insert into public.workers(farm_id,name,role,phone) select id,'Chris','Farm operations',null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Chicken feed','Feed',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Seeds / seed lots','Seeds',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Seedlings / transplants','Seedlings',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Chicken bedding','Chicken bedding',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Mulch','Other',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Nursery trays / media','Nursery',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Drip line / emitters / connectors / valves','Irrigation',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Trellis material','Other',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Packaging / egg packaging','Packaging',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Harvest crates','Other',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Cleaning / sanitation materials','Cleaning',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'PPE / hand tools / replacement parts','Tools / PPE',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Azaxol','Treatment',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Insectazol','Treatment',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Silazelle','Treatment',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Spinozad','Treatment',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Bt','Treatment',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Soap','Treatment',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Pepper','Treatment',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Neem oil','Treatment',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Vermi compost','Fertilizer / amendment',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Compost','Fertilizer / amendment',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Humic acid','Fertilizer / amendment',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Sugar','Fertilizer / amendment',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Seaweed','Fertilizer / amendment',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Beneficial bacteria','Fertilizer / amendment',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Weeds','Fertilizer / amendment',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Sheepwhool pellets','Fertilizer / amendment',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Wood Ash','Fertilizer / amendment',null,null from public.farms where slug='green-peas';
insert into public.inventory(farm_id,item,category,qty,min) select id,'Coffee eshre','Fertilizer / amendment',null,null from public.farms where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Harvest readiness','Harvest','Daily',null,'Daily::Harvest readiness',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Weather','Other','Daily',null,'Daily::Weather',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Soil moisture','Irrigation','Daily',null,'Daily::Soil moisture',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Irrigation','Irrigation','Daily',null,'Daily::Irrigation',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Nursery / germination','Nursery','Daily',null,'Daily::Nursery / germination',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Pest/disease check','Scouting','Daily',null,'Daily::Pest/disease check',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Food-safety check','Farm task','Daily',null,'Daily::Food-safety check',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Field work','Farm task','Daily',null,'Daily::Field work',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Coop work','Coop','Daily',null,'Daily::Coop work',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Review demand vs next 14 days of production','Farm task','Weekly',0,'Weekly:0:Review demand vs next 14 days of production',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Crop scouting','Scouting','Weekly',1,'Weekly:1:Crop scouting',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'14-day outlook','Farm task','Weekly',1,'Weekly:1:14-day outlook',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Crop review','Farm task','Weekly',2,'Weekly:2:Crop review',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Fertility review','Fertility','Weekly',2,'Weekly:2:Fertility review',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Weeding','Farm task','Weekly',3,'Weekly:3:Weeding',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Drainage','Maintenance','Weekly',3,'Weekly:3:Drainage',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Traps/screens','Scouting','Weekly',3,'Weekly:3:Traps/screens',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Disease-risk review','Scouting','Weekly',4,'Weekly:4:Disease-risk review',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Detailed pest scouting','Scouting','Weekly',5,'Weekly:5:Detailed pest scouting',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Trellising','Farm task','Weekly',5,'Weekly:5:Trellising',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Maintenance','Maintenance','Weekly',5,'Weekly:5:Maintenance',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Harvest','Harvest','Weekly',6,'Weekly:6:Harvest',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Packing','Farm task','Weekly',6,'Weekly:6:Packing',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Sales records','Farm task','Weekly',6,'Weekly:6:Sales records',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Marketplace / Breakfast Section use','Farm task','Weekly',6,'Weekly:6:Marketplace / Breakfast Section use',(select id from public.areas where name='Marketplace / Breakfast Section' and farm_id=f.id) from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Waste recording','Farm task','Weekly',6,'Weekly:6:Waste recording',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Inventory count','Farm task','Monthly',null,'Monthly::Inventory count',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Crop-performance review','Farm task','Monthly',null,'Monthly::Crop-performance review',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Egg/flock review','Coop','Monthly',null,'Monthly::Egg/flock review',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Irrigation maintenance','Maintenance','Monthly',null,'Monthly::Irrigation maintenance',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Tools/equipment check','Maintenance','Monthly',null,'Monthly::Tools/equipment check',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Input-cost review','Farm task','Monthly',null,'Monthly::Input-cost review',null from public.farms f where slug='green-peas';
insert into public.tasks(farm_id,title,event_type,recurrence,weekday,routine_key,area_id) select id,'Production-vs-sales review','Farm task','Monthly',null,'Monthly::Production-vs-sales review',null from public.farms f where slug='green-peas';

-- One inventory balance is shared by Marketplace, Breakfast and the coop egg system.
alter table public.inventory add column coop_id uuid;
alter table public.inventory add foreign key(farm_id,coop_id) references public.coops(farm_id,id);
create unique index inventory_coop_eggs_idx on public.inventory(coop_id) where coop_id is not null;
create table public.marketplace_products(
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),name text not null,description text,category text,
 image_data text check(length(image_data)<=350000),source text not null check(source in ('Crops','Eggs','Breakfast','Other farm products')),
 inventory_id uuid not null,unit text,stock_per_unit numeric not null check(stock_per_unit>0),price numeric check(price>=0),currency text,
 status text not null check(status in ('Available','Low Stock','Out of Stock','Hidden')),archived boolean not null default false,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 foreign key(farm_id,inventory_id) references public.inventory(farm_id,id),unique(farm_id,id)
);
create table public.breakfast_items(
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),name text not null,description text,image_data text check(length(image_data)<=350000),
 selling_price numeric check(selling_price>=0),currency text,active boolean not null default true,quantity_available numeric check(quantity_available>=0),
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(farm_id,id)
);
create table public.breakfast_ingredients(
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),menu_item_id uuid not null,inventory_id uuid not null,
 quantity_per_serving numeric not null check(quantity_per_serving>0),foreign key(farm_id,menu_item_id) references public.breakfast_items(farm_id,id) on delete cascade,
 foreign key(farm_id,inventory_id) references public.inventory(farm_id,id),unique(menu_item_id,inventory_id)
);
create table public.inventory_transactions(
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),inventory_id uuid not null,type text not null,
 quantity numeric,previous_quantity numeric,new_quantity numeric check(new_quantity>=0),reason text not null,
 product_id uuid,menu_item_id uuid,source_record_id uuid,created_by uuid references auth.users(id),created_by_email text,created_at timestamptz not null default now(),
 foreign key(farm_id,inventory_id) references public.inventory(farm_id,id),foreign key(farm_id,product_id) references public.marketplace_products(farm_id,id),
 foreign key(farm_id,menu_item_id) references public.breakfast_items(farm_id,id)
);
create table public.marketplace_transactions(
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),product_id uuid not null,
 quantity numeric not null check(quantity>0),unit_price numeric,currency text,revenue numeric,record_date date not null,
 created_by uuid references auth.users(id),created_at timestamptz not null default now(),request_id uuid not null unique,
 foreign key(farm_id,product_id) references public.marketplace_products(farm_id,id)
);
create table public.breakfast_records(
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),menu_item_id uuid not null,
 action text not null check(action in ('Prepared','Served')),quantity numeric not null check(quantity>0),record_date date not null,
 created_by uuid references auth.users(id),created_at timestamptz not null default now(),request_id uuid not null unique,
 foreign key(farm_id,menu_item_id) references public.breakfast_items(farm_id,id)
);
do $$declare t text;begin
 foreach t in array array['marketplace_products','breakfast_items','breakfast_ingredients','inventory_transactions','marketplace_transactions','breakfast_records'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('create policy farm_read on public.%I for select to authenticated using(public.can_access_farm(farm_id))',t);
 execute format('grant select on public.%I to authenticated',t);
 execute format('create index %I on public.%I(farm_id)',t||'_farm_idx',t);
 end loop;
end $$;
create index products_inventory_idx on public.marketplace_products(farm_id,inventory_id);
create index breakfast_recipe_inventory_idx on public.breakfast_ingredients(farm_id,inventory_id);
create index inventory_history_idx on public.inventory_transactions(inventory_id,created_at desc);
create index sales_product_idx on public.marketplace_transactions(product_id,record_date);
create index breakfast_records_menu_idx on public.breakfast_records(menu_item_id,record_date);
create function public.audit_inventory_quantity() returns trigger language plpgsql security definer set search_path='' as $$begin
 if old.qty is distinct from new.qty then
 insert into public.inventory_transactions(farm_id,inventory_id,type,quantity,previous_quantity,new_quantity,reason,product_id,menu_item_id,created_by,created_by_email)
 values(new.farm_id,new.id,coalesce(nullif(current_setting('farm.stock_type',true),''),'Stock count'),case when old.qty is null then null else new.qty-old.qty end,old.qty,new.qty,coalesce(nullif(current_setting('farm.stock_reason',true),''),'Observed inventory adjustment'),nullif(current_setting('farm.product_id',true),'')::uuid,nullif(current_setting('farm.menu_item_id',true),'')::uuid,auth.uid(),auth.jwt()->>'email');
 end if;return new;end $$;
revoke all on function public.audit_inventory_quantity() from public;
create trigger inventory_audit before update on public.inventory for each row execute function public.audit_inventory_quantity();
create function public.coop_stock_observation() returns trigger language plpgsql security definer set search_path='' as $$declare previous_date date;begin
 if (tg_op='INSERT' and new.stock is not null) or (tg_op='UPDATE' and new.stock is distinct from old.stock and new.stock is not null) then
 select max(record_date) into previous_date from public.coop_daily_records where coop_id=new.coop_id and stock is not null and id<>new.id;
 if previous_date is null or new.record_date>=previous_date then
 perform set_config('farm.stock_type','Coop stock count',true);perform set_config('farm.stock_reason','Observed remaining eggs on '||new.record_date,true);
 update public.inventory set qty=new.stock where coop_id=new.coop_id;
 end if;end if;return new;end $$;
revoke all on function public.coop_stock_observation() from public;
create trigger coop_stock_count after insert or update on public.coop_daily_records for each row execute function public.coop_stock_observation();
create function public.save_marketplace_product(p_farm_id uuid,p_id uuid,p_data jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare pid uuid:=coalesce(p_id,gen_random_uuid());inv uuid;begin
 if not public.can_manage_farm(p_farm_id) then raise exception 'Manager access required';end if;
 if p_id is not null and not exists(select 1 from public.marketplace_products where id=p_id and farm_id=p_farm_id) then raise exception 'Product unavailable';end if;
 inv:=nullif(p_data->>'inventory_id','')::uuid;
 if inv is null then
 insert into public.inventory(farm_id,item,category,qty,unit) values(p_farm_id,p_data->>'name','Marketplace',nullif(p_data->>'quantity','')::numeric,p_data->>'unit') on conflict(farm_id,item,category) do update set item=excluded.item returning id into inv;
 end if;
 insert into public.marketplace_products(id,farm_id,name,description,category,image_data,source,inventory_id,unit,stock_per_unit,price,currency,status,archived)
 values(pid,p_farm_id,p_data->>'name',p_data->>'description',p_data->>'category',p_data->>'image_data',p_data->>'source',inv,p_data->>'unit',(p_data->>'stock_per_unit')::numeric,nullif(p_data->>'price','')::numeric,nullif(p_data->>'currency',''),p_data->>'status',coalesce((p_data->>'archived')::boolean,false))
 on conflict(id) do update set name=excluded.name,description=excluded.description,category=excluded.category,image_data=excluded.image_data,source=excluded.source,inventory_id=excluded.inventory_id,unit=excluded.unit,stock_per_unit=excluded.stock_per_unit,price=excluded.price,currency=excluded.currency,status=excluded.status,archived=excluded.archived,updated_at=now();
 return pid;
end $$;
create function public.record_marketplace_sale(p_product_id uuid,p_quantity numeric,p_date date,p_request_id uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare p public.marketplace_products;i public.inventory;result uuid;begin
 select * into p from public.marketplace_products where id=p_product_id;
 if p.id is null or not public.can_manage_farm(p.farm_id) then raise exception 'Manager access required';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));select id into result from public.marketplace_transactions where request_id=p_request_id and farm_id=p.farm_id;if found then return result;end if;
 if p_quantity<=0 or p_quantity is null or p_date is null then raise exception 'Positive quantity and date required';end if;
 if p.archived or p.status='Hidden' then raise exception 'Product is not available for sale';end if;
 select * into i from public.inventory where id=p.inventory_id and farm_id=p.farm_id for update;
 if i.qty is null or i.qty<p_quantity*p.stock_per_unit then raise exception 'Record sufficient observed inventory first';end if;
 perform set_config('farm.stock_type','Marketplace Sale',true);perform set_config('farm.stock_reason','Sale recorded on '||p_date,true);perform set_config('farm.product_id',p.id::text,true);
 update public.inventory set qty=qty-p_quantity*p.stock_per_unit where id=i.id;
 insert into public.marketplace_transactions(farm_id,product_id,quantity,unit_price,currency,revenue,record_date,created_by,request_id)
 values(p.farm_id,p.id,p_quantity,p.price,p.currency,p.price*p_quantity,p_date,auth.uid(),p_request_id) returning id into result;return result;
end $$;
create function public.save_breakfast_item(p_farm_id uuid,p_id uuid,p_data jsonb,p_ingredients jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare mid uuid:=coalesce(p_id,gen_random_uuid());x jsonb;begin
 if not public.can_manage_farm(p_farm_id) then raise exception 'Manager access required';end if;
 if p_id is not null and not exists(select 1 from public.breakfast_items where id=p_id and farm_id=p_farm_id) then raise exception 'Menu item unavailable';end if;
 insert into public.breakfast_items(id,farm_id,name,description,image_data,selling_price,currency,active,quantity_available)
 values(mid,p_farm_id,p_data->>'name',p_data->>'description',p_data->>'image_data',nullif(p_data->>'selling_price','')::numeric,p_data->>'currency',(p_data->>'active')::boolean,nullif(p_data->>'quantity_available','')::numeric)
 on conflict(id) do update set name=excluded.name,description=excluded.description,image_data=excluded.image_data,selling_price=excluded.selling_price,currency=excluded.currency,active=excluded.active,updated_at=now();
 delete from public.breakfast_ingredients where menu_item_id=mid;
 for x in select value from jsonb_array_elements(p_ingredients) loop
 insert into public.breakfast_ingredients(farm_id,menu_item_id,inventory_id,quantity_per_serving) values(p_farm_id,mid,(x->>'inventory_id')::uuid,(x->>'quantity_per_serving')::numeric);
 end loop;return mid;
end $$;
create function public.record_breakfast(p_menu_item_id uuid,p_action text,p_quantity numeric,p_date date,p_request_id uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare m public.breakfast_items;r record;result uuid;begin
 select * into m from public.breakfast_items where id=p_menu_item_id;
 if m.id is null or not public.can_manage_farm(m.farm_id) then raise exception 'Manager access required';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));select id into result from public.breakfast_records where request_id=p_request_id and farm_id=m.farm_id;if found then return result;end if;
 select * into m from public.breakfast_items where id=p_menu_item_id for update;
 if p_quantity<=0 or p_quantity is null or p_date is null or not m.active then raise exception 'Active menu item, positive quantity and date required';end if;
 if p_action='Prepared' then
 if not exists(select 1 from public.breakfast_ingredients where menu_item_id=m.id) then raise exception 'Record the recipe ingredients before preparation';end if;
 for r in select i.id,i.qty,b.quantity_per_serving from public.breakfast_ingredients b join public.inventory i on i.id=b.inventory_id where b.menu_item_id=m.id order by i.id for update of i loop
 if r.qty is null or r.qty<r.quantity_per_serving*p_quantity then raise exception 'Ingredient stock is unknown or insufficient';end if;
 perform set_config('farm.stock_type','Breakfast Usage',true);perform set_config('farm.stock_reason','Prepared '||p_quantity||' servings on '||p_date,true);perform set_config('farm.menu_item_id',m.id::text,true);
 update public.inventory set qty=qty-r.quantity_per_serving*p_quantity where id=r.id;
 end loop;
 update public.breakfast_items set quantity_available=quantity_available+p_quantity,updated_at=now() where id=m.id;
 elsif p_action='Served' then
 if m.quantity_available is null or m.quantity_available<p_quantity then raise exception 'Available servings are unknown or insufficient';end if;
 update public.breakfast_items set quantity_available=quantity_available-p_quantity,updated_at=now() where id=m.id;
 else raise exception 'Invalid breakfast action';end if;
 insert into public.breakfast_records(farm_id,menu_item_id,action,quantity,record_date,created_by,request_id) values(m.farm_id,m.id,p_action,p_quantity,p_date,auth.uid(),p_request_id) returning id into result;return result;
end $$;
revoke all on function public.save_marketplace_product(uuid,uuid,jsonb),public.record_marketplace_sale(uuid,numeric,date,uuid),public.save_breakfast_item(uuid,uuid,jsonb,jsonb),public.record_breakfast(uuid,text,numeric,date,uuid) from public;
grant execute on function public.save_marketplace_product(uuid,uuid,jsonb),public.record_marketplace_sale(uuid,numeric,date,uuid),public.save_breakfast_item(uuid,uuid,jsonb,jsonb),public.record_breakfast(uuid,text,numeric,date,uuid) to authenticated;
-- Counts remain unknown until a real stock observation is entered.
insert into public.inventory(farm_id,item,category,qty,min,unit,coop_id) select farm_id,name||' eggs','Eggs',null,null,'egg',id from public.coops on conflict(farm_id,item,category) do nothing;
