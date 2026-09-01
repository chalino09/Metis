-- Restaurante · paquetes configurables en POS.
-- El producto padre conserva el precio comercial; las elecciones incluidas
-- consumen sus recetas sin volver a cobrar. Los extras son partidas normales.

begin;

create table public.restaurant_menu_bundles (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null unique references public.products(id) on delete cascade,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,id)
);

create table public.restaurant_menu_bundle_groups (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  bundle_id uuid not null references public.restaurant_menu_bundles(id) on delete cascade,
  name text not null check(length(trim(name))>0),
  minimum_selections integer not null default 1 check(minimum_selections>=0),
  maximum_selections integer not null default 1 check(maximum_selections>=minimum_selections and maximum_selections<=10),
  sort_order integer not null default 0,
  unique(bundle_id,name),
  unique(company_id,id)
);

create table public.restaurant_menu_bundle_options (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  group_id uuid not null references public.restaurant_menu_bundle_groups(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  unique(group_id,product_id)
);

create table public.restaurant_menu_bundle_extras (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  bundle_id uuid not null references public.restaurant_menu_bundles(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  unique(bundle_id,product_id)
);

create table public.sale_cart_bundle_instances (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  cart_item_id uuid not null references public.sale_cart_items(id) on delete cascade,
  bundle_id uuid not null references public.restaurant_menu_bundles(id) on delete restrict,
  created_at timestamptz not null default now()
);

create table public.sale_cart_bundle_selections (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  instance_id uuid not null references public.sale_cart_bundle_instances(id) on delete cascade,
  group_id uuid not null references public.restaurant_menu_bundle_groups(id) on delete restrict,
  option_id uuid not null references public.restaurant_menu_bundle_options(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity numeric(18,6) not null default 1 check(quantity>0),
  unique(instance_id,option_id)
);

create table public.sale_item_bundle_instances (
  id uuid primary key,
  company_id uuid not null references public.companies(id) on delete cascade,
  sale_item_id uuid not null references public.sale_items(id) on delete restrict,
  bundle_id uuid not null references public.restaurant_menu_bundles(id) on delete restrict,
  created_at timestamptz not null default now()
);

create table public.sale_item_bundle_selections (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  instance_id uuid not null references public.sale_item_bundle_instances(id) on delete restrict,
  group_name text not null,
  product_id uuid not null references public.products(id) on delete restrict,
  product_name text not null,
  quantity numeric(18,6) not null check(quantity>0),
  component_sale_item_id uuid not null unique references public.sale_items(id) on delete restrict
);

create index restaurant_menu_bundle_groups_bundle_idx on public.restaurant_menu_bundle_groups(bundle_id,sort_order,id);
create index restaurant_menu_bundle_options_group_idx on public.restaurant_menu_bundle_options(group_id,sort_order,id) where is_active;
create index restaurant_menu_bundle_extras_bundle_idx on public.restaurant_menu_bundle_extras(bundle_id,sort_order,id) where is_active;
create index sale_cart_bundle_instances_item_idx on public.sale_cart_bundle_instances(cart_item_id,created_at,id);
create index sale_cart_bundle_selections_instance_idx on public.sale_cart_bundle_selections(instance_id,group_id);
create index sale_item_bundle_instances_item_idx on public.sale_item_bundle_instances(sale_item_id);

alter table public.restaurant_menu_bundles enable row level security;
alter table public.restaurant_menu_bundle_groups enable row level security;
alter table public.restaurant_menu_bundle_options enable row level security;
alter table public.restaurant_menu_bundle_extras enable row level security;
alter table public.sale_cart_bundle_instances enable row level security;
alter table public.sale_cart_bundle_selections enable row level security;
alter table public.sale_item_bundle_instances enable row level security;
alter table public.sale_item_bundle_selections enable row level security;

create policy restaurant_menu_bundles_read on public.restaurant_menu_bundles for select to authenticated using(public.has_company_permission(company_id,'use_pos') or public.has_company_permission(company_id,'manage_products'));
create policy restaurant_menu_bundle_groups_read on public.restaurant_menu_bundle_groups for select to authenticated using(public.has_company_permission(company_id,'use_pos') or public.has_company_permission(company_id,'manage_products'));
create policy restaurant_menu_bundle_options_read on public.restaurant_menu_bundle_options for select to authenticated using(public.has_company_permission(company_id,'use_pos') or public.has_company_permission(company_id,'manage_products'));
create policy restaurant_menu_bundle_extras_read on public.restaurant_menu_bundle_extras for select to authenticated using(public.has_company_permission(company_id,'use_pos') or public.has_company_permission(company_id,'manage_products'));

revoke all on public.restaurant_menu_bundles,public.restaurant_menu_bundle_groups,public.restaurant_menu_bundle_options,public.restaurant_menu_bundle_extras,public.sale_cart_bundle_instances,public.sale_cart_bundle_selections,public.sale_item_bundle_instances,public.sale_item_bundle_selections from public,anon,authenticated;
grant select on public.restaurant_menu_bundles,public.restaurant_menu_bundle_groups,public.restaurant_menu_bundle_options,public.restaurant_menu_bundle_extras to authenticated;

create or replace function public.get_pos_restaurant_bundle(
  p_cart_id uuid,
  p_product_id uuid,
  p_at timestamptz default now()
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_cart public.sale_carts%rowtype;v_bundle public.restaurant_menu_bundles%rowtype;v_groups jsonb;v_extras jsonb;
begin
  select * into v_cart from public.sale_carts where id=p_cart_id;
  if not found or v_cart.cashier_id<>auth.uid() or v_cart.status<>'active' then raise exception 'Carrito no disponible.';end if;
  perform public.assert_pos_access(v_cart.company_id,v_cart.location_id,'use_pos');
  select * into v_bundle from public.restaurant_menu_bundles where company_id=v_cart.company_id and product_id=p_product_id and is_active;
  if not found then return jsonb_build_object('configured',false);end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'name',g.name,'minimum',g.minimum_selections,'maximum',g.maximum_selections,'options',coalesce(o.items,'[]'::jsonb)) order by g.sort_order,g.name),'[]'::jsonb)
  into v_groups from public.restaurant_menu_bundle_groups g left join lateral(
    select jsonb_agg(jsonb_build_object('id',x.id,'product_id',p.id,'name',p.name,'available',coalesce((public.validate_pos_product_for_location(v_cart.company_id,v_cart.location_id,p.id,p_at)->>'allowed')::boolean,false)) order by x.sort_order,p.name)items
    from public.restaurant_menu_bundle_options x join public.products p on p.id=x.product_id where x.group_id=g.id and x.is_active and p.is_active
  )o on true where g.bundle_id=v_bundle.id;
  select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'product_id',p.id,'name',p.name,'available',coalesce((public.validate_pos_product_for_location(v_cart.company_id,v_cart.location_id,p.id,p_at)->>'allowed')::boolean,false),'price',public.resolve_pos_sale_price(v_cart.company_id,v_cart.location_id,v_cart.customer_id,p.id,p_at)) order by x.sort_order,p.name),'[]'::jsonb)
  into v_extras from public.restaurant_menu_bundle_extras x join public.products p on p.id=x.product_id where x.bundle_id=v_bundle.id and x.is_active and p.is_active;
  return jsonb_build_object('configured',true,'bundle_id',v_bundle.id,'product_id',p_product_id,'groups',v_groups,'extras',v_extras);
