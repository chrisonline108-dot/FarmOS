-- Safe in a configured database too: every fixture is rolled back.
begin;
create temporary table harvest_fixture(k text primary key,id uuid);
grant select on harvest_fixture to authenticated;
insert into auth.users(id,email) values('33333333-3333-4333-8333-333333333333','harvest-test@example.invalid');
with r as(insert into public.farms(slug,name) values('__harvest_test','Harvest test') returning id) insert into harvest_fixture select 'farm',id from r;
insert into public.farm_members(farm_id,email,user_id,role) select id,'harvest-test@example.invalid','33333333-3333-4333-8333-333333333333','owner' from harvest_fixture where k='farm';
with r as(insert into public.areas(farm_id,name,kind) select id,'Test area','production' from harvest_fixture where k='farm' returning id) insert into harvest_fixture select 'area',id from r;
with r as(insert into public.beds(farm_id,area_id,code) select f.id,a.id,'A1' from harvest_fixture f,harvest_fixture a where f.k='farm' and a.k='area' returning id) insert into harvest_fixture select 'bed',id from r;
with r as(insert into public.workers(farm_id,name) select id,'Test worker' from harvest_fixture where k='farm' returning id) insert into harvest_fixture select 'worker',id from r;
with r as(insert into public.crops(farm_id,name) select id,'Tomatoes' from harvest_fixture where k='farm' returning id) insert into harvest_fixture select 'crop',id from r;
with r as(insert into public.inventory(farm_id,item,category,qty,unit) select id,'Tomatoes','Produce',20,'kg' from harvest_fixture where k='farm' returning id) insert into harvest_fixture select 'inventory',id from r;
select set_config('request.jwt.claims','{"sub":"33333333-3333-4333-8333-333333333333","email":"harvest-test@example.invalid","role":"authenticated"}',true);
set local role authenticated;
do $$declare fid uuid:=(select id from harvest_fixture where k='farm');cid uuid:=(select id from harvest_fixture where k='crop');
 bid uuid:=(select id from harvest_fixture where k='bed');wid uuid:=(select id from harvest_fixture where k='worker');
 inv uuid:=(select id from harvest_fixture where k='inventory');pid uuid;plan uuid;hid uuid;req uuid:=gen_random_uuid();q numeric;n integer;other uuid;stock uuid;rejected boolean;
