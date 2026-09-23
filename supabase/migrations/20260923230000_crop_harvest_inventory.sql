-- Additive migration; existing harvests are historical and are NOT replayed into stock.
begin;
alter table public.plantings add column worker_id uuid,
 add foreign key(farm_id,worker_id) references public.workers(farm_id,id);
alter table public.planting_plans add column worker_id uuid,
 add foreign key(farm_id,worker_id) references public.workers(farm_id,id);
alter table public.crops add column inventory_id uuid,
 add foreign key(farm_id,inventory_id) references public.inventory(farm_id,id);
create unique index crops_produce_inventory_idx on public.crops(inventory_id) where inventory_id is not null;
alter table public.harvest_records add column harvested_at timestamptz,
 add column inventory_id uuid,
 add column request_id uuid,
 add foreign key(farm_id,inventory_id) references public.inventory(farm_id,id),
 add unique(farm_id,request_id),
 add constraint recorded_harvest_valid check(request_id is null or
  (planting_id is not null and crop_id is not null and inventory_id is not null and harvested_at is not null
   and quantity is not null and quantity>0 and quantity<'Infinity'::numeric and unit='kg'));
create index harvest_planting_time_idx on public.harvest_records(planting_id,harvested_at);
create index harvest_crop_date_idx on public.harvest_records(farm_id,crop_id,harvest_date);
create index harvest_bed_date_idx on public.harvest_records(farm_id,bed_id,harvest_date);
create index harvest_worker_date_idx on public.harvest_records(farm_id,worker_id,harvest_date);
create index plantings_worker_idx on public.plantings(farm_id,worker_id);
create index planting_plans_worker_idx on public.planting_plans(farm_id,worker_id);
create unique index inventory_harvest_source_idx on public.inventory_transactions(source_record_id)
 where type='Harvest' and source_record_id is not null;

-- Continue using the existing quantity audit trigger for every stock change.
create or replace function public.audit_inventory_quantity() returns trigger language plpgsql security definer set search_path='' as $$begin
 if old.qty is distinct from new.qty then
 insert into public.inventory_transactions(farm_id,inventory_id,type,quantity,previous_quantity,new_quantity,reason,product_id,menu_item_id,source_record_id,created_by,created_by_email)
 values(new.farm_id,new.id,coalesce(nullif(current_setting('farm.stock_type',true),''),'Stock count'),case when old.qty is null then null else new.qty-old.qty end,old.qty,new.qty,coalesce(nullif(current_setting('farm.stock_reason',true),''),'Observed inventory adjustment'),nullif(current_setting('farm.product_id',true),'')::uuid,nullif(current_setting('farm.menu_item_id',true),'')::uuid,nullif(current_setting('farm.source_record_id',true),'')::uuid,auth.uid(),auth.jwt()->>'email');
 end if;return new;end $$;

-- A request key identifies one immutable harvest, including after a lost response.
create function public.record_crop_harvest(p_planting_id uuid,p_quantity numeric,p_harvested_at timestamptz,
 p_harvest_date date,p_worker_id uuid,p_notes text,p_request_id uuid,p_inventory_id uuid default null)
 returns uuid language plpgsql security definer set search_path='' as $$
declare p public.plantings;c public.crops;i public.inventory;h public.harvest_records;result uuid:=gen_random_uuid();
 old_type text;old_reason text;old_source text;old_product text;old_menu text;matches integer;
