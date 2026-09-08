-- Restaurante: editor integrado. No reemplaza funciones compartidas ni funciones POS.
-- Altas puntuales; máximo 100 componentes. Importaciones siguen usando sus RPC por lote.
begin;

create table public.restaurant_menu_presentations (
  product_id uuid primary key references public.products(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  description text not null default '' check(length(description)<=600),
  image_data text check(image_data is null or (length(image_data)<=1400000 and image_data ~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$')),
  batch_portions numeric not null default 1 check(batch_portions>0 and batch_portions<=100000),
  revision integer not null default 1,
  updated_at timestamptz not null default now()
);
alter table public.restaurant_menu_presentations enable row level security;
create policy restaurant_menu_presentations_read on public.restaurant_menu_presentations for select to authenticated
  using(public.has_company_permission(company_id,'view_products'));
grant select on public.restaurant_menu_presentations to authenticated;
revoke insert,update,delete on public.restaurant_menu_presentations from authenticated,anon;

create unique index restaurant_studio_request_once on public.audit_log(company_id,(metadata->>'request_id'))
  where action in ('restaurant.studio_saved','restaurant.ingredient_studio_saved') and metadata ? 'request_id';

create function public.assert_restaurant_studio_access(p_company_id uuid,p_permission text)
returns void language plpgsql stable security definer set search_path=public as $$
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,p_permission) then raise exception 'No tienes permiso para esta operación de Restaurante.';end if;
  if not exists(select 1 from public.companies where id=p_company_id and product_experience_code='restaurant') then raise exception 'Esta operación sólo está disponible en Restaurante.';end if;
end$$;
revoke all on function public.assert_restaurant_studio_access(uuid,text) from public,anon,authenticated;

create function public.restaurant_studio_location_status(p_company_id uuid,p_product_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_location record;v_check jsonb;v_items jsonb:='[]';
begin
  for v_location in
    select distinct l.id,l.name from public.sales_assortment_items i join public.sales_assortments s on s.id=i.assortment_id and s.company_id=p_company_id and s.status='active' and(s.valid_from is null or s.valid_from<=now()) and(s.valid_to is null or s.valid_to>now()) join public.location_sales_assortments a on a.assortment_id=s.id and a.valid_from<=now() and(a.valid_to is null or a.valid_to>now()) join public.locations l on l.id=a.location_id and l.company_id=p_company_id and l.is_active where i.product_id=p_product_id and public.can_access_location(l.id) order by l.name
  loop
    v_check:=public.validate_pos_product_for_location(p_company_id,v_location.id,p_product_id,now());
    v_items:=v_items||jsonb_build_array(jsonb_build_object('id',v_location.id,'name',v_location.name,'available',coalesce((v_check->>'allowed')::boolean,false),'message',case when coalesce((v_check->>'allowed')::boolean,false) then case when coalesce((v_check#>>'{culinary_readiness,bundle}')::boolean,false) then 'Configura la comida en POS para comprobar las existencias de sus opciones.' else 'Disponible para vender' end else coalesce(v_check#>>'{culinary_readiness,blockers,0,message}','Revisa el precio, impuesto y configuración de venta de esta sucursal.') end));
  end loop;
  return v_items;
end$$;
revoke all on function public.restaurant_studio_location_status(uuid,uuid) from public,anon,authenticated;

create function public.search_restaurant_studio_catalog(p_company_id uuid,p_role text default 'dish',p_query text default null,p_page integer default 1,p_page_size integer default 24,p_is_sellable boolean default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_result jsonb;v_item jsonb;v_items jsonb:='[]';v_image text;v_price numeric;v_currency text;v_tax numeric;v_status jsonb;v_list uuid;
begin
  v_result:=public.search_restaurant_catalog(p_company_id,p_role,p_query,p_page,least(p_page_size,24),p_is_sellable);
  select l.id into v_list from public.price_lists l join public.companies c on c.id=l.company_id where c.id=p_company_id and l.is_active and l.status='active' order by(l.id=c.default_price_list_id) desc,l.is_default desc,l.name limit 1;
  for v_item in select value from jsonb_array_elements(v_result->'items') loop
    v_price:=null;v_currency:=null;v_tax:=null;v_status:='[]';
    select image_data into v_image from public.restaurant_menu_presentations where company_id=p_company_id and product_id=(v_item->>'id')::uuid;
    if p_role='dish' then
      if public.has_company_permission(p_company_id,'view_prices') then
        select p.amount,p.currency_code into v_price,v_currency from public.product_prices p where p.product_id=(v_item->>'id')::uuid and p.price_list_id=v_list and p.valid_from<=now() and(p.valid_to is null or p.valid_to>now()) order by p.valid_from desc limit 1;
        select t.rate into v_tax from public.products p join public.tax_rates t on t.tax_category_id=p.tax_category_id and t.valid_from<=now() and(t.valid_to is null or t.valid_to>now()) where p.id=(v_item->>'id')::uuid and p.company_id=p_company_id order by t.valid_from desc limit 1;
      end if;
      v_status:=public.restaurant_studio_location_status(p_company_id,(v_item->>'id')::uuid);
      v_item:=v_item||jsonb_build_object('price',case when v_tax is not null then round(v_price*(1+v_tax),2) end,'currency_code',v_currency,'location_status',v_status,'ready_location_count',(select count(*) from jsonb_array_elements(v_status) x where(x->>'available')::boolean));
    end if;
    v_items:=v_items||jsonb_build_array(v_item||jsonb_build_object('image_data',v_image));
  end loop;
  return jsonb_set(v_result,'{items}',v_items);
end$$;
revoke all on function public.search_restaurant_studio_catalog(uuid,text,text,integer,integer,boolean) from public,anon;
grant execute on function public.search_restaurant_studio_catalog(uuid,text,text,integer,integer,boolean) to authenticated;

create function public.get_restaurant_studio_context(p_company_id uuid,p_product_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_product public.products%rowtype;v_result jsonb;v_recipe jsonb;v_tax numeric;v_bundle public.restaurant_menu_bundles%rowtype;v_state text;
begin
  perform public.assert_restaurant_studio_access(p_company_id,'view_products');
  if p_product_id is not null then
    select p.* into v_product from public.products p join public.product_culinary_roles r on r.product_id=p.id and r.company_id=p.company_id where p.id=p_product_id and p.company_id=p_company_id;
    if not found then raise exception 'No se encontró el registro de Restaurante.';end if;
    if public.has_company_permission(p_company_id,'view_recipes') then
      v_recipe:=public.get_culinary_recipe_context(p_company_id,p_product_id);
      -- El contrato anterior calcula costos internamente; este editor los oculta sin view_costs.
      v_recipe:=((v_recipe #- '{active,cost}'::text[]) #- '{draft,cost}'::text[]) - 'sale_price'::text;
      -- Conserva las notas de recetas importadas aunque el contexto anterior no las incluya.
      foreach v_state in array array['active','draft'] loop
        if jsonb_typeof(v_recipe->v_state)='object' then
          v_recipe:=jsonb_set(v_recipe,array[v_state,'components'],(select coalesce(jsonb_agg(x.value||jsonb_build_object('notes',c.notes) order by x.ordinal),'[]') from jsonb_array_elements(v_recipe#>array[v_state,'components']) with ordinality x(value,ordinal) left join public.culinary_recipe_components c on c.id=(x.value->>'id')::uuid));
        end if;
      end loop;
    end if;
    select rate into v_tax from public.tax_rates where tax_category_id=v_product.tax_category_id and valid_from<=now() and(valid_to is null or valid_to>now()) order by valid_from desc limit 1;
  end if;
  v_result:=jsonb_build_object(
    'currency_code',(select coalesce(base_currency_code,'MXN') from public.companies where id=p_company_id),
    'product',case when p_product_id is null then null else to_jsonb(v_product) end,
    'recipe',v_recipe,
    'location_status',case when p_product_id is null then '[]'::jsonb else public.restaurant_studio_location_status(p_company_id,p_product_id) end,
    'recipe_revision',(select coalesce(string_agg(v.id::text||':'||v.updated_at::text||':'||v.status,',' order by v.id),'') from public.culinary_recipes r join public.culinary_recipe_versions v on v.recipe_id=r.id and v.status in ('active','draft') where r.company_id=p_company_id and r.product_id=p_product_id),
    'presentation',(select to_jsonb(m) from public.restaurant_menu_presentations m where m.product_id=p_product_id and m.company_id=p_company_id),
    'tax_categories',coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'name',t.name,'is_active',t.is_active,'rate',(select rate from public.tax_rates where tax_category_id=t.id and valid_from<=now() and(valid_to is null or valid_to>now()) order by valid_from desc limit 1)) order by t.name) from public.tax_categories t where t.company_id=p_company_id and t.is_active),'[]'),
    'price_lists',case when public.has_company_permission(p_company_id,'manage_prices') or public.has_company_permission(p_company_id,'view_prices') then coalesce((select jsonb_agg(jsonb_build_object('id',l.id,'name',l.name,'currency_code',l.currency_code,'is_default',l.is_default or l.id=c.default_price_list_id) order by l.is_default desc,l.name) from public.price_lists l join public.companies c on c.id=l.company_id where l.company_id=p_company_id and l.is_active and l.status='active'),'[]') else '[]'::jsonb end,
    'prices',case when public.has_company_permission(p_company_id,'view_prices') or public.has_company_permission(p_company_id,'manage_prices') then coalesce((select jsonb_agg(jsonb_build_object('price_list_id',p.price_list_id,'amount',p.amount,'final_price',case when v_tax is not null then round(p.amount*(1+v_tax),2) end)) from public.product_prices p join public.price_lists price_list on price_list.id=p.price_list_id and price_list.company_id=p_company_id where p.product_id=p_product_id and p.valid_from<=now() and(p.valid_to is null or p.valid_to>now())),'[]') else '[]'::jsonb end,
    'assortments',case when public.has_company_permission(p_company_id,'manage_assortments') then coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'included',exists(select 1 from public.sales_assortment_items i where i.assortment_id=s.id and i.product_id=p_product_id),'locations',coalesce((select jsonb_agg(jsonb_build_object('id',l.id,'name',l.name) order by l.name) from public.location_sales_assortments a join public.locations l on l.id=a.location_id and l.company_id=p_company_id and l.is_active where a.assortment_id=s.id and a.valid_from<=now() and(a.valid_to is null or a.valid_to>now())),'[]')) order by s.name) from public.sales_assortments s where s.company_id=p_company_id and s.status='active' and(s.valid_from is null or s.valid_from<=now()) and(s.valid_to is null or s.valid_to>now())),'[]') else '[]'::jsonb end,
    'locations',case when public.has_company_permission(p_company_id,'manage_assortments') then coalesce((select jsonb_agg(jsonb_build_object('id',l.id,'name',l.name) order by l.name) from public.locations l where l.company_id=p_company_id and l.is_active and l.location_type='sucursal'),'[]') else '[]'::jsonb end,
    'purchase',case when p_product_id is null then null else public.get_product_purchase_unit(p_company_id,p_product_id) end,
    'cost',case when p_product_id is not null and public.has_company_permission(p_company_id,'import_costs') then public.get_product_cost_admin_context(p_company_id,p_product_id) else null end
  );
  select * into v_bundle from public.restaurant_menu_bundles where company_id=p_company_id and product_id=p_product_id;
  if found then
    v_result:=v_result||jsonb_build_object('bundle',jsonb_build_object('is_active',v_bundle.is_active,'combo_price_amount',case when public.has_company_permission(p_company_id,'view_prices') or public.has_company_permission(p_company_id,'manage_prices') then v_bundle.combo_price_amount::text end,
      'groups',coalesce((select jsonb_agg(jsonb_build_object('name',g.name,'minimum_selections',g.minimum_selections,'maximum_selections',g.maximum_selections,'options',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name) order by o.sort_order) from public.restaurant_menu_bundle_options o join public.products p on p.id=o.product_id where o.group_id=g.id and o.is_active),'[]')) order by g.sort_order) from public.restaurant_menu_bundle_groups g where g.bundle_id=v_bundle.id),'[]'),
      'extras',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name) order by e.sort_order) from public.restaurant_menu_bundle_extras e join public.products p on p.id=e.product_id where e.bundle_id=v_bundle.id and e.is_active),'[]')));
  end if;
  return v_result;
