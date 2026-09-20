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
