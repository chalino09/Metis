-- Restaurante · catálogo culinario coherente de punta a punta.
-- Volumen esperado: altas manuales puntuales y lotes de hasta 500 registros.
-- El lote es transaccional, idempotente y auditado; no crea un catálogo paralelo.

begin;

-- Sólo los platillos pertenecen a la venta. Conserva surtidos e historial.
with corrected as (
  update public.products product
  set is_sellable=false,tax_category_id=null,updated_at=now()
  from public.product_culinary_roles role_data
  join public.companies company on company.id=role_data.company_id and company.product_experience_code='restaurant'
  where role_data.product_id=product.id
    and role_data.role in ('ingredient','preparation')
    and (product.is_sellable or product.tax_category_id is not null)
  returning product.company_id,product.id,role_data.role
)
insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
select company_id,null,'restaurant.non_dish_commercial_fields_cleared','product',id,jsonb_build_object('role',role,'source','catalog_end_to_end_migration')
from corrected;

create or replace function public.search_restaurant_catalog(
  p_company_id uuid,
  p_role text default 'dish',
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 50,
  p_is_sellable boolean default null
)
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);
  v_query text:=lower(trim(coalesce(p_query,'')));
  v_total bigint;
  v_items jsonb;
  v_can_view_prices boolean;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_products') then raise exception 'No autorizado para consultar el catálogo.'; end if;
  if p_role not in ('dish','ingredient','preparation') then raise exception 'Función culinaria no reconocida.'; end if;
  if not exists(select 1 from public.companies where id=p_company_id and product_experience_code='restaurant') then raise exception 'Este catálogo sólo está disponible en Restaurante.'; end if;
  v_can_view_prices:=public.has_company_permission(p_company_id,'view_prices');

  with scoped as materialized (
    select product.*,
      role_data.role catalog_role,
      price.amount price_amount,price.currency_code,
      purchase_unit.code purchase_unit_code,purchase.base_units_per_purchase_unit,
      recipe.recipe_kind,
      case when active_version.id is not null then 'active' when draft_version.id is not null then 'draft' else 'missing' end recipe_status,
      active_version.version_number recipe_version_number,
      active_version.yield_quantity recipe_yield_quantity,
      active_version.yield_unit_code recipe_yield_unit_code,
      (select count(distinct parent_recipe.id)::integer
       from public.culinary_recipe_components component
       join public.culinary_recipe_versions parent_version on parent_version.id=component.recipe_version_id and parent_version.status='active'
       join public.culinary_recipes parent_recipe on parent_recipe.id=parent_version.recipe_id and parent_recipe.company_id=p_company_id
       where component.component_product_id=product.id) usage_count,
      case when active_version.id is null then 0 else (
        select count(*)::integer
        from public.culinary_recipe_components component
        left join public.product_culinary_roles component_role on component_role.company_id=p_company_id and component_role.product_id=component.component_product_id
        left join public.culinary_recipes component_recipe on component_recipe.company_id=p_company_id and component_recipe.product_id=component.component_product_id and component_recipe.recipe_kind='preparation'
        left join public.culinary_recipe_versions component_active on component_active.recipe_id=component_recipe.id and component_active.status='active'
        where component.recipe_version_id=active_version.id
          and (component_role.role not in ('ingredient','preparation') or component_role.role is null or (component_role.role='preparation' and component_active.id is null))
      ) end invalid_component_count,
      case when v_query='' then 0 when lower(coalesce(product.internal_sku,''))=v_query then 1 when lower(coalesce(product.barcode,''))=v_query then 2 else 3 end rank
    from public.products product
    join public.product_culinary_roles role_data on role_data.company_id=product.company_id and role_data.product_id=product.id and role_data.role=p_role
    left join public.product_purchase_units purchase on purchase.product_id=product.id
    left join public.units_of_measure purchase_unit on purchase_unit.id=purchase.purchase_unit_id
    left join public.culinary_recipes recipe on recipe.company_id=product.company_id and recipe.product_id=product.id
    left join lateral (select version.* from public.culinary_recipe_versions version where version.recipe_id=recipe.id and version.status='active' order by version.version_number desc limit 1) active_version on true
    left join lateral (select version.* from public.culinary_recipe_versions version where version.recipe_id=recipe.id and version.status='draft' order by version.version_number desc limit 1) draft_version on true
    left join lateral (
      select product_price.amount,product_price.currency_code from public.product_prices product_price
      where product_price.product_id=product.id and product_price.valid_from<=now() and (product_price.valid_to is null or product_price.valid_to>now())
      order by product_price.valid_from desc,product_price.id desc limit 1
    ) price on true
    where product.company_id=p_company_id
      and (p_is_sellable is null or (p_role='dish' and product.is_sellable=p_is_sellable) or (p_role<>'dish' and product.is_active=p_is_sellable))
      and (v_query='' or lower(product.name) like '%'||v_query||'%' or lower(coalesce(product.internal_sku,'')) like '%'||v_query||'%' or lower(coalesce(product.barcode,''))=v_query or exists(select 1 from public.product_aliases alias where alias.product_id=product.id and alias.normalized_value like '%'||v_query||'%'))
  ), paged as materialized (
    select * from scoped order by rank,name,id limit v_size offset (v_page-1)*v_size
  )
  select (select count(*) from scoped),coalesce((select jsonb_agg(jsonb_build_object(
    'id',item.id,'alpha_sku',item.alpha_sku,'internal_sku',item.internal_sku,'barcode',item.barcode,'name',item.name,'unit',item.unit,'product_group',item.product_group,
    'is_active',item.is_active,'is_inventory_tracked',item.is_inventory_tracked,'is_sellable',case when p_role='dish' then item.is_sellable else false end,
    'price',case when p_role='dish' and v_can_view_prices then item.price_amount else null end,'currency_code',case when p_role='dish' and v_can_view_prices then item.currency_code else null end,
    'catalog_role',p_role,'purchase_unit_code',item.purchase_unit_code,'base_units_per_purchase_unit',item.base_units_per_purchase_unit,
    'recipe_status',item.recipe_status,'recipe_version_number',item.recipe_version_number,'recipe_yield_quantity',item.recipe_yield_quantity,'recipe_yield_unit_code',item.recipe_yield_unit_code,
    'usage_count',item.usage_count,'invalid_component_count',item.invalid_component_count,
    'pos_ready',p_role='dish' and item.is_active and item.is_sellable and item.tax_category_id is not null and coalesce(item.price_amount,0)>0 and item.recipe_status='active' and item.invalid_component_count=0,
    'blockers',case when p_role<>'dish' then '[]'::jsonb else to_jsonb(array_remove(array[
      case when not item.is_active then 'inactive' end,case when not item.is_sellable then 'not_sellable' end,
      case when item.tax_category_id is null then 'missing_tax_category' end,case when coalesce(item.price_amount,0)<=0 then 'missing_or_zero_price' end,
      case when item.recipe_status<>'active' then 'missing_active_recipe' end,case when item.invalid_component_count>0 then 'invalid_recipe_components' end
    ]::text[],null)) end
  ) order by item.rank,item.name,item.id) from paged item),'[]'::jsonb) into v_total,v_items;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size,'catalog_role',p_role);