end$$;

-- Costeo de una tanda sin crear borradores ni modificar productos.
create function public.preview_restaurant_recipe_cost(p_company_id uuid,p_components jsonb,p_portions numeric default 1,p_waste_percent numeric default 0,p_currency_code text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_currency text;v_method text;v_line jsonb;v_product public.products%rowtype;v_role text;v_version public.culinary_recipe_versions%rowtype;v_quantity numeric;v_cost numeric;v_total numeric:=0;v_known boolean:=true;v_lines jsonb:='[]';v_child jsonb;v_base text;
begin
  perform public.assert_restaurant_studio_access(p_company_id,'view_recipes');
  select coalesce(p_currency_code,base_currency_code,'MXN') into v_currency from public.companies where id=p_company_id;
  if not public.has_company_permission(p_company_id,'view_costs') then return jsonb_build_object('can_view',false,'allowed',false,'total_cost',null,'cost_per_portion',null,'currency_code',v_currency,'lines','[]'::jsonb);end if;
  if p_portions is null or not(p_portions>0 and p_portions<=100000) or p_waste_percent is null or not(p_waste_percent>=0 and p_waste_percent<100) then raise exception 'Indica un rendimiento mayor que cero y una merma menor a 100%%.';end if;
  if jsonb_typeof(p_components) is distinct from 'array' or jsonb_array_length(p_components)>100 then raise exception 'La receta admite hasta 100 ingredientes.';end if;
  select coalesce(cost_method,'replacement_cost') into v_method from public.accounting_event_rule_sets where company_id=p_company_id and status='approved';v_method:=coalesce(v_method,'replacement_cost');
  for v_line in select value from jsonb_array_elements(p_components) loop
    v_cost:=null;v_version:=null;v_child:=null;
    select p.* into v_product from public.products p where p.id=(v_line->>'product_id')::uuid and p.company_id=p_company_id and p.is_active;
    if not found then raise exception 'Uno de los insumos ya no está activo. Vuelve a seleccionarlo.';end if;
    select role into v_role from public.product_culinary_roles where product_id=v_product.id and company_id=p_company_id;
    if v_role is null or v_role not in ('ingredient','preparation') then raise exception 'Agrega insumos o bases reutilizables a la receta.';end if;
    v_base:=lower(v_product.unit);
    if v_role='preparation' then
      select v.* into v_version from public.culinary_recipes r join public.culinary_recipe_versions v on v.recipe_id=r.id and v.status='active' where r.company_id=p_company_id and r.product_id=v_product.id;
      if not found then raise exception 'Activa la receta de la base antes de usarla.';end if;
      v_base:=v_version.yield_unit_code;
    end if;
    if v_line->>'base_unit_code' is distinct from v_base then raise exception 'La unidad de un ingrediente cambió. Vuelve a seleccionarlo.';end if;
    v_quantity:=(v_line->>'quantity')::numeric;
    if v_quantity is null or not(v_quantity>0 and v_quantity<1000000000) then raise exception 'Escribe cantidades mayores que cero.';end if;
    v_quantity:=public.normalize_culinary_quantity(v_quantity,lower(v_line->>'unit_code'),v_base)/(1-p_waste_percent/100);
    if v_role='ingredient' then
      select v_quantity*c.amount into v_cost from public.product_costs c where c.company_id=p_company_id and c.product_id=v_product.id and c.cost_type=v_method and c.currency_code=v_currency and c.valid_from<=now() and(c.valid_to is null or c.valid_to>now()) order by c.valid_from desc,c.id desc limit 1;
    else
      v_child:=public.culinary_version_cost(v_version.id,v_version.portion_count,now(),v_currency);
      if (v_child->>'allowed')::boolean then v_cost:=(v_child->>'total_cost')::numeric*v_quantity/v_version.yield_quantity;end if;
    end if;
    if v_cost is null then v_known:=false;else v_total:=v_total+v_cost;end if;
    v_lines:=v_lines||jsonb_build_array(jsonb_build_object('product_id',v_product.id,'cost',v_cost,'message',case when v_cost is null then 'Falta costo vigente de '||v_product.name end));
  end loop;
  v_known:=v_known and jsonb_array_length(p_components)>0;
  return jsonb_build_object('can_view',true,'allowed',v_known,'total_cost',case when v_known then round(v_total,6) end,'cost_per_portion',case when v_known then round(v_total/p_portions,6) end,'currency_code',v_currency,'lines',v_lines);
end$$;

create function public.save_restaurant_ingredient_studio(p_company_id uuid,p_payload jsonb,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_saved jsonb;v_replayed jsonb;v_id uuid:=nullif(p_payload->>'id','')::uuid;v_context jsonb;v_result jsonb;v_reason text;v_cost numeric;
begin
  perform public.assert_restaurant_studio_access(p_company_id,'manage_products');
  if p_client_request_id is null then raise exception 'Falta la referencia de la operación.';end if;
  perform pg_advisory_xact_lock(hashtextextended('restaurant-studio:'||p_company_id::text||':'||p_client_request_id::text,0));
  select metadata into v_replayed from public.audit_log where company_id=p_company_id and action='restaurant.ingredient_studio_saved' and metadata->>'request_id'=p_client_request_id::text;
  if found then
    if v_replayed->>'fingerprint'<>md5(p_payload::text) then raise exception 'La operación cambió. Actualiza antes de reintentar.';end if;
    return v_replayed->'result';
  end if;
  if v_id is not null and not exists(select 1 from public.product_culinary_roles where company_id=p_company_id and product_id=v_id and role='ingredient') then raise exception 'El registro no es un insumo de este restaurante.';end if;
  if v_id is not null and not exists(select 1 from public.products where id=v_id and company_id=p_company_id and updated_at=nullif(p_payload->>'updated_at','')::timestamptz) then raise exception 'El insumo cambió en otra sesión. Ciérralo y vuelve a abrirlo antes de guardar.';end if;
  v_reason:=case when v_id is null then 'Alta de insumo desde Restaurante' else 'Actualización de insumo desde Restaurante' end;
  v_saved:=public.save_restaurant_catalog_item(p_company_id,v_id,coalesce(p_payload->>'internal_sku',''),p_payload->>'name',nullif(p_payload->>'barcode',''),p_payload->>'unit',nullif(p_payload->>'category',''),'ingredient',coalesce((select is_sellable from public.products where id=v_id and company_id=p_company_id),false),coalesce((p_payload->>'is_active')::boolean,true),(select tax_category_id from public.products where id=v_id and company_id=p_company_id),p_payload->>'purchase_unit',(p_payload->>'purchase_factor')::numeric,coalesce((p_payload->>'lot_controlled')::boolean,false),v_reason,nullif(p_payload->>'updated_at','')::timestamptz,gen_random_uuid());
  v_id:=(v_saved->>'id')::uuid;
  if nullif(p_payload->>'package_cost','') is not null then
    v_cost:=(p_payload->>'package_cost')::numeric/(p_payload->>'purchase_factor')::numeric;
    if not(v_cost>0 and v_cost<1000000000) then raise exception 'Escribe un costo mayor que cero.';end if;
    v_context:=public.get_product_cost_admin_context(p_company_id,v_id);
    perform public.set_product_current_cost(p_company_id,v_id,v_cost,v_reason,(v_context#>>'{current_cost,id}')::uuid);
  end if;
  v_result:=jsonb_build_object('id',v_id,'name',v_saved->>'name','internal_sku',v_saved->>'internal_sku','unit',v_saved->>'unit','catalog_role','ingredient','recipe_kind',null);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'restaurant.ingredient_studio_saved','product',v_id,jsonb_build_object('request_id',p_client_request_id,'fingerprint',md5(p_payload::text),'result',v_result));
  return v_result;
end$$;

create function public.save_restaurant_studio(p_company_id uuid,p_payload jsonb,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare
  v_id uuid:=nullif(p_payload->>'id','')::uuid;v_kind text:=p_payload->>'kind';v_saved jsonb;v_version jsonb;v_replayed jsonb;v_result jsonb;
  v_existing_version public.culinary_recipe_versions%rowtype;v_existing_components jsonb;v_recipe_changed boolean;
  v_old public.products%rowtype;v_revision text;v_components jsonb;v_portions numeric:=(p_payload->>'portions')::numeric;v_finish boolean:=coalesce((p_payload->>'finish')::boolean,false);
  v_available boolean;v_reason text;v_list uuid;v_price numeric;v_rate numeric;v_currency text;v_ids uuid[];v_locations uuid[];v_assortment uuid;v_new_assortment uuid;v_location uuid;
  v_bundle uuid;v_group jsonb;v_group_id uuid;v_option jsonb;v_option_id uuid;v_order integer;v_group_ids uuid[]:='{}';v_options uuid[];
begin
  perform public.assert_restaurant_studio_access(p_company_id,'manage_products');
  perform public.assert_restaurant_studio_access(p_company_id,'manage_recipes');
  if p_client_request_id is null then raise exception 'Falta la referencia de la operación.';end if;
  if v_kind is null or v_kind not in ('dish','preparation') then raise exception 'Elige un platillo o una base reutilizable.';end if;
  if nullif(trim(p_payload->>'name'),'') is null then raise exception 'Escribe el nombre.';end if;
  perform pg_advisory_xact_lock(hashtextextended('restaurant-studio:'||p_company_id::text||':'||p_client_request_id::text,0));
  select metadata into v_replayed from public.audit_log where company_id=p_company_id and action='restaurant.studio_saved' and metadata->>'request_id'=p_client_request_id::text;
  if found then
    if v_replayed->>'fingerprint'<>md5(p_payload::text) then raise exception 'La operación cambió. Actualiza antes de reintentar.';end if;
    return v_replayed->'result';
  end if;
  if v_id is not null then
    select p.* into v_old from public.products p join public.product_culinary_roles r on r.product_id=p.id and r.company_id=p.company_id and r.role=v_kind where p.company_id=p_company_id and p.id=v_id for update of p;
    if not found then raise exception 'No se encontró el registro de Restaurante.';end if;
    select coalesce(string_agg(v.id::text||':'||v.updated_at::text||':'||v.status,',' order by v.id),'') into v_revision from public.culinary_recipes r join public.culinary_recipe_versions v on v.recipe_id=r.id and v.status in ('active','draft') where r.company_id=p_company_id and r.product_id=v_id;
    if p_payload->>'recipe_revision' is distinct from v_revision then raise exception 'La receta cambió en otra sesión. Cierra y vuelve a abrir el platillo antes de guardar.';end if;
    if nullif(p_payload->>'updated_at','')::timestamptz is distinct from v_old.updated_at then raise exception 'El platillo cambió en otra sesión. Cierra y vuelve a abrirlo antes de guardar.';end if;
  end if;
  if v_portions is null or not(v_portions>0 and v_portions<=100000) or v_portions<>trunc(v_portions) then raise exception 'Indica un número entero de porciones mayor que cero.';end if;
  if coalesce((p_payload->>'waste_percent')::numeric,0)<0 or not(coalesce((p_payload->>'waste_percent')::numeric,0)<100) then raise exception 'La merma debe estar entre 0 y menos de 100%%.';end if;
  if jsonb_typeof(p_payload->'components') is distinct from 'array' or jsonb_array_length(p_payload->'components')>100 then raise exception 'Agrega hasta 100 ingredientes a la receta.';end if;
  if v_kind='preparation' and ((p_payload->>'yield_quantity') is null or not((p_payload->>'yield_quantity')::numeric>0 and(p_payload->>'yield_quantity')::numeric<1000000000)) then raise exception 'Indica cuánto produce la tanda.';end if;
  if jsonb_array_length(p_payload->'components')=0 and exists(select 1 from public.culinary_recipes where company_id=p_company_id and product_id=v_id) then raise exception 'Conserva al menos un ingrediente en la receta. Puedes deshabilitar su venta.';end if;
  if v_finish and jsonb_array_length(p_payload->'components')=0 then raise exception 'Agrega al menos un ingrediente.';end if;
  if exists(select 1 from jsonb_array_elements(p_payload->'components') c where c->>'quantity' is null or not((c->>'quantity')::numeric>0 and(c->>'quantity')::numeric<1000000000)) then raise exception 'Revisa las cantidades de los ingredientes.';end if;
  if (select count(*)<>count(distinct c->>'product_id') from jsonb_array_elements(p_payload->'components') c) then raise exception 'Un ingrediente está repetido. Ajusta su cantidad en un solo renglón.';end if;
  v_available:=v_kind='dish' and case when v_finish then coalesce((p_payload->>'available')::boolean,false) else coalesce(v_old.is_sellable,false) end;
  v_reason:=case when v_id is null then 'Alta de ' else 'Actualización de ' end||case when v_kind='dish' then 'platillo' else 'base' end||' desde Restaurante';
  if v_kind='dish' and v_finish and v_available and nullif(p_payload->>'tax_category_id','') is null then raise exception 'Selecciona el impuesto para ofrecer el platillo.';end if;
  v_saved:=public.save_restaurant_catalog_item(p_company_id,v_id,coalesce(v_old.internal_sku,''),p_payload->>'name',v_old.barcode,case when v_kind='dish' then 'piece' else p_payload->>'yield_unit' end,nullif(p_payload->>'category',''),v_kind,v_available,true,nullif(p_payload->>'tax_category_id','')::uuid,null,null,false,v_reason,v_old.updated_at,gen_random_uuid());
  v_id:=(v_saved->>'id')::uuid;
  if jsonb_array_length(p_payload->'components')>0 then
    select jsonb_agg(c||jsonb_build_object('quantity',(c->>'quantity')::numeric/case when v_kind='dish' then v_portions else 1 end,'sort_order',ordinal-1) order by ordinal) into v_components from jsonb_array_elements(p_payload->'components') with ordinality x(c,ordinal);
    select v.* into v_existing_version from public.culinary_recipes r join public.culinary_recipe_versions v on v.recipe_id=r.id and v.status in ('active','draft') where r.company_id=p_company_id and r.product_id=v_id order by (v.status='draft') desc,v.version_number desc limit 1;
    select coalesce(jsonb_agg(jsonb_build_object('product_id',c.component_product_id,'quantity',c.entered_quantity,'unit_code',c.entered_unit_code,'base_unit_code',c.base_unit_code,'sort_order',c.sort_order,'notes',c.notes) order by c.sort_order),'[]') into v_existing_components from public.culinary_recipe_components c where c.recipe_version_id=v_existing_version.id;
    select jsonb_agg(c||jsonb_build_object('notes',nullif(trim(c->>'notes'),'')) order by (c->>'sort_order')::integer) into v_components from jsonb_array_elements(v_components) c;
    v_recipe_changed:=v_existing_version.id is null or v_existing_components<>v_components
      or v_existing_version.yield_quantity<>case when v_kind='dish' then 1 else (p_payload->>'yield_quantity')::numeric end
      or v_existing_version.yield_unit_code<>case when v_kind='dish' then 'piece' else p_payload->>'yield_unit' end
      or v_existing_version.portion_count<>case when v_kind='dish' then 1 else v_portions end
      or v_existing_version.waste_percent<>coalesce((p_payload->>'waste_percent')::numeric,0);
    if v_recipe_changed then
      v_version:=public.save_culinary_recipe_draft(p_company_id,v_id,v_kind,case when v_kind='dish' then 1 else (p_payload->>'yield_quantity')::numeric end,case when v_kind='dish' then 'piece' else p_payload->>'yield_unit' end,case when v_kind='dish' then 1 else v_portions end,coalesce((p_payload->>'waste_percent')::numeric,0),v_components,gen_random_uuid(),null);
    else
      v_version:=jsonb_build_object('version_id',v_existing_version.id);
    end if;
    if v_finish and (v_recipe_changed or v_existing_version.status='draft') then perform public.activate_culinary_recipe_version((v_version->>'version_id')::uuid,'draft');end if;
  end if;
  if v_kind='dish' and nullif(p_payload->>'final_price','') is not null then
    perform public.assert_restaurant_studio_access(p_company_id,'manage_prices');
    v_price:=(p_payload->>'final_price')::numeric;
    if not(v_price>0 and v_price<1000000000) then raise exception 'Escribe un precio mayor que cero.';end if;
    select rate into v_rate from public.tax_rates where tax_category_id=(v_saved->>'tax_category_id')::uuid and valid_from<=now() and(valid_to is null or valid_to>now()) order by valid_from desc limit 1;
    if v_rate is null then raise exception 'Selecciona un impuesto con tasa vigente para guardar el precio.';end if;
    select l.id into v_list from public.price_lists l join public.companies c on c.id=l.company_id where l.company_id=p_company_id and l.is_active and l.status='active' and(nullif(p_payload->>'price_list_id','') is null or l.id=(p_payload->>'price_list_id')::uuid) order by(l.id=c.default_price_list_id) desc,l.is_default desc,l.name limit 1;
    if v_list is null and nullif(p_payload->>'price_list_id','') is not null then raise exception 'La lista de precios ya no está activa.';end if;
    if v_list is null then
      select coalesce(base_currency_code,'MXN') into v_currency from public.companies where id=p_company_id;
      v_list:=(public.save_price_list(p_company_id,null,'GENERAL','Precio general',v_currency,true,true,v_reason,null,gen_random_uuid())->>'id')::uuid;
    end if;
    perform public.save_product_price(p_company_id,v_list,v_id,round(v_price/(1+v_rate),6),null,v_reason,gen_random_uuid());
  elsif v_kind='dish' and v_finish and v_available and not exists(select 1 from public.product_prices where product_id=v_id and amount>0 and valid_from<=now() and(valid_to is null or valid_to>now())) then
    raise exception 'Escribe el precio del platillo antes de ofrecerlo.';
  end if;
  -- La intención de venta no borra pertenencias cuando está apagada o faltan existencias.
  if v_kind='dish' and v_finish and v_available and p_payload ? 'assortment_ids' then
    perform public.assert_restaurant_studio_access(p_company_id,'manage_assortments');
    select coalesce(array_agg(value::uuid),'{}') into v_ids from jsonb_array_elements_text(p_payload->'assortment_ids');
    if exists(select 1 from unnest(v_ids) requested(id) left join public.sales_assortments s on s.id=requested.id and s.company_id=p_company_id and s.status='active' and(s.valid_from is null or s.valid_from<=now()) and(s.valid_to is null or s.valid_to>now()) where s.id is null) then raise exception 'Una selección de sucursales ya no está activa.';end if;
    select coalesce(array_agg(value::uuid),'{}') into v_locations from jsonb_array_elements_text(coalesce(p_payload->'location_ids','[]'));
    if cardinality(v_ids)=0 and cardinality(v_locations)>0 then
      if exists(select 1 from unnest(v_locations) requested(id) left join public.locations l on l.id=requested.id and l.company_id=p_company_id and l.is_active and l.location_type='sucursal' where l.id is null) then raise exception 'Selecciona sucursales activas de este restaurante.';end if;
      -- Reutiliza el catálogo exacto de estas sucursales si existe; serializa altas simultáneas.
      perform pg_advisory_xact_lock(hashtextextended('restaurant-assortments:'||p_company_id::text,0));
      select s.id into v_assortment from public.sales_assortments s where s.company_id=p_company_id and s.status='active' and(s.valid_from is null or s.valid_from<=now()) and(s.valid_to is null or s.valid_to>now()) and
        (select array_agg(distinct a.location_id order by a.location_id) from public.location_sales_assortments a where a.assortment_id=s.id and a.valid_from<=now() and(a.valid_to is null or a.valid_to>now()))=(select array_agg(distinct x order by x) from unnest(v_locations) x) limit 1;
      if v_assortment is null then
        insert into public.sales_assortments(company_id,code,name,status,valid_from,created_by) values(p_company_id,public.next_company_internal_code(p_company_id,'SURTIDO','public.sales_assortments'::regclass,'code'),'Menú · '||(select string_agg(name,', ' order by name) from public.locations where id=any(v_locations)),'draft',now(),auth.uid()) returning id into v_assortment;
        foreach v_location in array v_locations loop insert into public.location_sales_assortments(location_id,assortment_id,valid_from,created_by) values(v_location,v_assortment,now(),auth.uid());end loop;
        v_new_assortment:=v_assortment;
        insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'restaurant.menu_assortment_created','sales_assortment',v_assortment,jsonb_build_object('location_ids',v_locations,'reason',v_reason));
      end if;
      v_ids:=array[v_assortment];
    end if;
    if cardinality(v_ids)=0 then raise exception 'Elige al menos una sucursal para ofrecer el platillo.';end if;
    -- Conserva pertenencias históricas/no vigentes que no se editan en este formulario.
    select array_agg(distinct id) into v_ids from (select unnest(v_ids) id union select i.assortment_id from public.sales_assortment_items i join public.sales_assortments s on s.id=i.assortment_id where i.product_id=v_id and s.company_id=p_company_id and(s.status<>'active' or s.valid_from>now() or s.valid_to<=now())) q;
    perform public.set_product_sales_assortments(p_company_id,v_id,v_ids,v_reason);
    if v_new_assortment is not null then update public.sales_assortments set status='active',updated_at=now() where id=v_new_assortment;end if;
  end if;
  if v_kind='dish' and v_finish and v_available and not exists(select 1 from public.sales_assortment_items i join public.sales_assortments s on s.id=i.assortment_id and s.company_id=p_company_id and s.status='active' join public.location_sales_assortments a on a.assortment_id=s.id and a.valid_from<=now() and(a.valid_to is null or a.valid_to>now()) join public.locations l on l.id=a.location_id and l.company_id=p_company_id and l.is_active where i.product_id=v_id) then raise exception 'Selecciona al menos una sucursal para ofrecer el platillo.';end if;
  insert into public.restaurant_menu_presentations(product_id,company_id,description,image_data,batch_portions) values(v_id,p_company_id,coalesce(p_payload->>'description',''),nullif(p_payload->>'image_data',''),v_portions)
    on conflict(product_id) do update set description=excluded.description,image_data=excluded.image_data,batch_portions=excluded.batch_portions,revision=restaurant_menu_presentations.revision+1,updated_at=now();
  if v_kind='dish' and jsonb_typeof(p_payload->'bundle')='object' and (coalesce((p_payload#>>'{bundle,is_active}')::boolean,false) or exists(select 1 from public.restaurant_menu_bundles where company_id=p_company_id and product_id=v_id)) then
    perform public.assert_restaurant_studio_access(p_company_id,'manage_prices');
    if jsonb_array_length(coalesce(p_payload#>'{bundle,groups}','[]'))>10 or jsonb_array_length(coalesce(p_payload#>'{bundle,extras}','[]'))>50 then raise exception 'Reduce las opciones de comida completa.';end if;
    insert into public.restaurant_menu_bundles(company_id,product_id,is_active,combo_price_amount) values(p_company_id,v_id,coalesce((p_payload#>>'{bundle,is_active}')::boolean,false),nullif(p_payload#>>'{bundle,combo_price_amount}','')::numeric)
      on conflict(product_id) do update set is_active=excluded.is_active,combo_price_amount=excluded.combo_price_amount,updated_by=auth.uid(),updated_at=now() returning id into v_bundle;
    if coalesce((p_payload#>>'{bundle,is_active}')::boolean,false) then
    if nullif(p_payload#>>'{bundle,combo_price_amount}','') is null or not((p_payload#>>'{bundle,combo_price_amount}')::numeric>0 and(p_payload#>>'{bundle,combo_price_amount}')::numeric<1000000000) then raise exception 'Escribe el precio de la comida completa.';end if;
    if jsonb_array_length(coalesce(p_payload#>'{bundle,groups}','[]'))=0 then raise exception 'Agrega las opciones incluidas en la comida completa.';end if;
    if (select count(*)<>count(distinct lower(trim(x->>'name'))) from jsonb_array_elements(p_payload#>'{bundle,groups}') x) then raise exception 'Usa un nombre distinto para cada grupo de comida completa.';end if;
    v_order:=0;
    for v_group in select value from jsonb_array_elements(coalesce(p_payload#>'{bundle,groups}','[]')) loop
      if jsonb_array_length(v_group->'options')<coalesce((v_group->>'minimum_selections')::integer,1) then raise exception 'Agrega las opciones de cada grupo de comida completa.';end if;
      insert into public.restaurant_menu_bundle_groups(company_id,bundle_id,name,minimum_selections,maximum_selections,sort_order) values(p_company_id,v_bundle,trim(v_group->>'name'),coalesce((v_group->>'minimum_selections')::integer,1),coalesce((v_group->>'maximum_selections')::integer,1),v_order)
        on conflict(bundle_id,name) do update set minimum_selections=excluded.minimum_selections,maximum_selections=excluded.maximum_selections,sort_order=excluded.sort_order returning id into v_group_id;
      v_group_ids:=array_append(v_group_ids,v_group_id);v_order:=v_order+1;v_options:='{}';
      for v_option in select value from jsonb_array_elements(v_group->'options') loop
        v_option_id:=(v_option->>'id')::uuid;
        if v_option_id=v_id or not exists(select 1 from public.products p join public.product_culinary_roles r on r.product_id=p.id and r.company_id=p.company_id and r.role='dish' where p.id=v_option_id and p.company_id=p_company_id and p.is_active) then raise exception 'Elige platillos activos de este restaurante para las opciones.';end if;
        v_options:=array_append(v_options,v_option_id);
        insert into public.restaurant_menu_bundle_options(company_id,group_id,product_id,is_active) values(p_company_id,v_group_id,v_option_id,true) on conflict(group_id,product_id) do update set is_active=true;
      end loop;
      update public.restaurant_menu_bundle_options set is_active=false where group_id=v_group_id and not(product_id=any(v_options));
    end loop;
    -- Evita borrar grupos referenciados por carritos en curso; PostgreSQL conserva su integridad.
    if exists(select 1 from public.sale_cart_bundle_selections x join public.restaurant_menu_bundle_groups g on g.id=x.group_id where g.bundle_id=v_bundle and not(g.id=any(v_group_ids))) then raise exception 'Hay una venta usando estas opciones. Termina o cancela esa venta antes de quitar o renombrar el grupo.';end if;
    delete from public.restaurant_menu_bundle_groups where bundle_id=v_bundle and not(id=any(v_group_ids));
    v_options:='{}';
    for v_option in select value from jsonb_array_elements(coalesce(p_payload#>'{bundle,extras}','[]')) loop
      v_option_id:=(v_option->>'id')::uuid;
      if v_option_id=v_id or not exists(select 1 from public.products p join public.product_culinary_roles r on r.product_id=p.id and r.company_id=p.company_id and r.role='dish' where p.id=v_option_id and p.company_id=p_company_id and p.is_active and p.is_sellable) then raise exception 'Elige platillos vendibles de este restaurante para los extras.';end if;
      v_options:=array_append(v_options,v_option_id);
      insert into public.restaurant_menu_bundle_extras(company_id,bundle_id,product_id,is_active) values(p_company_id,v_bundle,v_option_id,true) on conflict(bundle_id,product_id) do update set is_active=true;
    end loop;
    update public.restaurant_menu_bundle_extras set is_active=false where bundle_id=v_bundle and not(product_id=any(v_options));
    end if;
  end if;
  if not coalesce((p_payload->>'is_active')::boolean,true) then
    v_saved:=public.save_restaurant_catalog_item(p_company_id,v_id,v_saved->>'internal_sku',p_payload->>'name',v_old.barcode,case when v_kind='dish' then 'piece' else p_payload->>'yield_unit' end,nullif(p_payload->>'category',''),v_kind,v_available,false,nullif(p_payload->>'tax_category_id','')::uuid,null,null,false,v_reason,(select updated_at from public.products where id=v_id),gen_random_uuid());
  end if;
  v_result:=jsonb_build_object('product_id',v_id,'name',v_saved->>'name','available',v_available and coalesce((p_payload->>'is_active')::boolean,true),'recipe_active',v_finish,'is_active',coalesce((p_payload->>'is_active')::boolean,true),'version_id',v_version->>'version_id');
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'restaurant.studio_saved','product',v_id,jsonb_build_object('request_id',p_client_request_id,'fingerprint',md5(p_payload::text),'result',v_result,'reason',v_reason));
  return v_result;
end$$;

revoke all on function public.get_restaurant_studio_context(uuid,uuid),public.preview_restaurant_recipe_cost(uuid,jsonb,numeric,numeric,text),public.save_restaurant_ingredient_studio(uuid,jsonb,uuid),public.save_restaurant_studio(uuid,jsonb,uuid) from public,anon;
grant execute on function public.get_restaurant_studio_context(uuid,uuid),public.preview_restaurant_recipe_cost(uuid,jsonb,numeric,numeric,text),public.save_restaurant_ingredient_studio(uuid,jsonb,uuid),public.save_restaurant_studio(uuid,jsonb,uuid) to authenticated;
notify pgrst,'reload schema';
commit;