end$$;

create or replace function public.list_sale_cart_bundle_instances(p_cart_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_cart public.sale_carts%rowtype;v_result jsonb;
begin
 select * into v_cart from public.sale_carts where id=p_cart_id;
 if not found or v_cart.cashier_id<>auth.uid() then raise exception 'Carrito no disponible.';end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'cart_item_id',i.cart_item_id,'selections',coalesce(s.items,'[]'::jsonb)) order by i.created_at,i.id),'[]'::jsonb) into v_result
 from public.sale_cart_bundle_instances i left join lateral(
   select jsonb_agg(jsonb_build_object('group',g.name,'product_id',x.product_id,'name',p.name,'quantity',x.quantity) order by g.sort_order,p.name)items
   from public.sale_cart_bundle_selections x join public.restaurant_menu_bundle_groups g on g.id=x.group_id join public.products p on p.id=x.product_id where x.instance_id=i.id
 )s on true where i.company_id=v_cart.company_id and i.cart_item_id in(select id from public.sale_cart_items where cart_id=p_cart_id);
 return v_result;
end$$;

create or replace function public.add_restaurant_bundle_to_cart(
  p_cart_id uuid,p_product_id uuid,p_selections jsonb,p_extra_product_ids uuid[] default '{}',p_expected_revision integer default null,p_client_request_id uuid default gen_random_uuid()
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_cart public.sale_carts%rowtype;v_bundle public.restaurant_menu_bundles%rowtype;v_group record;v_selected_count integer;v_selection record;v_change jsonb;v_revision integer;v_item_id uuid;v_instance_id uuid;v_extra uuid;v_quote jsonb;
begin
 select * into v_cart from public.sale_carts where id=p_cart_id for update;
 if not found or v_cart.cashier_id<>auth.uid() or v_cart.status<>'active' then raise exception 'Carrito no disponible.';end if;
 if p_expected_revision is not null and v_cart.revision<>p_expected_revision then raise exception 'El carrito cambió en otra operación; actualiza la vista.';end if;
 select * into v_bundle from public.restaurant_menu_bundles where company_id=v_cart.company_id and product_id=p_product_id and is_active;
 if not found then raise exception 'El paquete ya no está disponible.';end if;
 for v_group in select * from public.restaurant_menu_bundle_groups where bundle_id=v_bundle.id order by sort_order,id loop
   select count(*) into v_selected_count from jsonb_array_elements_text(coalesce(p_selections->v_group.id::text,'[]'::jsonb)) selected
   join public.restaurant_menu_bundle_options option on option.id=selected.value::uuid and option.group_id=v_group.id and option.is_active;
   if v_selected_count<v_group.minimum_selections or v_selected_count>v_group.maximum_selections then raise exception 'Elige entre % y % opciones en %.',v_group.minimum_selections,v_group.maximum_selections,v_group.name;end if;
 end loop;
 v_change:=public.change_sale_cart_item(p_cart_id,p_product_id,1,v_cart.revision);v_revision:=(v_change->>'revision')::integer;
 select id into v_item_id from public.sale_cart_items where cart_id=p_cart_id and product_id=p_product_id;
 insert into public.sale_cart_bundle_instances(company_id,cart_item_id,bundle_id)values(v_cart.company_id,v_item_id,v_bundle.id)returning id into v_instance_id;
 for v_selection in select g.id group_id,o.id option_id,o.product_id from public.restaurant_menu_bundle_groups g cross join lateral jsonb_array_elements_text(coalesce(p_selections->g.id::text,'[]'::jsonb))j join public.restaurant_menu_bundle_options o on o.id=j.value::uuid and o.group_id=g.id and o.is_active where g.bundle_id=v_bundle.id loop
   if not coalesce((public.validate_pos_product_for_location(v_cart.company_id,v_cart.location_id,v_selection.product_id)->>'allowed')::boolean,false)then raise exception 'Una elección incluida ya no está disponible.';end if;
   insert into public.sale_cart_bundle_selections(company_id,instance_id,group_id,option_id,product_id)values(v_cart.company_id,v_instance_id,v_selection.group_id,v_selection.option_id,v_selection.product_id);
 end loop;
 foreach v_extra in array coalesce(p_extra_product_ids,'{}') loop
   if not exists(select 1 from public.restaurant_menu_bundle_extras where bundle_id=v_bundle.id and product_id=v_extra and is_active)then raise exception 'El extra no corresponde a este paquete.';end if;
   v_change:=public.change_sale_cart_item(p_cart_id,v_extra,1,v_revision);v_revision:=(v_change->>'revision')::integer;
 end loop;
 v_quote:=public.quote_sale_cart(p_cart_id);
 perform public.write_sales_audit(v_cart.company_id,'sale_cart.restaurant_bundle_added','sale_carts',p_cart_id,jsonb_build_object('bundle_id',v_bundle.id,'instance_id',v_instance_id,'extras',coalesce(to_jsonb(p_extra_product_ids),'[]'::jsonb),'client_request_id',p_client_request_id));
 return v_quote||jsonb_build_object('bundle_instance_id',v_instance_id);
end$$;

create or replace function public.remove_restaurant_bundle_from_cart(
  p_cart_id uuid,p_instance_id uuid,p_expected_revision integer
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_cart public.sale_carts%rowtype;v_instance public.sale_cart_bundle_instances%rowtype;v_product_id uuid;v_change jsonb;
begin
 select * into v_cart from public.sale_carts where id=p_cart_id for update;
 if not found or v_cart.cashier_id<>auth.uid() or v_cart.status<>'active' then raise exception 'Carrito no disponible.';end if;
 if v_cart.revision<>p_expected_revision then raise exception 'El carrito cambió en otra operación; actualiza la vista.';end if;
 select i.* into v_instance from public.sale_cart_bundle_instances i join public.sale_cart_items item on item.id=i.cart_item_id where i.id=p_instance_id and item.cart_id=p_cart_id;
 if not found then raise exception 'La comida seleccionada ya no está en la venta.';end if;
 select product_id into v_product_id from public.sale_cart_items where id=v_instance.cart_item_id;
 delete from public.sale_cart_bundle_instances where id=v_instance.id;
 v_change:=public.change_sale_cart_item(p_cart_id,v_product_id,-1,v_cart.revision);
 perform public.write_sales_audit(v_cart.company_id,'sale_cart.restaurant_bundle_removed','sale_carts',p_cart_id,jsonb_build_object('bundle_id',v_instance.bundle_id,'instance_id',v_instance.id));
 return public.quote_sale_cart(p_cart_id);
end$$;

-- Un paquete padre no necesita receta propia: la disponibilidad culinaria se
-- valida sobre cada elección cuando se agrega y nuevamente antes de cobrar.
create or replace function public.culinary_pos_readiness(
  p_company_id uuid,p_location_id uuid,p_product_id uuid,p_quantity numeric default 1,p_at timestamptz default now(),p_currency_code text default 'MXN'
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_cost jsonb;v_cost_warnings jsonb:='[]'::jsonb;v_missing jsonb;v_conversion_missing jsonb;v_version uuid;
begin
 if exists(select 1 from public.restaurant_menu_bundles where company_id=p_company_id and product_id=p_product_id and is_active)then return jsonb_build_object('allowed',true,'bundle',true,'blockers','[]'::jsonb,'warnings','[]'::jsonb);end if;
 if p_quantity is null or p_quantity<=0 then raise exception 'La cantidad debe ser mayor que cero.';end if;
 select rv.id into v_version from public.culinary_recipes r join public.culinary_recipe_versions rv on rv.recipe_id=r.id where r.company_id=p_company_id and r.product_id=p_product_id and rv.status='active' and rv.valid_from<=p_at and(rv.valid_to is null or rv.valid_to>p_at);
 if v_version is null then return jsonb_build_object('allowed',false,'blockers',jsonb_build_array(jsonb_build_object('code','missing_active_recipe','message','Agrega y activa una receta.')),'warnings','[]'::jsonb);end if;
 begin v_cost:=public.culinary_version_cost(v_version,p_quantity,p_at,p_currency_code);exception when others then return jsonb_build_object('allowed',false,'recipe_version_id',v_version,'blockers',jsonb_build_array(jsonb_build_object('code','invalid_recipe_conversion','message',sqlerrm)),'warnings','[]'::jsonb);end;
 if not coalesce((v_cost->>'allowed')::boolean,false)then if v_cost#>>'{blockers,0,code}'='missing_component_cost'then v_cost_warnings:=coalesce(v_cost->'blockers','[]'::jsonb);else return v_cost||jsonb_build_object('recipe_version_id',v_version,'warnings','[]'::jsonb);end if;end if;
 with needed as(select*from public.expand_culinary_recipe(v_version,p_quantity))select jsonb_agg(jsonb_build_object('product_id',p.id,'product_name',p.name)order by p.name)into v_conversion_missing from needed n join public.products p on p.id=n.ingredient_product_id left join public.product_purchase_units u on u.product_id=p.id where p.is_inventory_tracked and(p.base_unit_id is null or u.product_id is null or u.base_units_per_purchase_unit<=0);
 if v_conversion_missing is not null then return v_cost||jsonb_build_object('allowed',false,'recipe_version_id',v_version,'warnings',v_cost_warnings,'blockers',jsonb_build_array(jsonb_build_object('code','missing_purchase_conversion','message','Configura la unidad de compra y su equivalencia para los ingredientes indicados.','ingredients',v_conversion_missing)));end if;
 with needed as(select*from public.expand_culinary_recipe(v_version,p_quantity)),short as(select n.ingredient_product_id,p.name,n.quantity,coalesce(b.quantity_on_hand,0)available from needed n join public.products p on p.id=n.ingredient_product_id left join public.inventory_balances b on b.company_id=p_company_id and b.location_id=p_location_id and b.product_id=n.ingredient_product_id where coalesce(b.quantity_on_hand,0)<n.quantity)select jsonb_agg(jsonb_build_object('product_id',ingredient_product_id,'product_name',name,'required',quantity,'available',available)order by name)into v_missing from short;
 if v_missing is not null then return v_cost||jsonb_build_object('allowed',false,'recipe_version_id',v_version,'warnings',v_cost_warnings,'blockers',jsonb_build_array(jsonb_build_object('code','insufficient_ingredient_stock','message','No hay existencia suficiente de los ingredientes de la receta.','ingredients',v_missing)));end if;
 return v_cost||jsonb_build_object('allowed',true,'recipe_version_id',v_version,'blockers','[]'::jsonb,'warnings',v_cost_warnings);
end$$;

-- Conserva la firma pública vigente y completa las elecciones dentro de la
-- misma transacción que el cobro.
create or replace function public.complete_pos_sale(
  p_cart_id uuid,p_expected_revision integer,p_sale_type text,p_payment_method_id uuid default null,p_received_amount numeric default null,p_client_request_id uuid default null,p_payment_reference text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_cart public.sale_carts%rowtype;v_method public.payment_methods%rowtype;v_reference text:=nullif(trim(coalesce(p_payment_reference,'')),'');v_result jsonb;v_ticket_payload jsonb;v_parent record;v_instance record;v_selection record;v_component_sale_item_id uuid;v_sale_id uuid;v_parent_sale_item_id uuid;v_expected integer;v_actual integer;
begin
 select * into v_cart from public.sale_carts where id=p_cart_id and cashier_id=auth.uid();if not found then raise exception 'Carrito no disponible.';end if;
 for v_parent in select i.id cart_item_id,i.product_id,i.quantity,b.id bundle_id from public.sale_cart_items i join public.restaurant_menu_bundles b on b.product_id=i.product_id and b.company_id=v_cart.company_id and b.is_active where i.cart_id=p_cart_id loop
   select count(*) into v_actual from public.sale_cart_bundle_instances where cart_item_id=v_parent.cart_item_id;v_expected:=v_parent.quantity::integer;if v_actual<>v_expected then raise exception 'Completa las elecciones de cada paquete antes de cobrar.';end if;
 end loop;
 if p_sale_type='cash'then select*into v_method from public.payment_methods where id=p_payment_method_id and company_id=v_cart.company_id and is_active;if not found then raise exception 'Forma de pago no disponible.';end if;if v_method.settlement_kind='external'and v_reference is null then raise exception 'Captura la autorización o referencia del cobro externo.';end if;else v_reference:=null;end if;
 perform set_config('satrapy.pos_payment_reference',coalesce(v_reference,''),true);perform set_config('satrapy.pos_price_list_id',coalesce(v_cart.price_list_id::text,''),true);perform set_config('satrapy.pos_cart_id',v_cart.id::text,true);
 v_result:=public.complete_sale(p_cart_id,p_expected_revision,p_sale_type,p_payment_method_id,p_received_amount,p_client_request_id);v_sale_id:=(v_result->>'sale_id')::uuid;
 if not coalesce((v_result->>'idempotent')::boolean,false)then
  for v_instance in select i.* from public.sale_cart_bundle_instances i join public.sale_cart_items ci on ci.id=i.cart_item_id where ci.cart_id=p_cart_id order by i.created_at,i.id loop
   select si.id into v_parent_sale_item_id from public.sale_items si join public.sale_cart_items ci on ci.product_id=si.product_id where si.sale_id=v_sale_id and ci.id=v_instance.cart_item_id;
   insert into public.sale_item_bundle_instances(id,company_id,sale_item_id,bundle_id)values(v_instance.id,v_instance.company_id,v_parent_sale_item_id,v_instance.bundle_id);
   for v_selection in select s.*,g.name group_name,p.name product_name,p.internal_sku,p.alpha_sku,p.unit,p.tax_category_id from public.sale_cart_bundle_selections s join public.restaurant_menu_bundle_groups g on g.id=s.group_id join public.products p on p.id=s.product_id where s.instance_id=v_instance.id order by g.sort_order,p.name loop
    if not coalesce((public.validate_pos_product_for_location(v_cart.company_id,v_cart.location_id,v_selection.product_id)->>'allowed')::boolean,false)then raise exception 'La opción % ya no está disponible.',v_selection.product_name;end if;
    insert into public.sale_items(sale_id,product_id,product_code,product_name,unit_name,quantity,unit_price_amount,gross_amount,discount_percent,discount_amount,taxable_amount,tax_amount,total_amount)values(v_sale_id,v_selection.product_id,coalesce(v_selection.internal_sku,v_selection.alpha_sku),v_selection.product_name,v_selection.unit,v_selection.quantity,0,0,0,0,0,0,0)returning id into v_component_sale_item_id;
    insert into public.sale_item_taxes(sale_item_id,tax_category_id,tax_category_code,rate,tax_amount)select v_component_sale_item_id,t.id,t.code,0,0 from public.tax_categories t where t.id=v_selection.tax_category_id;
    insert into public.sale_item_bundle_selections(company_id,instance_id,group_name,product_id,product_name,quantity,component_sale_item_id)values(v_cart.company_id,v_instance.id,v_selection.group_name,v_selection.product_id,v_selection.product_name,v_selection.quantity,v_component_sale_item_id);
   end loop;
  end loop;
 end if;
 select ticket.payload into v_ticket_payload from public.canonical_tickets ticket where ticket.id=(v_result->>'ticket_id')::uuid;
 if v_ticket_payload is not null then
  select jsonb_set(v_ticket_payload,'{items}',coalesce(jsonb_agg(item_payload order by ordinal),'[]'::jsonb),true) into v_ticket_payload from(
   select ordinal,item_payload||case when x.selections is null then '{}'::jsonb else jsonb_build_object('selections',x.selections)end item_payload
   from jsonb_array_elements(v_ticket_payload->'items')with ordinality t(item_payload,ordinal)
   left join lateral(select jsonb_agg(jsonb_build_object('group',s.group_name,'name',s.product_name,'quantity',s.quantity)order by s.group_name,s.product_name)selections from public.sale_item_bundle_instances i join public.sale_item_bundle_selections s on s.instance_id=i.id join public.sale_items si on si.id=i.sale_item_id where si.sale_id=v_sale_id and si.product_code=t.item_payload->>'product_code')x on true
  )q;
  update public.canonical_tickets set payload=v_ticket_payload,content_sha256=encode(digest(v_ticket_payload::text,'sha256'),'hex')where id=(v_result->>'ticket_id')::uuid;
  v_result:=jsonb_set(v_result,'{ticket}',v_ticket_payload,true);
 end if;
 return v_result;
end$$;

revoke all on function public.get_pos_restaurant_bundle(uuid,uuid,timestamptz),public.list_sale_cart_bundle_instances(uuid),public.add_restaurant_bundle_to_cart(uuid,uuid,jsonb,uuid[],integer,uuid),public.remove_restaurant_bundle_from_cart(uuid,uuid,integer) from public,anon;
grant execute on function public.get_pos_restaurant_bundle(uuid,uuid,timestamptz),public.list_sale_cart_bundle_instances(uuid),public.add_restaurant_bundle_to_cart(uuid,uuid,jsonb,uuid[],integer,uuid),public.remove_restaurant_bundle_from_cart(uuid,uuid,integer) to authenticated;
grant execute on function public.culinary_pos_readiness(uuid,uuid,uuid,numeric,timestamptz,text),public.complete_pos_sale(uuid,integer,text,uuid,numeric,uuid,text) to authenticated;

commit;
