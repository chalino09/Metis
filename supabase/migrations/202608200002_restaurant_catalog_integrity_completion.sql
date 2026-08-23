-- Restaurante · cierre de integridad de insumos, recetas y archivo seguro.
-- No inventa contenidos de presentaciones: identifica los heredados y exige
-- que una persona confirme el contenido real antes de seguir operando.

begin;

alter table public.product_purchase_units
  add column if not exists presentation_content_confirmed_at timestamptz,
  add column if not exists presentation_content_confirmed_by uuid references auth.users(id) on delete set null;

create or replace function public.restaurant_normalize_unit_code(p_value text)
returns text language plpgsql immutable set search_path=public as $$
declare v_value text:=lower(trim(coalesce(p_value,'')));
begin
  if v_value in ('pza','pieza','piezas','ea','unidad','unidades') then return 'piece'; end if;
  return v_value;
end $$;

create or replace function public.restaurant_unit_conversion_factor(
  p_purchase_unit text,
  p_base_unit text
) returns numeric language plpgsql immutable set search_path=public as $$
declare
  v_purchase text:=public.restaurant_normalize_unit_code(p_purchase_unit);
  v_base text:=public.restaurant_normalize_unit_code(p_base_unit);
begin
  if v_purchase=v_base and v_base in ('g','kg','ml','l','piece') then return 1; end if;
  if v_purchase='kg' and v_base='g' then return 1000; end if;
  if v_purchase='g' and v_base='kg' then return 0.001; end if;
  if v_purchase='l' and v_base='ml' then return 1000; end if;
  if v_purchase='ml' and v_base='l' then return 0.001; end if;
  return null;
end $$;

create or replace function public.restaurant_purchase_presentation_is_standard(p_code text)
returns boolean language sql immutable set search_path=public as $$
  select public.restaurant_normalize_unit_code(p_code) in ('g','kg','ml','l','piece')
$$;

create or replace function public.restaurant_purchase_configuration_error(
  p_purchase_unit text,
  p_base_unit text,
  p_factor numeric
) returns text language plpgsql immutable set search_path=public as $$
declare
  v_code text:=upper(trim(coalesce(p_purchase_unit,'')));
  v_expected numeric:=public.restaurant_unit_conversion_factor(p_purchase_unit,p_base_unit);
begin
  if v_code='' or coalesce(p_factor,0)<=0 then
    return 'Selecciona la presentación de compra y captura su contenido real.';
  end if;
  if not public.restaurant_purchase_presentation_is_standard(p_purchase_unit)
     and v_code !~ '[[:alpha:]]' then
    return 'La presentación de compra debe tener un nombre, por ejemplo BOTELLA, CAJA o BOLSA; no puede ser sólo un número.';
  end if;
  if v_expected is not null and p_factor<>v_expected then
    return format('La conversión correcta es 1 %s = %s %s.',v_code,v_expected,lower(public.restaurant_normalize_unit_code(p_base_unit)));
  end if;
  if public.restaurant_purchase_presentation_is_standard(p_purchase_unit)
     and v_expected is null then
    return 'La unidad de compra no es compatible con la unidad de consumo.';
  end if;
  return null;
end $$;

