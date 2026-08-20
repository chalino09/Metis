-- Restaurante · integridad operativa del alta de catálogo.
-- Mantiene el producto canónico y agrupa en una sola transacción su función
-- culinaria, presentación de compra y control de lotes.

begin;

create or replace function public.restaurant_unit_conversion_factor(
  p_purchase_unit text,
  p_base_unit text
) returns numeric language plpgsql immutable set search_path=public as $$
declare
  v_purchase text:=lower(trim(coalesce(p_purchase_unit,'')));
  v_base text:=lower(trim(coalesce(p_base_unit,'')));
begin
  if v_purchase in ('pza','pieza','ea') then v_purchase:='piece'; end if;
  if v_base in ('pza','pieza','ea') then v_base:='piece'; end if;
  if v_purchase=v_base and v_base in ('g','kg','ml','l','piece') then return 1; end if;
  if v_purchase='kg' and v_base='g' then return 1000; end if;
  if v_purchase='g' and v_base='kg' then return 0.001; end if;
  if v_purchase='l' and v_base='ml' then return 1000; end if;
  if v_purchase='ml' and v_base='l' then return 0.001; end if;
  return null;
end $$;

create or replace function public.save_restaurant_catalog_item(
  p_company_id uuid,
  p_product_id uuid,
  p_internal_sku text,
  p_name text,
  p_barcode text,
  p_unit text,
  p_product_group text,
  p_role text,
  p_is_sellable boolean,
  p_is_active boolean,
  p_tax_category_id uuid,
  p_purchase_unit_code text,
  p_base_units_per_purchase_unit numeric,
  p_lot_controlled boolean,
  p_reason text,
  p_expected_updated_at timestamptz,
  p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare
  v_product jsonb;
  v_product_id uuid;
  v_expected_factor numeric;
  v_existing jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_products') then
    raise exception 'No autorizado para administrar el catálogo de Restaurante.';
  end if;
  if not exists(select 1 from public.companies where id=p_company_id and product_experience_code='restaurant') then
    raise exception 'Esta operación sólo está disponible en Restaurante.';
  end if;
  if p_role not in ('dish','ingredient','preparation') then raise exception 'Función culinaria no válida.'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null or p_client_request_id is null then
    raise exception 'Captura el motivo de auditoría y vuelve a intentar.';
  end if;

  select to_jsonb(product) into v_existing
  from public.audit_log audit
  join public.products product on product.id=audit.entity_id and product.company_id=audit.company_id
  where audit.company_id=p_company_id
    and audit.action='restaurant.catalog_item_saved'
    and audit.metadata->>'request_id'=p_client_request_id::text
  limit 1;
  if v_existing is not null then return v_existing||jsonb_build_object('idempotent',true); end if;

  if p_role='ingredient' then
    if nullif(trim(coalesce(p_purchase_unit_code,'')),'') is null or coalesce(p_base_units_per_purchase_unit,0)<=0 then
      raise exception 'Selecciona la presentación de compra y una equivalencia válida.';
    end if;
    v_expected_factor:=public.restaurant_unit_conversion_factor(p_purchase_unit_code,p_unit);
    if v_expected_factor is not null and p_base_units_per_purchase_unit<>v_expected_factor then
      raise exception 'La conversión correcta es 1 % = % %.',upper(trim(p_purchase_unit_code)),v_expected_factor,lower(trim(p_unit));
    end if;
  end if;

  v_product:=public.save_product(
    p_company_id,p_product_id,p_internal_sku,p_name,p_barcode,p_unit,p_product_group,
    case when p_role='ingredient' then 'tracked' else 'not_required' end,
    case when p_role='preparation' then false else coalesce(p_is_sellable,false) end,
    p_is_active,p_tax_category_id,p_reason,p_expected_updated_at,gen_random_uuid()
  );
  v_product_id:=(v_product->>'id')::uuid;

  if p_role='ingredient' then
    perform public.set_product_purchase_unit(p_company_id,v_product_id,p_purchase_unit_code,p_base_units_per_purchase_unit,p_reason,gen_random_uuid());
    perform public.set_product_lot_controlled(p_company_id,v_product_id,coalesce(p_lot_controlled,false),p_reason,gen_random_uuid());
  end if;
  perform public.set_product_culinary_role(p_company_id,v_product_id,p_role,p_reason);

  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'restaurant.catalog_item_saved','product',v_product_id,
    jsonb_build_object('request_id',p_client_request_id,'role',p_role,'reason',trim(p_reason)));
  return (select to_jsonb(product) from public.products product where product.id=v_product_id)||jsonb_build_object('idempotent',false);
