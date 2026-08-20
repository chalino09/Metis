-- Restaurante · archivo seguro de insumos.
-- Conserva la identidad e historial canónicos; no elimina productos.

create or replace function public.archive_restaurant_ingredient(
  p_company_id uuid,
  p_product_id uuid,
  p_reason text,
  p_client_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  v_product public.products%rowtype;
  v_active_recipe_count integer:=0;
  v_open_purchase_order_count integer:=0;
  v_has_stock boolean:=false;
  v_blockers text[]:=array[]::text[];
begin
  if auth.uid() is null or not (public.is_super_admin() or public.has_company_permission(p_company_id,'manage_products')) then
    raise exception 'No autorizado para archivar insumos.';
  end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then
    raise exception 'Indica el motivo para archivar el insumo.';
  end if;
  if p_client_request_id is null then
    raise exception 'No se pudo confirmar el archivo. Intenta nuevamente.';
  end if;
  if not exists(
    select 1 from public.companies
    where id=p_company_id and product_experience_code='restaurant'
  ) then
    raise exception 'El archivo de insumos sólo está disponible en Restaurante.';
  end if;

  if exists(
    select 1 from public.audit_log
    where company_id=p_company_id
      and action='restaurant.ingredient_archived'
      and metadata->>'client_request_id'=p_client_request_id::text
  ) then
    return jsonb_build_object('product_id',p_product_id,'archived',true,'idempotent',true);
  end if;

  select * into v_product
  from public.products
  where id=p_product_id and company_id=p_company_id
  for update;

  if not found then
    raise exception 'El insumo ya no está disponible.';
  end if;
  if not exists(
    select 1 from public.product_culinary_roles
    where company_id=p_company_id and product_id=p_product_id and role='ingredient'
  ) then
    raise exception 'Sólo se pueden archivar insumos desde este apartado.';
  end if;
  if not v_product.is_active then
    raise exception 'Este insumo ya está archivado.';
  end if;

  perform 1
  from public.inventory_balances
  where company_id=p_company_id and product_id=p_product_id
  for update;

  select exists(
    select 1 from public.inventory_balances
    where company_id=p_company_id and product_id=p_product_id and quantity_on_hand<>0
  ) into v_has_stock;

  select count(distinct recipe.id)::integer into v_active_recipe_count
  from public.culinary_recipe_components component
  join public.culinary_recipe_versions version on version.id=component.recipe_version_id and version.status='active'
  join public.culinary_recipes recipe on recipe.id=version.recipe_id and recipe.company_id=p_company_id
  where component.component_product_id=p_product_id;

  select count(distinct purchase_order.id)::integer into v_open_purchase_order_count
  from public.purchase_order_lines purchase_line
  join public.purchase_orders purchase_order on purchase_order.id=purchase_line.purchase_order_id
  where purchase_line.company_id=p_company_id
    and purchase_line.product_id=p_product_id
    and purchase_order.company_id=p_company_id
    and purchase_order.status in ('draft','pending_approval','approved');

  if v_has_stock then
    v_blockers:=array_append(v_blockers,'Tiene existencias en inventario.');
  end if;
  if v_active_recipe_count>0 then
    v_blockers:=array_append(v_blockers,format('Se usa en %s receta%s activa%s.',v_active_recipe_count,case when v_active_recipe_count=1 then '' else 's' end,case when v_active_recipe_count=1 then '' else 's' end));
  end if;
  if v_open_purchase_order_count>0 then
    v_blockers:=array_append(v_blockers,'Está incluido en órdenes de compra abiertas.');
  end if;
  if coalesce(array_length(v_blockers,1),0)>0 then
    raise exception 'No se puede archivar "%": %',v_product.name,array_to_string(v_blockers,' ');
  end if;

  update public.products
  set is_active=false
  where id=p_product_id and company_id=p_company_id;

  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(
    p_company_id,
    auth.uid(),
    'restaurant.ingredient_archived',
    'products',
    p_product_id,
    jsonb_build_object('reason',trim(p_reason),'client_request_id',p_client_request_id,'previous_is_active',true)
  );

  return jsonb_build_object('product_id',p_product_id,'archived',true,'idempotent',false);
end $$;

revoke all on function public.archive_restaurant_ingredient(uuid,uuid,text,uuid) from public,anon;
grant execute on function public.archive_restaurant_ingredient(uuid,uuid,text,uuid) to authenticated;

notify pgrst, 'reload schema';