end $$;

create or replace function public.search_restaurant_recipe_components(
  p_company_id uuid,p_query text default null,p_page integer default 1,p_page_size integer default 30
)
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,30),1),50);v_query text:=lower(trim(coalesce(p_query,'')));v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_recipes') then raise exception 'No autorizado para consultar componentes.'; end if;
  with scope as materialized (
    select product.id,product.internal_sku,product.name,
      case when role_data.role='preparation' then active_version.yield_unit_code else lower(product.unit) end unit,
      product.is_inventory_tracked,case when role_data.role='preparation' then 'preparation' end recipe_kind,role_data.role catalog_role,
      (select count(*)::integer from public.culinary_recipe_components component where component.component_product_id=product.id) usage_count
    from public.products product
    join public.product_culinary_roles role_data on role_data.company_id=product.company_id and role_data.product_id=product.id and role_data.role in ('ingredient','preparation')
    left join public.culinary_recipes recipe on recipe.company_id=product.company_id and recipe.product_id=product.id and recipe.recipe_kind='preparation'
    left join public.culinary_recipe_versions active_version on active_version.recipe_id=recipe.id and active_version.status='active'
    where product.company_id=p_company_id and product.is_active
      and (role_data.role='ingredient' or active_version.id is not null)
      and (v_query='' or lower(product.name) like '%'||v_query||'%' or lower(product.internal_sku) like '%'||v_query||'%')
  ),paged as(select * from scope order by usage_count desc,name,id limit v_size offset(v_page-1)*v_size)
  select (select count(*) from scope),coalesce((select jsonb_agg(to_jsonb(item) order by item.usage_count desc,item.name,item.id) from paged item),'[]'::jsonb) into v_total,v_items;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size);
end $$;

