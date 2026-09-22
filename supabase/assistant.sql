-- Persist conversations privately; action proposals are immutable until explicitly decided.
create table public.ai_conversations(
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),user_id uuid not null default auth.uid() references auth.users(id),
 title text not null default 'Farm conversation' check(length(title)<=200),created_at timestamptz not null default now(),unique(farm_id,id)
);
create table public.ai_messages(
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),conversation_id uuid not null,
 role text not null check(role in ('user','assistant')),content text not null check(length(content)<=60000),created_at timestamptz not null default clock_timestamp(),
 foreign key(farm_id,conversation_id) references public.ai_conversations(farm_id,id) on delete cascade
);
create table public.ai_actions(
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),conversation_id uuid references public.ai_conversations(id) on delete set null,
 user_id uuid not null default auth.uid() references auth.users(id),action text not null check(action in ('create_task','assign_task','update_task','mark_task_complete','create_crop_record','update_crop_stage','revert_crop_stage','adjust_chicken_count','transfer_chickens','record_egg_collection','record_feed_water','record_coop_cleaning','update_marketplace_stock','record_breakfast_usage')),
 arguments jsonb not null,summary text not null,status text not null default 'Pending' check(status in ('Pending','Confirmed','Cancelled','Expired')),created_at timestamptz not null default now(),decided_at timestamptz
);
create table public.ai_audit_log(
 id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),user_id uuid not null references auth.users(id),
 action_id uuid not null references public.ai_actions(id),action text not null,arguments jsonb not null,result text not null,created_at timestamptz not null default now()
);
alter table public.ai_conversations enable row level security;
alter table public.ai_messages enable row level security;
alter table public.ai_actions enable row level security;
alter table public.ai_audit_log enable row level security;
create policy own_conversations on public.ai_conversations for all to authenticated using(user_id=(select auth.uid()) and public.can_access_farm(farm_id)) with check(user_id=(select auth.uid()) and public.can_access_farm(farm_id));
create policy own_messages on public.ai_messages for all to authenticated using(exists(select 1 from public.ai_conversations c where c.id=conversation_id and c.user_id=(select auth.uid()))) with check(exists(select 1 from public.ai_conversations c where c.id=conversation_id and c.user_id=(select auth.uid())));
create policy own_actions_read on public.ai_actions for select to authenticated using(user_id=(select auth.uid()) and public.can_access_farm(farm_id));
create policy own_actions_insert on public.ai_actions for insert to authenticated with check(user_id=(select auth.uid()) and public.can_access_farm(farm_id) and status='Pending' and decided_at is null and exists(select 1 from public.ai_conversations c where c.id=conversation_id and c.farm_id=ai_actions.farm_id));
create policy own_ai_audit on public.ai_audit_log for select to authenticated using(user_id=(select auth.uid()) and public.can_access_farm(farm_id));
grant select,insert,update,delete on public.ai_conversations to authenticated;
grant select,insert,delete on public.ai_messages to authenticated;
grant select,insert on public.ai_actions to authenticated;
grant select on public.ai_audit_log to authenticated;
create index ai_conversations_owner_idx on public.ai_conversations(user_id,farm_id);
create index ai_messages_conversation_idx on public.ai_messages(conversation_id,created_at);
create index ai_actions_owner_idx on public.ai_actions(user_id,created_at);
create index ai_audit_action_idx on public.ai_audit_log(action_id);
create function public.decide_ai_action(p_id uuid,p_confirm boolean) returns text language plpgsql security definer set search_path='' as $$
declare a public.ai_actions;d jsonb;t public.tasks;r public.coop_daily_records;stock public.inventory;cropid uuid;plant public.plantings;data jsonb;wid uuid;
begin
 select * into a from public.ai_actions where id=p_id and user_id=auth.uid() for update;
 if not found or not public.can_access_farm(a.farm_id) then raise exception 'Action unavailable';end if;
 if a.status<>'Pending' then return a.status;end if;
 if not p_confirm then update public.ai_actions set status='Cancelled',decided_at=now() where id=a.id;
 insert into public.ai_audit_log(farm_id,user_id,action_id,action,arguments,result) values(a.farm_id,auth.uid(),a.id,a.action,a.arguments,'Cancelled');return 'Cancelled';end if;
 if a.created_at<now()-interval '30 minutes' then update public.ai_actions set status='Expired',decided_at=now() where id=a.id;return 'Expired';end if;
 if a.action<>'mark_task_complete' and not public.can_manage_farm(a.farm_id) then raise exception 'Manager access required';end if;
 d:=a.arguments;
 if a.action in ('assign_task','update_task','mark_task_complete') then
 select * into t from public.tasks where id=(d->>'task_id')::uuid and farm_id=a.farm_id for update;
 if not found then raise exception 'Task unavailable';end if;
 if d->>'expected_updated_at' is null or t.updated_at<>(d->>'expected_updated_at')::timestamptz then raise exception 'Task changed; request a fresh proposal';end if;
 end if;
 case a.action
 when 'create_task' then perform public.save_scheduled_task(a.farm_id,null,d,'Open');
 when 'assign_task' then
 delete from public.task_assignees where task_id=t.id;
 for wid in select value::uuid from jsonb_array_elements_text(d->'assignee_ids') loop insert into public.task_assignees(farm_id,task_id,worker_id) values(a.farm_id,t.id,wid);end loop;
 update public.tasks set updated_at=clock_timestamp() where id=t.id;
 when 'update_task' then
 data:=to_jsonb(t)||coalesce(d->'changes','{}')||jsonb_build_object('assignee_ids',coalesce((select jsonb_agg(worker_id) from public.task_assignees where task_id=t.id),'[]'));
 perform public.save_scheduled_task(a.farm_id,t.id,data,t.status,t.updated_at);
 when 'mark_task_complete' then perform public.set_task_status(t.id,(d->>'date')::date,'Completed');
 when 'create_crop_record' then
 select id into cropid from public.crops where id=(d->>'crop_id')::uuid and farm_id=a.farm_id;
 if cropid is null then raise exception 'Choose an existing crop from the catalogue';end if;
 insert into public.plantings(farm_id,crop_id,bed_id,area_id,planted_on,stage) select a.farm_id,cropid,id,area_id,(d->>'planted_on')::date,coalesce(d->>'stage','Planned') from public.beds where id=(d->>'bed_id')::uuid and farm_id=a.farm_id and purpose='Production';if not found then raise exception 'Production bed unavailable';end if;
 when 'update_crop_stage','revert_crop_stage' then
 select * into plant from public.plantings where id=(d->>'planting_id')::uuid and farm_id=a.farm_id for update;
 if not found or plant.stage is distinct from d->>'expected_stage' then raise exception 'Crop stage changed; request a fresh proposal';end if;
 perform public.change_crop_stage(plant.id,case a.action when 'update_crop_stage' then 'advance' else 'previous' end,d->>'reason');
 when 'adjust_chicken_count','transfer_chickens' then
 if not exists(select 1 from public.coops where id=(d->>'coop_id')::uuid and farm_id=a.farm_id) then raise exception 'Coop unavailable';end if;
 perform public.adjust_chickens((d->>'coop_id')::uuid,case a.action when 'transfer_chickens' then 'Transfer' else d->>'action' end,(d->>'quantity')::integer,d->>'reason',d->>'notes',nullif(d->>'to_coop_id','')::uuid);
 when 'record_egg_collection','record_feed_water' then
 if not exists(select 1 from public.coops where id=(d->>'coop_id')::uuid and farm_id=a.farm_id) then raise exception 'Coop unavailable';end if;
 if (d->>'date')::date>current_date then raise exception 'Actual records cannot be future dated';end if;
 select * into r from public.coop_daily_records where coop_id=(d->>'coop_id')::uuid and record_date=(d->>'date')::date for update;
 if (r.id is not null and (d->>'expected_updated_at' is null or r.updated_at<>(d->>'expected_updated_at')::timestamptz)) or (r.id is null and d->>'expected_updated_at' is not null) then raise exception 'Coop record changed; request a fresh proposal';end if;
 if r.id is null then insert into public.coop_daily_records(farm_id,coop_id,record_date) values(a.farm_id,(d->>'coop_id')::uuid,(d->>'date')::date) returning * into r;end if;
 if a.action='record_egg_collection' then
 update public.coop_daily_records set morning=case when d?'morning' then (d->>'morning')::int else morning end,evening=case when d?'evening' then (d->>'evening')::int else evening end,total=case when d?'total' then (d->>'total')::int else total end,saleable=case when d?'saleable' then (d->>'saleable')::int else saleable end,broken=case when d?'broken' then (d->>'broken')::int else broken end where id=r.id;
 else update public.coop_daily_records set feed=case when d?'feed' then (d->>'feed')::numeric else feed end,water=case when d?'water' then d->>'water' else water end where id=r.id;end if;
 when 'record_coop_cleaning' then
 if (d->>'date')::date>current_date then raise exception 'Actual records cannot be future dated';end if;
 insert into public.coop_cleaning(farm_id,coop_id,type,cleaning_date,completion,next_due,worker_id,notes) values(a.farm_id,(d->>'coop_id')::uuid,d->>'type',(d->>'date')::date,d->>'completion',nullif(d->>'next_due','')::date,nullif(d->>'worker_id','')::uuid,d->>'notes');
 when 'update_marketplace_stock' then
 select * into stock from public.inventory where id=(d->>'inventory_id')::uuid and farm_id=a.farm_id for update;
 if not found or d->>'expected_updated_at' is null or stock.updated_at<>(d->>'expected_updated_at')::timestamptz then raise exception 'Stock changed; request a fresh proposal';end if;
 perform set_config('farm.stock_reason',coalesce(d->>'reason','Confirmed assistant stock count'),true);update public.inventory set qty=(d->>'quantity')::numeric where id=stock.id;
 when 'record_breakfast_usage' then
 if not exists(select 1 from public.breakfast_items where id=(d->>'menu_item_id')::uuid and farm_id=a.farm_id) then raise exception 'Breakfast item unavailable';end if;
 perform public.record_breakfast((d->>'menu_item_id')::uuid,'Prepared',(d->>'quantity')::numeric,(d->>'date')::date,a.id);
 else raise exception 'Unsupported action';end case;
 update public.ai_actions set status='Confirmed',decided_at=now() where id=a.id;
 insert into public.ai_audit_log(farm_id,user_id,action_id,action,arguments,result) values(a.farm_id,auth.uid(),a.id,a.action,d,'Confirmed');return 'Confirmed';