create or replace function public.get_product_purchase_unit(p_company_id uuid,p_product_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_product public.products%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_products') then raise exception 'No autorizado para consultar la unidad de compra.'; end if;
  select * into v_product from public.products where id=p_product_id and company_id=p_company_id;
  if not found then raise exception 'Producto no encontrado.'; end if;
  return jsonb_build_object(
    'base_unit',(select code from public.units_of_measure where id=v_product.base_unit_id),
    'purchase_unit',(select code from public.units_of_measure where id=coalesce(v_product.purchase_unit_id,v_product.base_unit_id)),
    'base_units_per_purchase_unit',coalesce((select base_units_per_purchase_unit from public.product_purchase_units where product_id=v_product.id),1),
    'presentation_content_confirmed_at',(select presentation_content_confirmed_at from public.product_purchase_units where product_id=v_product.id)
  );
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
  select to_jsonb(product) into v_existing from public.audit_log audit join public.products product on product.id=audit.entity_id and product.company_id=audit.company_id where audit.company_id=p_company_id and audit.action='restaurant.catalog_item_saved' and audit.metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_existing is not null then return v_existing||jsonb_build_object('idempotent',true); end if;
  if p_role='ingredient' then
    v_purchase_error:=public.restaurant_purchase_configuration_error(p_purchase_unit_code,p_unit,p_base_units_per_purchase_unit);
    if v_purchase_error is not null then raise exception '%',v_purchase_error; end if;
  end if;
  v_product:=public.save_product(p_company_id,p_product_id,p_internal_sku,p_name,p_barcode,p_unit,p_product_group,p_role='ingredient',case when p_role='preparation' then false else coalesce(p_is_sellable,false) end,p_is_active,p_tax_category_id,p_reason,p_expected_updated_at,gen_random_uuid());
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
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'restaurant.catalog_item_saved','product',v_product_id,jsonb_build_object('request_id',p_client_request_id,'role',p_role,'reason',trim(p_reason)));
  return(select to_jsonb(product)from public.products product where product.id=v_product_id)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.list_restaurant_catalog_integrity_issues(
  p_company_id uuid,p_page integer default 1,p_page_size integer default 50
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_products') then raise exception 'No autorizado para revisar el catálogo.'; end if;
  if not exists(select 1 from public.companies where id=p_company_id and product_experience_code='restaurant') then raise exception 'Esta revisión sólo está disponible en Restaurante.'; end if;
  with scope as materialized(
    select product.id,product.internal_sku,product.alpha_sku,product.name,product.barcode,product.unit,product.product_group,case when product.is_inventory_tracked then 'tracked' else 'not_required' end inventory_policy,product.is_active,product.is_sellable,product.is_inventory_tracked,
      coalesce(role_data.role,case when product.is_inventory_tracked then 'ingredient' else 'dish' end) catalog_role,
      purchase_unit.code purchase_unit_code,base_unit.code base_unit_code,purchase.base_units_per_purchase_unit,purchase.presentation_content_confirmed_at,
      case when role_data.product_id is null then 'missing_culinary_role'
        when role_data.role='ingredient' and public.restaurant_purchase_configuration_error(purchase_unit.code,base_unit.code,coalesce(purchase.base_units_per_purchase_unit,0)) is not null then 'invalid_purchase_configuration'
        when role_data.role='ingredient' and not public.restaurant_purchase_presentation_is_standard(purchase_unit.code) and purchase.presentation_content_confirmed_at is null then 'presentation_content_unconfirmed'
      end issue_code,
      case when role_data.product_id is null then 'Falta la función culinaria; revisa este registro antes de usarlo.'
        when role_data.role='ingredient' and public.restaurant_purchase_configuration_error(purchase_unit.code,base_unit.code,coalesce(purchase.base_units_per_purchase_unit,0)) is not null then public.restaurant_purchase_configuration_error(purchase_unit.code,base_unit.code,coalesce(purchase.base_units_per_purchase_unit,0))
        when role_data.role='ingredient' and not public.restaurant_purchase_presentation_is_standard(purchase_unit.code) and purchase.presentation_content_confirmed_at is null then format('Confirma el contenido real de %s en %s.',coalesce(purchase_unit.code,'la presentación'),coalesce(base_unit.code,'la unidad de consumo'))
      end message
    from public.products product
    left join public.product_culinary_roles role_data on role_data.product_id=product.id
    left join public.product_purchase_units purchase on purchase.product_id=product.id
    left join public.units_of_measure purchase_unit on purchase_unit.id=purchase.purchase_unit_id
    left join public.units_of_measure base_unit on base_unit.id=product.base_unit_id
    where product.company_id=p_company_id and product.is_active
  ),issues as(select * from scope where issue_code is not null),paged as(select * from issues order by name,id limit v_size offset(v_page-1)*v_size)
  select(select count(*)from issues),coalesce((select jsonb_agg(jsonb_build_object('id',item.id,'internal_sku',item.internal_sku,'alpha_sku',item.alpha_sku,'name',item.name,'barcode',item.barcode,'unit',item.unit,'product_group',item.product_group,'inventory_policy',item.inventory_policy,'is_active',item.is_active,'is_sellable',item.is_sellable,'is_inventory_tracked',item.is_inventory_tracked,'price',null,'currency_code',null,'pos_ready',false,'catalog_role',item.catalog_role,'issue_code',item.issue_code,'message',item.message,'purchase_unit_code',item.purchase_unit_code,'base_unit_code',item.base_unit_code,'base_units_per_purchase_unit',item.base_units_per_purchase_unit)order by item.name,item.id)from paged item),'[]'::jsonb)into v_total,v_items;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size);