create or replace function public.save_culinary_recipe_draft(
  p_company_id uuid,p_product_id uuid,p_recipe_kind text,p_yield_quantity numeric,p_yield_unit_code text,p_portion_count numeric,p_waste_percent numeric,p_components jsonb,p_client_request_id uuid,p_duplicate_from_version_id uuid default null
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_existing jsonb;v_recipe public.culinary_recipes%rowtype;v_version public.culinary_recipe_versions%rowtype;v_component record;v_count integer:=0;v_result jsonb;v_product_role text;v_component_role text;v_component_base_unit text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_recipes') then raise exception 'No autorizado para guardar recetas.'; end if;
  if p_client_request_id is null then raise exception 'La llave de la operación es obligatoria.'; end if;
  select result into v_existing from public.culinary_recipe_requests where company_id=p_company_id and client_request_id=p_client_request_id;if found then return v_existing||jsonb_build_object('idempotent',true);end if;
  if p_recipe_kind not in ('dish','preparation') or p_yield_quantity<=0 or p_portion_count<=0 or p_waste_percent<0 or p_waste_percent>=100 then raise exception 'Completa rendimiento y merma con valores válidos.'; end if;
  if p_portion_count<>1 then raise exception 'La receta debe capturarse para una porción o una tanda.'; end if;
  if p_recipe_kind='dish' and (p_yield_quantity<>1 or lower(trim(p_yield_unit_code))<>'piece') then raise exception 'La receta del platillo debe representar exactamente una porción.'; end if;
  if not exists(select 1 from public.culinary_units where code=lower(trim(p_yield_unit_code))) then raise exception 'Selecciona una unidad válida para el rendimiento.'; end if;
  select role into v_product_role from public.product_culinary_roles where company_id=p_company_id and product_id=p_product_id;
  if v_product_role is null or (p_recipe_kind='dish' and v_product_role<>'dish') or (p_recipe_kind='preparation' and v_product_role<>'preparation') then raise exception 'La receta no corresponde a la función culinaria del registro.'; end if;
  if not exists(select 1 from public.products where id=p_product_id and company_id=p_company_id and is_active) then raise exception 'El registro culinario no está activo.'; end if;
  if jsonb_typeof(coalesce(p_components,'[]'))<>'array' or jsonb_array_length(coalesce(p_components,'[]'))=0 then raise exception 'Agrega al menos un insumo o una base.'; end if;
  if p_recipe_kind='preparation' then update public.products set unit=lower(trim(p_yield_unit_code)),updated_at=now() where id=p_product_id; end if;

  insert into public.culinary_recipes(company_id,product_id,recipe_kind) values(p_company_id,p_product_id,p_recipe_kind)
  on conflict(company_id,product_id) do update set recipe_kind=excluded.recipe_kind returning * into v_recipe;
  select * into v_version from public.culinary_recipe_versions where recipe_id=v_recipe.id and status='draft' order by version_number desc limit 1 for update;
  if not found then
    insert into public.culinary_recipe_versions(recipe_id,version_number,yield_quantity,yield_unit_code,portion_count,waste_percent,duplicated_from_id)
    values(v_recipe.id,coalesce((select max(version_number)+1 from public.culinary_recipe_versions where recipe_id=v_recipe.id),1),p_yield_quantity,lower(p_yield_unit_code),p_portion_count,p_waste_percent,p_duplicate_from_version_id) returning * into v_version;
  else
    update public.culinary_recipe_versions set yield_quantity=p_yield_quantity,yield_unit_code=lower(p_yield_unit_code),portion_count=p_portion_count,waste_percent=p_waste_percent,updated_at=now() where id=v_version.id returning * into v_version;
    delete from public.culinary_recipe_components where recipe_version_id=v_version.id;
  end if;
  for v_component in select * from jsonb_to_recordset(p_components) as component(product_id uuid,quantity numeric,unit_code text,base_unit_code text,notes text,sort_order integer) loop
    select role into v_component_role from public.product_culinary_roles where company_id=p_company_id and product_id=v_component.product_id;
    if v_component_role='ingredient' then
      select lower(unit) into v_component_base_unit from public.products where company_id=p_company_id and id=v_component.product_id and is_active;
    elsif v_component_role='preparation' then
      select version.yield_unit_code into v_component_base_unit
      from public.culinary_recipes recipe join public.culinary_recipe_versions version on version.recipe_id=recipe.id and version.status='active'
      where recipe.company_id=p_company_id and recipe.product_id=v_component.product_id and recipe.recipe_kind='preparation';
    else
      raise exception 'Una receta sólo puede contener insumos o bases reutilizables.';
    end if;
    if v_component_base_unit is null then raise exception 'Activa la receta de cada base antes de reutilizarla.'; end if;
    if lower(trim(v_component.base_unit_code))<>lower(trim(v_component_base_unit)) then raise exception 'La unidad base de un componente cambió; vuelve a seleccionarlo.'; end if;
    insert into public.culinary_recipe_components(recipe_version_id,component_product_id,entered_quantity,entered_unit_code,normalized_quantity,base_unit_code,notes,sort_order)
    values(v_version.id,v_component.product_id,v_component.quantity,lower(v_component.unit_code),1,lower(v_component_base_unit),nullif(trim(v_component.notes),''),coalesce(v_component.sort_order,v_count));
    v_count:=v_count+1;
  end loop;
  perform public.assert_culinary_recipe_acyclic(v_version.id);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'culinary_recipe.draft_saved','culinary_recipe_version',v_version.id,jsonb_build_object('product_id',p_product_id,'component_count',v_count,'yield_quantity',p_yield_quantity,'yield_unit_code',lower(trim(p_yield_unit_code)),'client_request_id',p_client_request_id));
  v_result:=jsonb_build_object('recipe_id',v_recipe.id,'version_id',v_version.id,'version_number',v_version.version_number,'status','draft','component_count',v_count,'idempotent',false);
  insert into public.culinary_recipe_requests(company_id,client_request_id,operation,result) values(p_company_id,p_client_request_id,case when p_duplicate_from_version_id is null then 'save_draft' else 'duplicate' end,v_result);
  return v_result;