begin
 select * into p from public.plantings where id=p_planting_id for update;
 if p.id is null or not public.can_manage_farm(p.farm_id) then raise exception 'Manager access required';end if;
 if p_request_id is null then raise exception 'Harvest request ID required';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 select * into h from public.harvest_records where farm_id=p.farm_id and request_id=p_request_id;
 if found then
  if h.planting_id is distinct from p_planting_id or h.quantity is distinct from p_quantity
   or h.harvested_at is distinct from p_harvested_at or h.harvest_date is distinct from p_harvest_date
   or h.worker_id is distinct from p_worker_id or h.notes is distinct from nullif(trim(p_notes),'')
   or (p_inventory_id is not null and h.inventory_id<>p_inventory_id) then
   raise exception 'This request already recorded a different harvest. Refresh its history.';
  end if;return h.id;
 end if;
 if p.stage in ('Planned','Finished') then raise exception 'Only an active crop can be harvested. Reopen a finished crop first.';end if;
 if p_quantity is null or not(p_quantity>0 and p_quantity<'Infinity'::numeric) then raise exception 'Enter a finite harvest quantity greater than zero kg';end if;
 if p_harvested_at is null or not isfinite(p_harvested_at) or p_harvest_date is null or not isfinite(p_harvest_date)
  or abs(p_harvest_date-(p_harvested_at at time zone 'UTC')::date)>1 then raise exception 'Valid harvest date and time required';end if;
 if p_worker_id is not null and not exists(select 1 from public.workers where id=p_worker_id and farm_id=p.farm_id and not archived) then raise exception 'Choose an existing active worker';end if;
 select * into c from public.crops where id=p.crop_id and farm_id=p.farm_id for update;
 if c.inventory_id is not null and p_inventory_id is not null and c.inventory_id<>p_inventory_id then raise exception 'This crop is already linked to another inventory item';end if;
 if c.inventory_id is null then
  if p_inventory_id is not null then c.inventory_id:=p_inventory_id;
  else
   select count(*) into matches from public.inventory where farm_id=p.farm_id and lower(trim(item))=lower(trim(c.name)) and coop_id is null;
   if matches>1 then raise exception 'Choose which existing inventory item receives this crop';end if;
   if matches=1 then
    select id into c.inventory_id from public.inventory where farm_id=p.farm_id and lower(trim(item))=lower(trim(c.name)) and coop_id is null and lower(trim(unit))='kg';
    if c.inventory_id is null then raise exception 'Select the existing inventory item and confirm its unit is kg';end if;
   else
    insert into public.inventory(farm_id,item,category,qty,unit) values(p.farm_id,c.name,'Produce',0,'kg') returning id into c.inventory_id;
   end if;
  end if;
 end if;
 select * into i from public.inventory where id=c.inventory_id and farm_id=p.farm_id for update;
 if i.id is null or i.coop_id is not null then raise exception 'Choose a produce inventory item in this farm';end if;
 if i.unit is null and p_inventory_id=i.id then
  update public.inventory set unit='kg' where id=i.id;i.unit:='kg';
 end if;
 if lower(trim(coalesce(i.unit,'')))<>'kg' then raise exception 'Harvest inventory must be measured in kg';end if;
 if i.qty is null then raise exception 'Record the current inventory count first, then retry this harvest';end if;
 update public.crops set inventory_id=i.id where id=c.id and inventory_id is null;
 insert into public.harvest_records(id,farm_id,planting_id,crop_id,bed_id,area_id,worker_id,harvest_date,harvested_at,quantity,unit,notes,inventory_id,request_id)
 values(result,p.farm_id,p.id,p.crop_id,p.bed_id,p.area_id,p_worker_id,p_harvest_date,p_harvested_at,p_quantity,'kg',nullif(trim(p_notes),''),i.id,p_request_id);
 old_type:=current_setting('farm.stock_type',true);old_reason:=current_setting('farm.stock_reason',true);old_source:=current_setting('farm.source_record_id',true);
 old_product:=current_setting('farm.product_id',true);old_menu:=current_setting('farm.menu_item_id',true);
 perform set_config('farm.stock_type','Harvest',true);perform set_config('farm.stock_reason','Harvest · '||c.name,true);
 perform set_config('farm.source_record_id',result::text,true);perform set_config('farm.product_id','',true);perform set_config('farm.menu_item_id','',true);
 update public.inventory set qty=qty+p_quantity where id=i.id;
 perform set_config('farm.stock_type',coalesce(old_type,''),true);perform set_config('farm.stock_reason',coalesce(old_reason,''),true);
 perform set_config('farm.source_record_id',coalesce(old_source,''),true);perform set_config('farm.product_id',coalesce(old_product,''),true);perform set_config('farm.menu_item_id',coalesce(old_menu,''),true);
 return result;
end $$;
-- Harvest writes go through the atomic RPC; history cannot be casually edited/deleted.
revoke insert,update,delete on public.harvest_records from anon,authenticated;
revoke all on function public.record_crop_harvest(uuid,numeric,timestamptz,date,uuid,text,uuid,uuid) from public;
grant execute on function public.record_crop_harvest(uuid,numeric,timestamptz,date,uuid,text,uuid,uuid) to anon,authenticated;

create or replace function public.audit_crop_stage() returns trigger language plpgsql security definer set search_path='' as $$
declare stages text[]:=array['Planned','Active','Vegetative','Flowering','Fruit development','Ready to harvest','Finished'];begin
 if old.stage is distinct from new.stage then
 if not public.can_manage_farm(new.farm_id) then raise exception 'Manager access required';end if;
 if abs(array_position(stages,new.stage)-array_position(stages,old.stage))<>1
  and not(new.stage='Finished' and old.stage not in ('Planned','Finished')) then raise exception 'Only adjacent lifecycle stages or finishing an active crop are valid';end if;
 new.stage_changed_at:=now();
 insert into public.crop_stage_history(farm_id,planting_id,crop_id,bed_id,previous_stage,new_stage,changed_by,changed_by_email,reason)
 values(new.farm_id,new.id,new.crop_id,new.bed_id,old.stage,new.stage,auth.uid(),auth.jwt()->>'email',nullif(current_setting('farm.stage_reason',true),''));
 end if;return new;end $$;
create function public.finish_crop(p_id uuid) returns void language plpgsql security invoker set search_path='' as $$
declare p public.plantings;begin
 select * into p from public.plantings where id=p_id for update;
 if p.id is null or not public.can_manage_farm(p.farm_id) then raise exception 'Manager access required';end if;
 if p.stage='Finished' then return;end if;
 if p.stage='Planned' then raise exception 'This crop has not started yet';end if;
 perform set_config('farm.stage_reason','Crop cycle finished',true);
 update public.plantings set stage='Finished' where id=p.id;
end $$;
revoke all on function public.finish_crop(uuid) from public;
grant execute on function public.finish_crop(uuid) to anon,authenticated;
notify pgrst,'reload schema';
commit;