end $$;

-- Repara únicamente altas manuales de Restaurante que llegaron a configurar
-- compra pero se interrumpieron antes de registrar la función culinaria.
with recoverable as (
  select product.company_id,product.id
  from public.products product
  join public.companies company on company.id=product.company_id and company.product_experience_code='restaurant'
  where product.is_active and product.is_inventory_tracked
    and not exists(select 1 from public.product_culinary_roles role_data where role_data.product_id=product.id)
    and not exists(select 1 from public.culinary_recipes recipe where recipe.product_id=product.id)
    and exists(select 1 from public.audit_log audit where audit.company_id=product.company_id and audit.entity_id=product.id and audit.action='product.purchase_unit_configured')
), inserted as (
  insert into public.product_culinary_roles(company_id,product_id,role,assigned_by,reason)
  select company_id,id,'ingredient',null,'Recuperación de alta manual interrumpida antes de asignar la función culinaria'
  from recoverable on conflict do nothing returning company_id,product_id
)
insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
select company_id,null,'product.culinary_role_recovered','product',product_id,jsonb_build_object('role','ingredient','source','interrupted_restaurant_form') from inserted;

-- Corrige equivalencias imposibles entre unidades métricas conocidas. No toca
-- cajas, sacos u otras presentaciones cuyo contenido sí depende del proveedor.
with corrections as (
  select purchase.product_id,product.company_id,purchase.base_units_per_purchase_unit previous_factor,
    public.restaurant_unit_conversion_factor(purchase_unit.code,base_unit.code) correct_factor
  from public.product_purchase_units purchase
  join public.products product on product.id=purchase.product_id
  join public.companies company on company.id=product.company_id and company.product_experience_code='restaurant'
  join public.units_of_measure purchase_unit on purchase_unit.id=purchase.purchase_unit_id
  join public.units_of_measure base_unit on base_unit.id=product.base_unit_id
  where public.restaurant_unit_conversion_factor(purchase_unit.code,base_unit.code) is not null
    and purchase.base_units_per_purchase_unit<>public.restaurant_unit_conversion_factor(purchase_unit.code,base_unit.code)
), updated as (
  update public.product_purchase_units purchase
  set base_units_per_purchase_unit=corrections.correct_factor,updated_at=now(),updated_by=null
  from corrections where purchase.product_id=corrections.product_id
  returning purchase.product_id,corrections.company_id,corrections.previous_factor,corrections.correct_factor
)
insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
select company_id,null,'product.purchase_unit_conversion_repaired','product',product_id,
  jsonb_build_object('previous_factor',previous_factor,'correct_factor',correct_factor,'reason','Conversión métrica incoherente') from updated;

revoke all on function public.restaurant_unit_conversion_factor(text,text) from public,anon;
revoke all on function public.save_restaurant_catalog_item(uuid,uuid,text,text,text,text,text,text,boolean,boolean,uuid,text,numeric,boolean,text,timestamptz,uuid) from public,anon;
grant execute on function public.save_restaurant_catalog_item(uuid,uuid,text,text,text,text,text,text,boolean,boolean,uuid,text,numeric,boolean,text,timestamptz,uuid) to authenticated;

commit;
