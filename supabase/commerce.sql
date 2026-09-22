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