end $$;

create or replace function public.get_restaurant_ingredient_archive_context(p_company_id uuid,p_product_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_product public.products%rowtype;v_stock_count integer;v_open_purchase_orders integer;v_active_recipes jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_products') then raise exception 'No autorizado para consultar el archivo de insumos.'; end if;
  select * into v_product from public.products where id=p_product_id and company_id=p_company_id;if not found then raise exception 'Insumo no encontrado.';end if;
  select count(*) into v_stock_count from public.inventory_balances where company_id=p_company_id and product_id=p_product_id and quantity_on_hand<>0;
  select count(distinct purchase_order.id)into v_open_purchase_orders from public.purchase_order_lines line join public.purchase_orders purchase_order on purchase_order.id=line.purchase_order_id where line.company_id=p_company_id and line.product_id=p_product_id and purchase_order.company_id=p_company_id and purchase_order.status in ('draft','pending_approval','approved');
  select coalesce(jsonb_agg(jsonb_build_object('product_id',recipe_product.id,'product_name',recipe_product.name,'recipe_kind',recipe.recipe_kind,'version_number',version.version_number)order by recipe_product.name),'[]'::jsonb)into v_active_recipes from public.culinary_recipe_components component join public.culinary_recipe_versions version on version.id=component.recipe_version_id and version.status='active' join public.culinary_recipes recipe on recipe.id=version.recipe_id and recipe.company_id=p_company_id join public.products recipe_product on recipe_product.id=recipe.product_id where component.component_product_id=p_product_id;
  return jsonb_build_object('product_id',p_product_id,'inventory_location_count',v_stock_count,'open_purchase_order_count',v_open_purchase_orders,'active_recipes',v_active_recipes);
end $$;

create or replace function public.get_culinary_recipe_context(p_company_id uuid,p_product_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_product public.products%rowtype;v_recipe public.culinary_recipes%rowtype;v_draft public.culinary_recipe_versions%rowtype;v_active public.culinary_recipe_versions%rowtype;v_currency text;v_price numeric;v_draft_json jsonb;v_active_json jsonb;v_draft_cost jsonb;v_active_cost jsonb;
begin
 if auth.uid() is null or not public.has_company_permission(p_company_id,'view_recipes') then raise exception 'No autorizado para consultar recetas.';end if;
 select * into v_product from public.products where id=p_product_id and company_id=p_company_id;if not found then raise exception 'Platillo no encontrado.';end if;
 select * into v_recipe from public.culinary_recipes where company_id=p_company_id and product_id=p_product_id;
 if found then select * into v_draft from public.culinary_recipe_versions where recipe_id=v_recipe.id and status='draft' order by version_number desc limit 1;select * into v_active from public.culinary_recipe_versions where recipe_id=v_recipe.id and status='active';end if;
 select pp.amount,pp.currency_code into v_price,v_currency from public.product_prices pp join public.price_lists pl on pl.id=pp.price_list_id where pp.product_id=p_product_id and pp.valid_from<=now()and(pp.valid_to is null or pp.valid_to>now())and pl.is_active order by pp.valid_from desc limit 1;v_currency:=coalesce(v_currency,(select base_currency_code from public.companies where id=p_company_id),'MXN');
 if v_draft.id is not null then
  begin v_draft_cost:=public.culinary_version_cost(v_draft.id,v_draft.portion_count,now(),v_currency);exception when others then v_draft_cost:=jsonb_build_object('allowed',false,'total_cost',null,'cost_per_portion',null,'currency_code',v_currency,'blockers',jsonb_build_array(jsonb_build_object('code','cost_context_unavailable','message','No se pudo calcular el costo; revisa la configuración de costos.')));end;
  v_draft_json:=to_jsonb(v_draft)||jsonb_build_object('components',(select coalesce(jsonb_agg(jsonb_build_object('id',component.id,'product_id',product.id,'product_name',product.name,'product_code',product.internal_sku,'entered_quantity',component.entered_quantity,'entered_unit_code',component.entered_unit_code,'base_unit_code',component.base_unit_code,'recipe_kind',component_recipe.recipe_kind)order by component.sort_order,product.name),'[]')from public.culinary_recipe_components component join public.products product on product.id=component.component_product_id left join public.culinary_recipes component_recipe on component_recipe.company_id=p_company_id and component_recipe.product_id=product.id where component.recipe_version_id=v_draft.id),'cost',v_draft_cost);
 end if;
 if v_active.id is not null then
  begin v_active_cost:=public.culinary_version_cost(v_active.id,v_active.portion_count,now(),v_currency);exception when others then v_active_cost:=jsonb_build_object('allowed',false,'total_cost',null,'cost_per_portion',null,'currency_code',v_currency,'blockers',jsonb_build_array(jsonb_build_object('code','cost_context_unavailable','message','No se pudo calcular el costo; revisa la configuración de costos.')));end;
  v_active_json:=to_jsonb(v_active)||jsonb_build_object('components',(select coalesce(jsonb_agg(jsonb_build_object('id',component.id,'product_id',product.id,'product_name',product.name,'product_code',product.internal_sku,'entered_quantity',component.entered_quantity,'entered_unit_code',component.entered_unit_code,'base_unit_code',component.base_unit_code,'recipe_kind',component_recipe.recipe_kind)order by component.sort_order,product.name),'[]')from public.culinary_recipe_components component join public.products product on product.id=component.component_product_id left join public.culinary_recipes component_recipe on component_recipe.company_id=p_company_id and component_recipe.product_id=product.id where component.recipe_version_id=v_active.id),'cost',v_active_cost);
 end if;
 return jsonb_build_object('product',jsonb_build_object('id',v_product.id,'name',v_product.name,'code',v_product.internal_sku),'recipe_id',v_recipe.id,'draft',v_draft_json,'active',v_active_json,'sale_price',v_price,'currency_code',v_currency);
end $$;

revoke all on function public.restaurant_normalize_unit_code(text),public.restaurant_purchase_presentation_is_standard(text),public.restaurant_purchase_configuration_error(text,text,numeric),public.list_restaurant_catalog_integrity_issues(uuid,integer,integer),public.get_restaurant_ingredient_archive_context(uuid,uuid) from public,anon;
grant execute on function public.get_product_purchase_unit(uuid,uuid),public.save_restaurant_catalog_item(uuid,uuid,text,text,text,text,text,text,boolean,boolean,uuid,text,numeric,boolean,text,timestamptz,uuid),public.list_restaurant_catalog_integrity_issues(uuid,integer,integer),public.get_restaurant_ingredient_archive_context(uuid,uuid),public.get_culinary_recipe_context(uuid,uuid) to authenticated;

notify pgrst, 'reload schema';
commit;