end $$;

create or replace function public.save_restaurant_catalog_item(
  p_company_id uuid,p_product_id uuid,p_internal_sku text,p_name text,p_barcode text,p_unit text,p_product_group text,p_role text,
  p_is_sellable boolean,p_is_active boolean,p_tax_category_id uuid,p_purchase_unit_code text,p_base_units_per_purchase_unit numeric,
  p_lot_controlled boolean,p_reason text,p_expected_updated_at timestamptz,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_product jsonb;v_product_id uuid;v_existing jsonb;v_purchase_error text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_products') then raise exception 'No autorizado para administrar el catálogo de Restaurante.'; end if;
  if not exists(select 1 from public.companies where id=p_company_id and product_experience_code='restaurant') then raise exception 'Esta operación sólo está disponible en Restaurante.'; end if;
  if p_role not in ('dish','ingredient','preparation') then raise exception 'Función culinaria no válida.'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null or p_client_request_id is null then raise exception 'Captura el motivo de auditoría y vuelve a intentar.'; end if;
  select to_jsonb(product) into v_existing
  from public.audit_log audit join public.products product on product.id=audit.entity_id and product.company_id=audit.company_id
  where audit.company_id=p_company_id and audit.action='restaurant.catalog_item_saved' and audit.metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_existing is not null then return v_existing||jsonb_build_object('idempotent',true); end if;
  if p_role='ingredient' then
    v_purchase_error:=public.restaurant_purchase_configuration_error(p_purchase_unit_code,p_unit,p_base_units_per_purchase_unit);
    if v_purchase_error is not null then raise exception '%',v_purchase_error; end if;
  end if;
  v_product:=public.save_product(
    p_company_id,p_product_id,p_internal_sku,p_name,p_barcode,
    case when p_role='dish' then 'piece' else p_unit end,p_product_group,p_role='ingredient',
    p_role='dish' and coalesce(p_is_sellable,false),p_is_active,
    case when p_role='dish' then p_tax_category_id else null end,
    p_reason,p_expected_updated_at,gen_random_uuid()
  );
  v_product_id:=(v_product->>'id')::uuid;
  if p_role='ingredient' then
    perform public.set_product_purchase_unit(p_company_id,v_product_id,p_purchase_unit_code,p_base_units_per_purchase_unit,p_reason,gen_random_uuid());
    if not public.restaurant_purchase_presentation_is_standard(p_purchase_unit_code) then
      update public.product_purchase_units set presentation_content_confirmed_at=now(),presentation_content_confirmed_by=auth.uid() where product_id=v_product_id;
    else
      update public.product_purchase_units set presentation_content_confirmed_at=null,presentation_content_confirmed_by=null where product_id=v_product_id;
    end if;
    perform public.set_product_lot_controlled(p_company_id,v_product_id,coalesce(p_lot_controlled,false),p_reason,gen_random_uuid());
  end if;
  perform public.set_product_culinary_role(p_company_id,v_product_id,p_role,p_reason);
  update public.products set is_sellable=false,tax_category_id=null where id=v_product_id and p_role<>'dish';
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'restaurant.catalog_item_saved','product',v_product_id,jsonb_build_object('request_id',p_client_request_id,'role',p_role,'reason',trim(p_reason)));
  return(select to_jsonb(product)from public.products product where product.id=v_product_id)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.import_restaurant_catalog_batch(
  p_company_id uuid,p_role text,p_rows jsonb,p_reason text,p_client_request_id uuid
)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_row record;v_count integer:=0;v_result jsonb;v_existing jsonb;v_tax_category_id uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_products') then raise exception 'No autorizado para importar el catálogo.'; end if;
  if p_role not in ('dish','ingredient','preparation') then raise exception 'Función culinaria no válida.'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null or p_client_request_id is null then raise exception 'Indica el motivo de la importación.'; end if;
  if jsonb_typeof(coalesce(p_rows,'[]'))<>'array' or jsonb_array_length(coalesce(p_rows,'[]'))=0 or jsonb_array_length(p_rows)>500 then raise exception 'El archivo debe contener entre 1 y 500 registros.'; end if;
  select metadata->'result' into v_existing from public.audit_log where company_id=p_company_id and action='restaurant.catalog_batch_imported' and metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_existing is not null then return v_existing||jsonb_build_object('idempotent',true); end if;

  for v_row in select * from jsonb_to_recordset(p_rows) as item(
    internal_sku text,name text,barcode text,unit text,product_group text,is_active boolean,is_sellable boolean,tax_category_code text,
    purchase_unit_code text,base_units_per_purchase_unit numeric,lot_controlled boolean
  ) loop
    if nullif(trim(coalesce(v_row.name,'')),'') is null then raise exception 'Cada fila debe incluir un nombre.'; end if;
    v_tax_category_id:=null;
    if p_role='dish' and nullif(trim(coalesce(v_row.tax_category_code,'')),'') is not null then
      select id into v_tax_category_id from public.tax_categories where company_id=p_company_id and lower(code)=lower(trim(v_row.tax_category_code)) and is_active limit 1;
      if v_tax_category_id is null then raise exception 'No existe la categoría fiscal %.',v_row.tax_category_code; end if;
    end if;
    perform public.save_restaurant_catalog_item(
      p_company_id,null,coalesce(v_row.internal_sku,''),trim(v_row.name),nullif(trim(coalesce(v_row.barcode,'')),''),
      case when p_role='dish' then 'piece' else lower(trim(coalesce(v_row.unit,''))) end,nullif(trim(coalesce(v_row.product_group,'')),''),p_role,
      p_role='dish' and coalesce(v_row.is_sellable,false),coalesce(v_row.is_active,true),v_tax_category_id,
      case when p_role='ingredient' then nullif(upper(trim(coalesce(v_row.purchase_unit_code,''))),'') end,
      case when p_role='ingredient' then v_row.base_units_per_purchase_unit end,
      p_role='ingredient' and coalesce(v_row.lot_controlled,false),trim(p_reason),null,gen_random_uuid()
    );
    v_count:=v_count+1;
  end loop;
  v_result:=jsonb_build_object('processed',v_count,'role',p_role,'idempotent',false);
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata) values(p_company_id,auth.uid(),'restaurant.catalog_batch_imported','product_batch',jsonb_build_object('request_id',p_client_request_id,'role',p_role,'reason',trim(p_reason),'result',v_result));
  return v_result;
