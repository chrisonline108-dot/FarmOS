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