end $$;
revoke all on function public.decide_ai_action(uuid,boolean) from public;
grant execute on function public.decide_ai_action(uuid,boolean) to authenticated;

create or replace function public.adjust_inventory(p_id uuid,p_delta numeric) returns void language plpgsql security invoker set search_path='' as $$
declare i public.inventory;begin select * into i from public.inventory where id=p_id for update;
 if not found or i.qty is null then raise exception 'Record an observed quantity first';end if;
 if p_delta is null or i.qty+p_delta<0 then raise exception 'Stock cannot be negative';end if;
 update public.inventory set qty=qty+p_delta where id=p_id;end $$;
create table public.breakfast_count_history(id uuid primary key default gen_random_uuid(),farm_id uuid not null references public.farms(id),menu_item_id uuid not null,previous_quantity numeric,new_quantity numeric not null,created_by uuid references auth.users(id),created_at timestamptz not null default now(),foreign key(farm_id,menu_item_id) references public.breakfast_items(farm_id,id));
alter table public.breakfast_count_history enable row level security;
create policy breakfast_counts_read on public.breakfast_count_history for select to authenticated using(public.can_access_farm(farm_id));
grant select on public.breakfast_count_history to authenticated;
create function public.count_breakfast_servings(p_id uuid,p_quantity numeric) returns void language plpgsql security definer set search_path='' as $$
declare m public.breakfast_items;begin select * into m from public.breakfast_items where id=p_id for update;
 if not found or not public.can_manage_farm(m.farm_id) then raise exception 'Manager access required';end if;
 if p_quantity is null or p_quantity<0 then raise exception 'Enter a non-negative count';end if;
 insert into public.breakfast_count_history(farm_id,menu_item_id,previous_quantity,new_quantity,created_by) values(m.farm_id,m.id,m.quantity_available,p_quantity,auth.uid());
 update public.breakfast_items set quantity_available=p_quantity,updated_at=now() where id=p_id;end $$;
revoke all on function public.count_breakfast_servings(uuid,numeric) from public;
grant execute on function public.count_breakfast_servings(uuid,numeric) to authenticated;
-- Efficient joins for all new foreign keys, including audit actors.
do $$declare r record;begin for r in select c.conrelid::regclass as tbl,a.attname from pg_constraint c join pg_attribute a on a.attrelid=c.conrelid and a.attnum=c.conkey[1] where c.contype='f' and c.connamespace='public'::regnamespace and not exists(select 1 from pg_index i where i.indrelid=c.conrelid and i.indkey[0]=c.conkey[1]) loop execute format('create index if not exists %I on %s(%I)',replace(r.tbl::text,'public.','')||'_'||r.attname||'_fk_idx',r.tbl,r.attname);end loop;end $$;
