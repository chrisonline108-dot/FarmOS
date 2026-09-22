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
