-- TEMPORARY TEST ONLY: explicit public access to Green Peas for 72 hours.
-- Expiry is enforced in every temporary policy and in the existing write RPC checks.
-- No anonymous role can modify this window. RLS remains enabled on every table.
-- Audit actor UUIDs stay NULL for operations performed without an identified user.
create schema if not exists farm_internal;
revoke all on schema farm_internal from public,anon,authenticated;
create table farm_internal.temporary_access_window(
 farm_id uuid primary key references public.farms(id),
 enabled_at timestamptz not null default now(),
 expires_at timestamptz not null default now()+interval '72 hours'
);
alter table farm_internal.temporary_access_window enable row level security;
revoke all on farm_internal.temporary_access_window from public,anon,authenticated;
insert into farm_internal.temporary_access_window(farm_id) select id from public.farms where slug='green-peas';
create function public.farm_test_access(p_farm_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from farm_internal.temporary_access_window w
 join public.farms f on f.id=w.farm_id
 where w.farm_id=p_farm_id and f.slug='green-peas' and now()<w.expires_at)
$$;
revoke all on function public.farm_test_access(uuid) from public;
grant execute on function public.farm_test_access(uuid) to anon,authenticated;
create or replace function public.can_access_farm(p_farm_id uuid) returns boolean
language plpgsql stable security invoker set search_path='' as $$begin
 if public.farm_test_access(p_farm_id) then return true;end if;
 if auth.uid() is null then return false;end if;
 return exists(select 1 from public.farm_members where farm_id=p_farm_id and (user_id=auth.uid() or email=lower(auth.jwt()->>'email')));
end $$;
create or replace function public.can_manage_farm(p_farm_id uuid) returns boolean
language plpgsql stable security invoker set search_path='' as $$begin
 if public.farm_test_access(p_farm_id) then return true;end if;
 if auth.uid() is null then return false;end if;
 return exists(select 1 from public.farm_members where farm_id=p_farm_id and role in ('owner','manager') and (user_id=auth.uid() or email=lower(auth.jwt()->>'email')));
end $$;
grant execute on function public.can_access_farm(uuid),public.can_manage_farm(uuid) to anon;
grant select on public.farms to anon;
grant update(name,total_property_area,profile) on public.farms to anon;
create policy temporary_test_farm_read on public.farms for select to anon using(public.farm_test_access(id));
create policy temporary_test_farm_update on public.farms for update to anon using(public.farm_test_access(id)) with check(public.farm_test_access(id));
do $$declare t text;begin
 foreach t in array array['areas','beds','workers','coops','crops','plantings','planting_plans','tasks','task_occurrences','coop_daily_records','coop_cleaning','inventory','harvest_records','farm_records','legacy_imports','task_assignees','crop_stage_history','chicken_count_history','farm_seasons','marketplace_products','marketplace_transactions','breakfast_items','breakfast_ingredients','breakfast_records','inventory_transactions','breakfast_count_history','ai_conversations','ai_messages','ai_actions','ai_audit_log'] loop
 execute format('grant select on public.%I to anon',t);
 execute format('create policy temporary_test_farm_read on public.%I for select to anon using(public.farm_test_access(farm_id))',t);
 end loop;
 foreach t in array array['areas','beds','workers','crops','plantings','planting_plans','tasks','coop_daily_records','coop_cleaning','inventory','harvest_records','farm_records','legacy_imports','task_assignees','farm_seasons'] loop
 execute format('grant insert,update,delete on public.%I to anon',t);
 execute format('create policy temporary_test_farm_insert on public.%I for insert to anon with check(public.farm_test_access(farm_id))',t);
 execute format('create policy temporary_test_farm_update on public.%I for update to anon using(public.farm_test_access(farm_id)) with check(public.farm_test_access(farm_id))',t);
 execute format('create policy temporary_test_farm_delete on public.%I for delete to anon using(public.farm_test_access(farm_id))',t);
 end loop;
end $$;
grant select on public.feed_logs,public.coop_treatments to anon;
grant execute on function public.import_legacy_farm(uuid,jsonb),public.set_task_status(uuid,date,text),public.adjust_inventory(uuid,numeric),public.set_coop_counts(uuid,integer,integer),public.change_crop_stage(uuid,text,text),public.adjust_chickens(uuid,text,integer,text,text,uuid),public.task_occurs(public.tasks,date),public.save_scheduled_task(uuid,uuid,jsonb,text,timestamptz),public.save_marketplace_product(uuid,uuid,jsonb),public.record_marketplace_sale(uuid,numeric,date,uuid),public.save_breakfast_item(uuid,uuid,jsonb,jsonb),public.record_breakfast(uuid,text,numeric,date,uuid),public.count_breakfast_servings(uuid,numeric),public.decide_ai_action(uuid,boolean) to anon;
alter table public.ai_conversations alter column user_id drop not null;
alter table public.ai_actions alter column user_id drop not null;
alter table public.ai_audit_log alter column user_id drop not null;
grant insert,delete on public.ai_conversations to anon;
grant update(title) on public.ai_conversations to anon;
create policy temporary_test_conversation_insert on public.ai_conversations for insert to anon with check(public.farm_test_access(farm_id) and user_id is null);
create policy temporary_test_conversation_update on public.ai_conversations for update to anon using(public.farm_test_access(farm_id)) with check(public.farm_test_access(farm_id));
create policy temporary_test_conversation_delete on public.ai_conversations for delete to anon using(public.farm_test_access(farm_id));
grant insert on public.ai_messages to anon;
create policy temporary_test_message_insert on public.ai_messages for insert to anon with check(public.farm_test_access(farm_id) and exists(select 1 from public.ai_conversations c where c.id=conversation_id and c.farm_id=ai_messages.farm_id));
grant insert on public.ai_actions to anon;
create policy temporary_test_action_insert on public.ai_actions for insert to anon with check(public.farm_test_access(farm_id) and user_id is null and status='Pending' and decided_at is null and exists(select 1 from public.ai_conversations c where c.id=conversation_id and c.farm_id=ai_actions.farm_id));

create or replace function public.set_task_status(p_task_id uuid,p_date date,p_status text) returns void language plpgsql security definer set search_path='' as $$
declare t public.tasks;allowed boolean;begin
 select * into t from public.tasks where id=p_task_id for update;
 if t.id is null then raise exception 'Task unavailable';end if;
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

create or replace function public.decide_ai_action(p_id uuid,p_confirm boolean) returns text language plpgsql security definer set search_path='' as $$
declare a public.ai_actions;d jsonb;t public.tasks;r public.coop_daily_records;stock public.inventory;cropid uuid;plant public.plantings;data jsonb;wid uuid;
begin
 select * into a from public.ai_actions where id=p_id and (user_id=auth.uid() or public.farm_test_access(farm_id)) for update;
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
