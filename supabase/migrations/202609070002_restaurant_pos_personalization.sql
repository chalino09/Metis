-- Restaurante only: editable meals over the existing cart and culinary domain.
begin;
alter table public.sale_cart_bundle_instances
  add column mode text not null default 'complete' check(mode in ('solo','complete')),
  add column quantity integer not null default 1 check(quantity between 1 and 100);
create table public.sale_cart_bundle_extras (
  instance_id uuid not null references public.sale_cart_bundle_instances(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  primary key(instance_id,product_id)
);
alter table public.sale_cart_bundle_extras enable row level security;
revoke all on public.sale_cart_bundle_extras from public,anon,authenticated;

-- Preserve the exact stored net amount until the canonical quote rounds each line.
create function public.restaurant_pos_solo_price(p_company_id uuid,p_location_id uuid,p_customer_id uuid,p_product_id uuid,p_at timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare b jsonb;amount numeric;
begin
 b:=public.resolve_pos_sale_price_base(p_company_id,p_location_id,p_customer_id,p_product_id,p_at);
 if b is null or not exists(select 1 from public.companies where id=p_company_id and product_experience_code='restaurant')then return b;end if;
 select p.amount into amount from public.product_prices p where p.product_id=p_product_id and p.price_list_id=(b->>'price_list_id')::uuid and p.currency_code=b->>'currency_code' and p.valid_from<=p_at and(p.valid_to is null or p.valid_to>p_at)order by p.valid_from desc limit 1;
 return b||jsonb_build_object('amount',amount);
end$$;
revoke all on function public.restaurant_pos_solo_price(uuid,uuid,uuid,uuid,timestamptz) from public,anon,authenticated;

-- Refresh only Restaurant's existing cart price metadata. The shared quote and
-- price resolvers remain untouched and perform their usual tax/discount logic.
create function public.quote_restaurant_pos_cart(p_cart_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare c public.sale_carts%rowtype;r record;price jsonb;solo numeric;combo numeric;rate numeric;net numeric;
begin
 select * into c from public.sale_carts where id=p_cart_id and cashier_id=auth.uid() and status in('active','held') for update;
 if not found then raise exception 'Carrito no disponible.';end if;
 perform public.assert_restaurant_studio_access(c.company_id,'use_pos');
 perform public.assert_pos_access(c.company_id,c.location_id,'use_pos');
 perform set_config('satrapy.pos_cart_id',c.id::text,true);
 perform set_config('satrapy.pos_price_list_id',coalesce(c.price_list_id::text,''),true);
 for r in select ci.id,ci.product_id,ci.quantity,coalesce(sum(i.quantity)filter(where i.mode='complete'),0) complete_quantity from public.sale_cart_items ci left join public.sale_cart_bundle_instances i on i.cart_item_id=ci.id where ci.cart_id=c.id group by ci.id loop
  price:=public.restaurant_pos_solo_price(c.company_id,c.location_id,c.customer_id,r.product_id);
  solo:=(price->>'amount')::numeric;net:=solo;
  if r.complete_quantity>0 then
   select combo_price_amount into combo from public.restaurant_menu_bundles where company_id=c.company_id and product_id=r.product_id and is_active;
   select t.rate into rate from public.tax_rates t join public.products p on p.tax_category_id=t.tax_category_id where p.id=r.product_id and t.valid_from<=now() and(t.valid_to is null or t.valid_to>now()) order by t.valid_from desc limit 1;
   if combo is null or rate is null then raise exception 'Completa el precio y el impuesto de la comida antes de venderla.';end if;
   if r.complete_quantity>r.quantity then raise exception 'Actualiza las cantidades de las comidas.';end if;
   net:=round(((r.quantity-r.complete_quantity)*solo+r.complete_quantity*combo/(1+rate))/r.quantity,6);
  end if;
  update public.sale_cart_items set restaurant_bundle_mode=case when r.complete_quantity>0 then 'complete' else 'solo' end,restaurant_bundle_price_amount=net where id=r.id;
 end loop;
 return public.quote_sale_cart(p_cart_id);
end$$;
revoke all on function public.quote_restaurant_pos_cart(uuid) from public,anon;
grant execute on function public.quote_restaurant_pos_cart(uuid) to authenticated;

create or replace function public.get_pos_restaurant_bundle_choice(p_cart_id uuid,p_product_id uuid,p_at timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare c public.sale_carts%rowtype;b jsonb;price jsonb;rate numeric;combo numeric;extras jsonb;
begin
 select * into c from public.sale_carts where id=p_cart_id and cashier_id=auth.uid() and status='active';
 if not found then raise exception 'Carrito no disponible.';end if;
 perform public.assert_restaurant_studio_access(c.company_id,'use_pos');
 b:=public.get_pos_restaurant_bundle(p_cart_id,p_product_id,p_at);
 if not coalesce((b->>'configured')::boolean,false) then return b;end if;
 perform set_config('satrapy.pos_cart_id',c.id::text,true);
 perform set_config('satrapy.pos_price_list_id',coalesce(c.price_list_id::text,''),true);
 price:=public.restaurant_pos_solo_price(c.company_id,c.location_id,c.customer_id,p_product_id,p_at);
 select t.rate into rate from public.tax_rates t join public.products p on p.tax_category_id=t.tax_category_id where p.id=p_product_id and t.valid_from<=p_at and(t.valid_to is null or t.valid_to>p_at) order by t.valid_from desc limit 1;
 select combo_price_amount into combo from public.restaurant_menu_bundles where id=(b->>'bundle_id')::uuid;
 select coalesce(jsonb_agg(e||jsonb_build_object('final_price',case when ep.value is not null and tr.rate is not null then round((ep.value->>'amount')::numeric*(1+tr.rate),2) end,'currency_code',ep.value->>'currency_code','available',coalesce((e->>'available')::boolean,false) and ep.value is not null and tr.rate is not null)),'[]') into extras
 from jsonb_array_elements(b->'extras')e
 left join lateral(select public.restaurant_pos_solo_price(c.company_id,c.location_id,c.customer_id,(e->>'product_id')::uuid,p_at) value)ep on true
 left join lateral(select t.rate from public.products p join public.tax_rates t on t.tax_category_id=p.tax_category_id where p.id=(e->>'product_id')::uuid and t.valid_from<=p_at and(t.valid_to is null or t.valid_to>p_at) order by t.valid_from desc limit 1)tr on true;
 return b||jsonb_build_object('solo_price',case when price is not null and rate is not null then round((price->>'amount')::numeric*(1+rate),2) end,'combo_price',case when rate is not null then combo end,'currency_code',price->>'currency_code','extras',extras);
end$$;

-- Validate the combined demand, including ingredients shared by several meals.
create function public.assert_restaurant_cart_stock(p_cart_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare c public.sale_carts%rowtype;r record;v uuid;needed jsonb:='[]';problem record;
begin
 select * into c from public.sale_carts where id=p_cart_id;
 for r in with requested as(
   select product_id,quantity from public.sale_cart_items where cart_id=p_cart_id
   union all select s.product_id,s.quantity from public.sale_cart_bundle_selections s join public.sale_cart_bundle_instances i on i.id=s.instance_id join public.sale_cart_items ci on ci.id=i.cart_item_id where ci.cart_id=p_cart_id
 ) select p.id,p.name,p.is_inventory_tracked,sum(x.quantity) quantity from requested x join public.products p on p.id=x.product_id group by p.id loop
   if not coalesce((public.validate_pos_product_for_location(c.company_id,c.location_id,r.id)->>'allowed')::boolean,false) then raise exception '% ya no está disponible en esta sucursal.',r.name;end if;
   if r.is_inventory_tracked then needed:=needed||jsonb_build_array(jsonb_build_object('id',r.id,'quantity',r.quantity));end if;
   select rv.id into v from public.culinary_recipes cr join public.culinary_recipe_versions rv on rv.recipe_id=cr.id where cr.company_id=c.company_id and cr.product_id=r.id and rv.status='active' and rv.valid_from<=now() and(rv.valid_to is null or rv.valid_to>now());
   if v is not null then
     select needed||coalesce(jsonb_agg(jsonb_build_object('id',ingredient_product_id,'quantity',quantity)),'[]') into needed from public.expand_culinary_recipe(v,r.quantity);
   elsif exists(select 1 from public.product_culinary_roles where product_id=r.id and role='dish') then
     raise exception 'Activa la receta de % antes de venderlo.',r.name;
   end if;
 end loop;
 for problem in select p.name,sum((x->>'quantity')::numeric) required,coalesce(b.quantity_on_hand,0) available from jsonb_array_elements(needed)x join public.products p on p.id=(x->>'id')::uuid left join public.inventory_balances b on b.product_id=p.id and b.location_id=c.location_id and b.company_id=c.company_id group by p.id,p.name,b.quantity_on_hand having sum((x->>'quantity')::numeric)>coalesce(b.quantity_on_hand,0) loop
   raise exception 'No alcanza %: se necesitan % y hay %.',problem.name,problem.required,problem.available;
 end loop;
end$$;
revoke all on function public.assert_restaurant_cart_stock(uuid) from public,anon,authenticated;

create function public.save_restaurant_pos_selection(
 p_cart_id uuid,p_product_id uuid,p_mode text default 'solo',p_selections jsonb default '{}',p_extra_product_ids uuid[] default '{}',p_quantity integer default 1,p_instance_id uuid default null,p_expected_revision integer default null,p_client_request_id uuid default gen_random_uuid()
) returns jsonb language plpgsql security definer set search_path=public as $$
declare c public.sale_carts%rowtype;b public.restaurant_menu_bundles%rowtype;old public.sale_cart_bundle_instances%rowtype;instance uuid:=coalesce(p_instance_id,gen_random_uuid());item uuid;g record;x record;n integer;choice jsonb;deltas jsonb:='[]';fingerprint text;replay jsonb;result jsonb;q numeric;
begin
 if p_quantity is null or p_quantity<0 or p_quantity>100 or p_mode is null or p_mode not in('solo','complete') or p_client_request_id is null then raise exception 'Revisa la cantidad y la modalidad del platillo.';end if;
 select * into c from public.sale_carts where id=p_cart_id and cashier_id=auth.uid() and status='active' for update;
 if not found then raise exception 'Carrito no disponible.';end if;
 perform public.assert_restaurant_studio_access(c.company_id,'use_pos');perform public.assert_pos_access(c.company_id,c.location_id,'use_pos');
 fingerprint:=md5(jsonb_build_array(p_product_id,p_mode,p_selections,p_extra_product_ids,p_quantity,p_instance_id)::text);
 select metadata into replay from public.audit_log where company_id=c.company_id and entity_id=p_cart_id and action='restaurant.pos_selection_saved' and metadata->>'request_id'=p_client_request_id::text;
 if replay is not null then if replay->>'fingerprint'<>fingerprint then raise exception 'La operación cambió. Vuelve a intentarlo.';end if;return public.quote_restaurant_pos_cart(p_cart_id);end if;
 if p_expected_revision is null or c.revision<>p_expected_revision then raise exception 'El carrito cambió en otra operación; actualiza la vista.';end if;
 if p_instance_id is not null then
   select i.* into old from public.sale_cart_bundle_instances i join public.sale_cart_items ci on ci.id=i.cart_item_id where i.id=p_instance_id and ci.cart_id=p_cart_id and ci.product_id=p_product_id;
   if not found then raise exception 'La comida ya no está en esta venta.';end if;
   deltas:=deltas||jsonb_build_array(jsonb_build_object('id',p_product_id,'delta',-old.quantity));
   select deltas||coalesce(jsonb_agg(jsonb_build_object('id',product_id,'delta',-old.quantity)),'[]') into deltas from public.sale_cart_bundle_extras where instance_id=instance;
 end if;
 if p_quantity>0 then
   select * into b from public.restaurant_menu_bundles where company_id=c.company_id and product_id=p_product_id and is_active;
   if not found then raise exception 'Este platillo no tiene opciones activas.';end if;
   choice:=public.get_pos_restaurant_bundle_choice(p_cart_id,p_product_id);
   if choice->>'solo_price' is null then raise exception 'Falta precio o impuesto vigente del platillo.';end if;
   if p_mode='complete' and(choice->>'combo_price' is null or jsonb_array_length(choice->'groups')=0) then raise exception 'Configura el precio y los acompañamientos de la comida completa.';end if;
   if jsonb_typeof(p_selections) is distinct from 'object' or coalesce(array_length(p_extra_product_ids,1),0)>100 then raise exception 'Revisa las opciones de la comida.';end if;
   if p_mode='complete' then
     if exists(select 1 from jsonb_object_keys(p_selections)k where not exists(select 1 from public.restaurant_menu_bundle_groups where id::text=k and bundle_id=b.id)) then raise exception 'Un grupo ya no pertenece a esta comida.';end if;
     for g in select * from public.restaurant_menu_bundle_groups where bundle_id=b.id loop
       if jsonb_typeof(coalesce(p_selections->g.id::text,'[]')) is distinct from 'array' then raise exception 'Revisa las opciones de %.',g.name;end if;
       select count(*) into n from jsonb_array_elements_text(coalesce(p_selections->g.id::text,'[]'));
       if n<g.minimum_selections or n>g.maximum_selections then raise exception 'Elige entre % y % opciones en %.',g.minimum_selections,g.maximum_selections,g.name;end if;
       if exists(select 1 from jsonb_array_elements_text(coalesce(p_selections->g.id::text,'[]'))v group by value having count(*)>1) or exists(select 1 from jsonb_array_elements_text(coalesce(p_selections->g.id::text,'[]'))v where not exists(select 1 from public.restaurant_menu_bundle_options o where o.id::text=v.value and o.group_id=g.id and o.is_active and o.product_id<>p_product_id)) then raise exception 'Revisa las opciones de %.',g.name;end if;
     end loop;
   end if;
   if (select count(*)<>count(distinct id) from unnest(coalesce(p_extra_product_ids,'{}'))id) or exists(select 1 from unnest(coalesce(p_extra_product_ids,'{}'))as extra(product_id) where extra.product_id=p_product_id or not exists(select 1 from public.restaurant_menu_bundle_extras e where e.bundle_id=b.id and e.product_id=extra.product_id and e.is_active)) then raise exception 'Revisa los extras de este platillo.';end if;
   deltas:=deltas||jsonb_build_array(jsonb_build_object('id',p_product_id,'delta',p_quantity));
   select deltas||coalesce(jsonb_agg(jsonb_build_object('id',id,'delta',p_quantity)),'[]') into deltas from unnest(coalesce(p_extra_product_ids,'{}'))id;
 end if;
 -- Remove old relations first; every change rolls back together on failure.
 delete from public.sale_cart_bundle_instances where id=p_instance_id;
 for x in select (v->>'id')::uuid id,sum((v->>'delta')::numeric) delta from jsonb_array_elements(deltas)v group by v->>'id' order by v->>'id' loop
   select quantity into q from public.sale_cart_items where cart_id=p_cart_id and product_id=x.id;q:=coalesce(q,0)+x.delta;
   if q<0 then raise exception 'Las cantidades cambiaron. Actualiza la venta.';end if;
   if q=0 then delete from public.sale_cart_items where cart_id=p_cart_id and product_id=x.id;
   else insert into public.sale_cart_items(cart_id,product_id,quantity) values(p_cart_id,x.id,q) on conflict(cart_id,product_id)do update set quantity=excluded.quantity,updated_at=now();end if;
 end loop;
 if p_quantity>0 then
   select id into item from public.sale_cart_items where cart_id=p_cart_id and product_id=p_product_id;
   insert into public.sale_cart_bundle_instances(id,company_id,cart_item_id,bundle_id,mode,quantity,created_at)values(instance,c.company_id,item,b.id,p_mode,p_quantity,coalesce(old.created_at,now()));
   if p_mode='complete' then insert into public.sale_cart_bundle_selections(company_id,instance_id,group_id,option_id,product_id,quantity) select c.company_id,instance,grp.id,o.id,o.product_id,p_quantity from public.restaurant_menu_bundle_groups grp cross join lateral jsonb_array_elements_text(coalesce(p_selections->grp.id::text,'[]'))v join public.restaurant_menu_bundle_options o on o.id::text=v.value and o.group_id=grp.id where grp.bundle_id=b.id;end if;
   insert into public.sale_cart_bundle_extras(instance_id,product_id)select instance,id from unnest(coalesce(p_extra_product_ids,'{}'))id;
   perform public.assert_restaurant_cart_stock(p_cart_id);
 end if;
 update public.sale_cart_items ci set restaurant_bundle_mode=case when exists(select 1 from public.sale_cart_bundle_instances i where i.cart_item_id=ci.id and i.mode='complete') then 'complete' else 'solo' end,restaurant_bundle_price_amount=null where ci.cart_id=p_cart_id and ci.product_id=p_product_id;
 update public.sale_carts set revision=revision+1 where id=p_cart_id;
 result:=public.quote_restaurant_pos_cart(p_cart_id);
 insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)values(c.company_id,auth.uid(),'restaurant.pos_selection_saved','sale_cart',p_cart_id,jsonb_build_object('request_id',p_client_request_id,'fingerprint',fingerprint,'instance_id',instance,'quantity',p_quantity,'mode',p_mode));
 return result;
end$$;
revoke all on function public.save_restaurant_pos_selection(uuid,uuid,text,jsonb,uuid[],integer,uuid,integer,uuid) from public,anon;
grant execute on function public.save_restaurant_pos_selection(uuid,uuid,text,jsonb,uuid[],integer,uuid,integer,uuid) to authenticated;

create or replace function public.list_sale_cart_bundle_instances(p_cart_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare c public.sale_carts%rowtype;result jsonb;
begin
 select * into c from public.sale_carts where id=p_cart_id and cashier_id=auth.uid();if not found then raise exception 'Carrito no disponible.';end if;
 perform public.assert_restaurant_studio_access(c.company_id,'use_pos');
 perform set_config('satrapy.pos_cart_id',c.id::text,true);perform set_config('satrapy.pos_price_list_id',coalesce(c.price_list_id::text,''),true);
 select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'cart_item_id',ci.id,'product_id',ci.product_id,'mode',i.mode,'quantity',i.quantity,
 'has_complete',b.combo_price_amount is not null and exists(select 1 from public.restaurant_menu_bundle_groups bg where bg.bundle_id=b.id),'has_extras',exists(select 1 from public.restaurant_menu_bundle_extras be where be.bundle_id=b.id and be.is_active),'solo_unit_final_price',round((public.restaurant_pos_solo_price(c.company_id,c.location_id,c.customer_id,ci.product_id)->>'amount')::numeric*(1+tr.rate),2),'unit_final_price',case when i.mode='complete' then b.combo_price_amount else round((public.restaurant_pos_solo_price(c.company_id,c.location_id,c.customer_id,ci.product_id)->>'amount')::numeric*(1+tr.rate),2)end,
 'selections',coalesce(s.items,'[]'),'extras',coalesce(e.items,'[]')) order by i.created_at,i.id),'[]')into result
 from public.sale_cart_bundle_instances i join public.sale_cart_items ci on ci.id=i.cart_item_id join public.restaurant_menu_bundles b on b.id=i.bundle_id
 left join lateral(select t.rate from public.products p join public.tax_rates t on t.tax_category_id=p.tax_category_id where p.id=ci.product_id and t.valid_from<=now()and(t.valid_to is null or t.valid_to>now())order by t.valid_from desc limit 1)tr on true
 left join lateral(select jsonb_agg(jsonb_build_object('group_id',g.id,'option_id',s.option_id,'group',g.name,'product_id',s.product_id,'name',p.name,'quantity',s.quantity)order by g.sort_order,p.name)items from public.sale_cart_bundle_selections s join public.restaurant_menu_bundle_groups g on g.id=s.group_id join public.products p on p.id=s.product_id where s.instance_id=i.id)s on true
 left join lateral(select jsonb_agg(jsonb_build_object('product_id',e.product_id,'name',p.name)order by p.name)items from public.sale_cart_bundle_extras e join public.products p on p.id=e.product_id where e.instance_id=i.id)e on true
 where ci.cart_id=p_cart_id;
 return result;
end$$;

-- Calculate a reviewable preview through the same Restaurant transaction.
-- The inner subtransaction always rolls back; no cart/audit change is retained.
create function public.preview_restaurant_pos_selection(
 p_cart_id uuid,p_product_id uuid,p_mode text,p_selections jsonb,p_extra_product_ids uuid[],p_quantity integer,p_instance_id uuid,p_expected_revision integer
) returns jsonb language plpgsql security definer set search_path=public as $$
declare result jsonb;q jsonb;request uuid:=gen_random_uuid();instance uuid;
begin
 begin
  q:=public.save_restaurant_pos_selection(p_cart_id,p_product_id,p_mode,p_selections,p_extra_product_ids,p_quantity,p_instance_id,p_expected_revision,request);
  select (metadata->>'instance_id')::uuid into instance from public.audit_log where entity_id=p_cart_id and action='restaurant.pos_selection_saved' and metadata->>'request_id'=request::text;
  result:=jsonb_build_object('quote',q,'instances',public.list_sale_cart_bundle_instances(p_cart_id),'instance_id',instance);
  raise exception using errcode='PZ001',message='Restaurant preview rollback';
 exception when sqlstate 'PZ001' then null;
 end;
 return result;
end$$;
revoke all on function public.preview_restaurant_pos_selection(uuid,uuid,text,jsonb,uuid[],integer,uuid,integer) from public,anon;
grant execute on function public.preview_restaurant_pos_selection(uuid,uuid,text,jsonb,uuid[],integer,uuid,integer) to authenticated;

-- Existing public add/remove endpoints use the same validated transaction.
create or replace function public.add_restaurant_bundle_choice(p_cart_id uuid,p_product_id uuid,p_mode text,p_selections jsonb default '{}',p_extra_product_ids uuid[] default '{}',p_expected_revision integer default null,p_client_request_id uuid default gen_random_uuid())
returns jsonb language plpgsql security definer set search_path=public as $$
begin return public.save_restaurant_pos_selection(p_cart_id,p_product_id,p_mode,p_selections,p_extra_product_ids,1,null,p_expected_revision,p_client_request_id);end$$;
create or replace function public.add_restaurant_bundle_to_cart(p_cart_id uuid,p_product_id uuid,p_selections jsonb,p_extra_product_ids uuid[] default '{}',p_expected_revision integer default null,p_client_request_id uuid default gen_random_uuid())
returns jsonb language plpgsql security definer set search_path=public as $$
begin return public.save_restaurant_pos_selection(p_cart_id,p_product_id,'complete',p_selections,p_extra_product_ids,1,null,p_expected_revision,p_client_request_id);end$$;
create or replace function public.remove_restaurant_bundle_from_cart(p_cart_id uuid,p_instance_id uuid,p_expected_revision integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare p uuid;
begin
 select ci.product_id into p from public.sale_cart_bundle_instances i join public.sale_cart_items ci on ci.id=i.cart_item_id where i.id=p_instance_id and ci.cart_id=p_cart_id;
 return public.save_restaurant_pos_selection(p_cart_id,p,'solo','{}','{}',0,p_instance_id,p_expected_revision,gen_random_uuid());
end$$;

alter table public.sale_item_bundle_instances add column mode text not null default 'complete' check(mode in('solo','complete')),add column quantity integer not null default 1 check(quantity>0),add column extras jsonb not null default '[]';
create function public.complete_restaurant_pos_sale(
  p_cart_id uuid,p_expected_revision integer,p_sale_type text,p_payment_method_id uuid default null,p_received_amount numeric default null,p_client_request_id uuid default null,p_payment_reference text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_cart public.sale_carts%rowtype;v_method public.payment_methods%rowtype;v_reference text:=nullif(trim(coalesce(p_payment_reference,'')),'');v_result jsonb;v_ticket_payload jsonb;v_parent record;v_instance record;v_selection record;v_component_sale_item_id uuid;v_sale_id uuid;v_parent_sale_item_id uuid;v_expected integer;v_actual integer;v_balance numeric;
begin
 select * into v_cart from public.sale_carts where id=p_cart_id and cashier_id=auth.uid() for update;if not found then raise exception 'Carrito no disponible.';end if;
 perform public.assert_restaurant_studio_access(v_cart.company_id,'use_pos');
 if v_cart.status='active' then perform public.quote_restaurant_pos_cart(p_cart_id);end if;
 if exists(select 1 from public.companies where id=v_cart.company_id and product_experience_code='restaurant') and v_cart.status='active' then
  perform public.assert_restaurant_cart_stock(p_cart_id);
  for v_instance in select i.*,b.is_active from public.sale_cart_bundle_instances i join public.sale_cart_items ci on ci.id=i.cart_item_id join public.restaurant_menu_bundles b on b.id=i.bundle_id where ci.cart_id=p_cart_id loop
   if not v_instance.is_active then raise exception 'Una comida ya no está configurada. Edita su selección.';end if;
   if v_instance.mode='complete' then
    for v_parent in select g.* from public.restaurant_menu_bundle_groups g where g.bundle_id=v_instance.bundle_id loop
     select count(*) into v_actual from public.sale_cart_bundle_selections s join public.restaurant_menu_bundle_options o on o.id=s.option_id and o.is_active where s.instance_id=v_instance.id and s.group_id=v_parent.id and o.group_id=v_parent.id and o.product_id=s.product_id and s.quantity=v_instance.quantity;
     if v_actual<v_parent.minimum_selections or v_actual>v_parent.maximum_selections then raise exception 'Revisa las opciones de % antes de cobrar.',v_parent.name;end if;
    end loop;
   end if;
   if exists(select 1 from public.sale_cart_bundle_extras x where x.instance_id=v_instance.id and not exists(select 1 from public.restaurant_menu_bundle_extras e where e.bundle_id=v_instance.bundle_id and e.product_id=x.product_id and e.is_active)) then raise exception 'Un extra ya no está configurado. Edita la comida.';end if;
  end loop;
  if exists(select 1 from public.sale_cart_items ci join public.sale_cart_bundle_instances i on i.cart_item_id=ci.id where ci.cart_id=p_cart_id group by ci.id having sum(i.quantity)>ci.quantity) then raise exception 'Las cantidades de las comidas cambiaron. Actualiza la venta.';end if;
  if exists(select 1 from public.sale_cart_bundle_extras e join public.sale_cart_bundle_instances i on i.id=e.instance_id join public.sale_cart_items parent on parent.id=i.cart_item_id left join public.sale_cart_items extra on extra.cart_id=parent.cart_id and extra.product_id=e.product_id where parent.cart_id=p_cart_id group by e.product_id,extra.quantity having sum(i.quantity)>coalesce(extra.quantity,0)) then raise exception 'Faltan extras en la venta. Edita las comidas antes de cobrar.';end if;
 end if;
 if p_sale_type='cash'then select*into v_method from public.payment_methods where id=p_payment_method_id and company_id=v_cart.company_id and is_active;if not found then raise exception 'Forma de pago no disponible.';end if;if v_method.settlement_kind='external'and v_reference is null then raise exception 'Captura la autorización o referencia del cobro externo.';end if;else v_reference:=null;end if;
 perform set_config('satrapy.pos_payment_reference',coalesce(v_reference,''),true);perform set_config('satrapy.pos_price_list_id',coalesce(v_cart.price_list_id::text,''),true);perform set_config('satrapy.pos_cart_id',v_cart.id::text,true);
 v_result:=public.complete_sale(p_cart_id,p_expected_revision,p_sale_type,p_payment_method_id,p_received_amount,p_client_request_id);v_sale_id:=(v_result->>'sale_id')::uuid;
 if not coalesce((v_result->>'idempotent')::boolean,false)then
  for v_instance in select i.* from public.sale_cart_bundle_instances i join public.sale_cart_items ci on ci.id=i.cart_item_id where ci.cart_id=p_cart_id order by i.created_at,i.id loop
   select si.id into v_parent_sale_item_id from public.sale_items si join public.sale_cart_items ci on ci.product_id=si.product_id where si.sale_id=v_sale_id and ci.id=v_instance.cart_item_id;
   insert into public.sale_item_bundle_instances(id,company_id,sale_item_id,bundle_id,mode,quantity,extras)values(v_instance.id,v_instance.company_id,v_parent_sale_item_id,v_instance.bundle_id,v_instance.mode,v_instance.quantity,coalesce((select jsonb_agg(jsonb_build_object('product_id',e.product_id,'name',p.name,'quantity',v_instance.quantity))from public.sale_cart_bundle_extras e join public.products p on p.id=e.product_id where e.instance_id=v_instance.id),'[]'));
    for v_selection in select s.*,g.name group_name,p.name product_name,p.internal_sku,p.alpha_sku,p.unit,p.tax_category_id,p.is_inventory_tracked from public.sale_cart_bundle_selections s join public.restaurant_menu_bundle_groups g on g.id=s.group_id join public.products p on p.id=s.product_id where s.instance_id=v_instance.id order by g.sort_order,p.name loop
    if not coalesce((public.validate_pos_product_for_location(v_cart.company_id,v_cart.location_id,v_selection.product_id)->>'allowed')::boolean,false)then raise exception 'La opción % ya no está disponible.',v_selection.product_name;end if;
    insert into public.sale_items(sale_id,product_id,product_code,product_name,unit_name,quantity,unit_price_amount,gross_amount,discount_percent,discount_amount,taxable_amount,tax_amount,total_amount)values(v_sale_id,v_selection.product_id,coalesce(v_selection.internal_sku,v_selection.alpha_sku),v_selection.product_name,v_selection.unit,v_selection.quantity,0,0,0,0,0,0,0)returning id into v_component_sale_item_id;
    insert into public.sale_item_taxes(sale_item_id,tax_category_id,tax_category_code,rate,tax_amount)select v_component_sale_item_id,t.id,t.code,0,0 from public.tax_categories t where t.id=v_selection.tax_category_id;
    if v_selection.is_inventory_tracked then
      select quantity_on_hand into v_balance from public.inventory_balances where company_id=v_cart.company_id and location_id=v_cart.location_id and product_id=v_selection.product_id for update;
      if coalesce(v_balance,0)<v_selection.quantity then raise exception 'Existencia insuficiente para %.',v_selection.product_name;end if;
      update public.inventory_balances set quantity_on_hand=quantity_on_hand-v_selection.quantity,updated_at=now() where company_id=v_cart.company_id and location_id=v_cart.location_id and product_id=v_selection.product_id returning quantity_on_hand into v_balance;
      insert into public.inventory_ledger(company_id,location_id,product_id,quantity_delta,balance_after,movement_type,sale_item_id,actor_id)values(v_cart.company_id,v_cart.location_id,v_selection.product_id,-v_selection.quantity,v_balance,'sale',v_component_sale_item_id,auth.uid());
    end if;
    insert into public.sale_item_bundle_selections(company_id,instance_id,group_name,product_id,product_name,quantity,component_sale_item_id)values(v_cart.company_id,v_instance.id,v_selection.group_name,v_selection.product_id,v_selection.product_name,v_selection.quantity,v_component_sale_item_id);
   end loop;
  end loop;
 end if;
 select ticket.payload into v_ticket_payload from public.canonical_tickets ticket where ticket.id=(v_result->>'ticket_id')::uuid;
 -- The canonical ticket is immutable. Keep it exactly as created by complete_sale;
 -- Restaurant's sold choices are retained in sale_item_bundle_* snapshots.
 if v_ticket_payload is not null then v_result:=jsonb_set(v_result,'{ticket}',v_ticket_payload,true);end if;
 return v_result;
end$$;

revoke all on function public.complete_restaurant_pos_sale(uuid,integer,text,uuid,numeric,uuid,text) from public,anon;
grant execute on function public.complete_restaurant_pos_sale(uuid,integer,text,uuid,numeric,uuid,text) to authenticated;

commit;