begin
 insert into public.plantings(farm_id,crop_id,bed_id,stage,worker_id) values(fid,cid,bid,'Active',wid) returning id into pid;
 insert into public.planting_plans(farm_id,crop_id,bed_id,worker_id) values(fid,cid,bid,wid) returning id into plan;
 if (select worker_id from public.plantings where id=pid)<>wid or (select worker_id from public.planting_plans where id=plan)<>wid then raise exception 'Assignment not persistent';end if;
 hid:=public.record_crop_harvest(pid,12.5,'2026-09-23 09:30+03','2026-09-23',wid,'First pick',req);
 if (select qty from public.inventory where id=inv)<>32.5 then raise exception '20 + 12.5 must equal 32.5';end if;
 if (select stage from public.plantings where id=pid)<>'Active' then raise exception 'Harvest finished crop';end if;
 if not exists(select 1 from public.harvest_records where id=hid and planting_id=pid and crop_id=cid and bed_id=bid and worker_id=wid and inventory_id=inv and unit='kg' and notes='First pick') then raise exception 'Harvest relations missing';end if;
 if not exists(select 1 from public.inventory_transactions where source_record_id=hid and type='Harvest' and quantity=12.5 and previous_quantity=20 and new_quantity=32.5) then raise exception 'Audit missing';end if;
 perform public.record_crop_harvest(pid,12.5,'2026-09-23 09:30+03','2026-09-23',wid,'First pick',req);
 if (select qty from public.inventory where id=inv)<>32.5 or (select count(*) from public.harvest_records where planting_id=pid)<>1 or (select count(*) from public.inventory_transactions where source_record_id=hid)<>1 then raise exception 'Retry doubled stock';end if;
 rejected:=false;begin perform public.record_crop_harvest(pid,99,'2026-09-23 09:30+03','2026-09-23',wid,'First pick',req);exception when others then rejected:=true;end;if not rejected then raise exception 'Changed payload reused request';end if;
 foreach q in array array[0,-1,'NaN'::numeric,'Infinity'::numeric,null] loop
 rejected:=false;begin perform public.record_crop_harvest(pid,q,now(),current_date,wid,null,gen_random_uuid());exception when others then rejected:=true;end;if not rejected then raise exception 'Invalid quantity accepted: %',q;end if;
 end loop;
 perform public.record_crop_harvest(pid,2.5,'2026-09-24 10:00+03','2026-09-24',wid,null,gen_random_uuid());
 if (select qty from public.inventory where id=inv)<>35 or (select sum(quantity) from public.harvest_records where planting_id=pid)<>15 then raise exception 'Multiple harvest totals wrong';end if;
 perform public.finish_crop(pid);
 if (select stage from public.plantings where id=pid)<>'Finished' or (select qty from public.inventory where id=inv)<>35 then raise exception 'Finish changed stock';end if;
 rejected:=false;begin perform public.record_crop_harvest(pid,1,now(),current_date,wid,null,gen_random_uuid());exception when others then rejected:=true;end;if not rejected then raise exception 'Finished crop harvested';end if;
 -- A retry after finish still returns the original record, without changing stock.
 perform public.record_crop_harvest(pid,12.5,'2026-09-23 09:30+03','2026-09-23',wid,'First pick',req);
 perform public.change_crop_stage(pid,'previous','Reopened for another pick');
 perform public.record_crop_harvest(pid,1,now(),current_date,wid,null,gen_random_uuid());
 if (select qty from public.inventory where id=inv)<>36 then raise exception 'Reopen failed';end if;
 -- Manual changes retain their original audit type after a harvest in the same transaction.
 perform public.adjust_inventory(inv,-5);
 if not exists(select 1 from public.inventory_transactions where inventory_id=inv and type='Stock count' and quantity=-5 and source_record_id is null) then raise exception 'Harvest context leaked into manual adjustment';end if;
 insert into public.plantings(farm_id,crop_id,stage) values(fid,cid,'Planned') returning id into other;
 rejected:=false;begin perform public.record_crop_harvest(other,1,now(),current_date,wid,null,gen_random_uuid());exception when others then rejected:=true;end;if not rejected then raise exception 'Planned crop harvested';end if;
 -- The same crop in another bed/cycle uses the same stock.
 insert into public.plantings(farm_id,crop_id,stage) values(fid,cid,'Active') returning id into other;
 perform public.record_crop_harvest(other,2,now(),current_date,wid,null,gen_random_uuid());
 if (select qty from public.inventory where id=inv)<>33 then raise exception 'Shared crop inventory failed';end if;
 insert into public.crops(farm_id,name) values(fid,'Lettuce') returning id into cid;
 insert into public.plantings(farm_id,crop_id,stage) values(fid,cid,'Active') returning id into other;
 hid:=public.record_crop_harvest(other,3.25,now(),current_date,null,null,gen_random_uuid());
 select inventory_id into stock from public.harvest_records where id=hid;
 if (select qty from public.inventory where id=stock)<>3.25 or (select unit from public.inventory where id=stock)<>'kg' then raise exception 'New produce inventory failed';end if;
 -- An existing count with no unit requires explicit selection/confirmation of kg.
 insert into public.crops(farm_id,name) values(fid,'Peas') returning id into cid;
 insert into public.plantings(farm_id,crop_id,stage) values(fid,cid,'Active') returning id into other;
 insert into public.inventory(farm_id,item,category,qty) values(fid,'Peas','Other',7) returning id into stock;
 rejected:=false;begin perform public.record_crop_harvest(other,2,now(),current_date,null,null,gen_random_uuid());exception when others then rejected:=true;end;if not rejected then raise exception 'Unknown units assumed';end if;
 perform public.record_crop_harvest(other,2,now(),current_date,null,null,gen_random_uuid(),stock);
 if (select qty from public.inventory where id=stock)<>9 then raise exception 'Existing produce not reused';end if;
 -- Unknown stock is never silently treated as zero.
 update public.inventory set qty=null where id=stock;
 select count(*) into n from public.harvest_records;
 rejected:=false;begin perform public.record_crop_harvest(other,2,now(),current_date,null,null,gen_random_uuid());exception when others then rejected:=true;end;if not rejected then raise exception 'Unknown stock accepted';end if;
 if (select count(*) from public.harvest_records)<>n then raise exception 'Failed inventory left harvest behind';end if;
 -- Only the atomic RPC may write harvest history.
 rejected:=false;begin delete from public.harvest_records where id=hid;exception when insufficient_privilege then rejected:=true;end;if not rejected then raise exception 'Harvest deletable directly';end if;
end $$;
reset role;
-- Force an inventory failure AFTER inserting a harvest; both changes must roll back.
create function pg_temp.reject_test_stock() returns trigger language plpgsql as $$begin raise exception 'Injected inventory failure';end $$;
create trigger test_stock_failure before update of qty on public.inventory for each row execute function pg_temp.reject_test_stock();
do $$declare pid uuid;before_count int;before_qty numeric;inv uuid:=(select id from harvest_fixture where k='inventory');begin
 select id into pid from public.plantings where crop_id=(select id from harvest_fixture where k='crop') and stage='Ready to harvest';
 select count(*) into before_count from public.harvest_records;select qty into before_qty from public.inventory where id=inv;
 begin perform public.record_crop_harvest(pid,4,now(),current_date,null,null,gen_random_uuid());raise exception 'Failure injection did not fire';exception when others then if sqlerrm<>'Injected inventory failure' then raise;end if;end;
 if (select count(*) from public.harvest_records)<>before_count or (select qty from public.inventory where id=inv)<>before_qty then raise exception 'Atomic rollback failed';end if;
end $$;
drop trigger test_stock_failure on public.inventory;
-- Unauthenticated callers cannot access another farm just because RPC is granted.
insert into harvest_fixture select 'private_planting',id from public.plantings where farm_id=(select id from harvest_fixture where k='farm') limit 1;
grant select on harvest_fixture to anon;
select set_config('request.jwt.claims','{}',true);
set local role anon;
do $$begin
 begin perform public.record_crop_harvest((select id from harvest_fixture where k='private_planting'),1,now(),current_date,null,null,gen_random_uuid());raise exception 'Anonymous access accepted';
 exception when insufficient_privilege then null;when others then if sqlerrm<>'Manager access required' then raise;end if;end;
end $$;
reset role;
rollback;