end $$;

-- Refuerza que ninguna escritura futura vuelva a exponer insumos o bases a venta.
create or replace function public.enforce_restaurant_catalog_sale_scope()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.is_sellable and exists(
    select 1 from public.product_culinary_roles role_data join public.companies company on company.id=role_data.company_id
    where role_data.product_id=new.id and role_data.company_id=new.company_id and company.product_experience_code='restaurant' and role_data.role in ('ingredient','preparation')
  ) then raise exception 'Sólo los platillos pueden habilitarse para venta en Restaurante.'; end if;
  return new;
end $$;
drop trigger if exists products_restaurant_sale_scope on public.products;
create trigger products_restaurant_sale_scope before update of is_sellable on public.products for each row execute function public.enforce_restaurant_catalog_sale_scope();

revoke all on function public.search_restaurant_catalog(uuid,text,text,integer,integer,boolean),public.search_restaurant_recipe_components(uuid,text,integer,integer),public.import_restaurant_catalog_batch(uuid,text,jsonb,text,uuid) from public,anon;
grant execute on function public.search_restaurant_catalog(uuid,text,text,integer,integer,boolean),public.search_restaurant_recipe_components(uuid,text,integer,integer),public.save_culinary_recipe_draft(uuid,uuid,text,numeric,text,numeric,numeric,jsonb,uuid,uuid),public.import_restaurant_catalog_batch(uuid,text,jsonb,text,uuid) to authenticated;

notify pgrst,'reload schema';
commit;
