-- Restaurante · matriz completa y consistente de unidades de compra.
-- Peso, volumen y conteo nunca se mezclan. Las presentaciones variables
-- conservan contenido explícito y sólo se normalizan datos heredados seguros.

begin;

create or replace function public.restaurant_normalize_unit_code(p_value text)
returns text language plpgsql immutable set search_path=public as $$
declare v_value text:=lower(trim(coalesce(p_value,'')));
begin
  if v_value in ('pza','pieza','piezas','ea','unidad','unidades') then return 'piece'; end if;
  return v_value;
end $$;

create or replace function public.restaurant_unit_dimension(p_value text)
returns text language sql immutable set search_path=public as $$
  select case
    when public.restaurant_normalize_unit_code(p_value) in ('mg','g','kg') then 'mass'
    when public.restaurant_normalize_unit_code(p_value) in ('ml','l') then 'volume'
    when public.restaurant_normalize_unit_code(p_value)='piece' then 'count'
  end
$$;

create or replace function public.restaurant_unit_conversion_factor(
  p_purchase_unit text,
  p_base_unit text
) returns numeric language plpgsql immutable set search_path=public as $$
declare
  v_purchase text:=public.restaurant_normalize_unit_code(p_purchase_unit);
  v_base text:=public.restaurant_normalize_unit_code(p_base_unit);
  v_purchase_dimension text:=public.restaurant_unit_dimension(v_purchase);
  v_base_dimension text:=public.restaurant_unit_dimension(v_base);
  v_purchase_scale numeric;
  v_base_scale numeric;
begin
  if v_purchase_dimension is null or v_purchase_dimension is distinct from v_base_dimension then return null; end if;
  v_purchase_scale:=case v_purchase when 'mg' then 1 when 'g' then 1000 when 'kg' then 1000000 when 'ml' then 1 when 'l' then 1000 when 'piece' then 1 end;
  v_base_scale:=case v_base when 'mg' then 1 when 'g' then 1000 when 'kg' then 1000000 when 'ml' then 1 when 'l' then 1000 when 'piece' then 1 end;
  return v_purchase_scale/v_base_scale;
end $$;

create or replace function public.restaurant_purchase_presentation_is_standard(p_code text)
returns boolean language sql immutable set search_path=public as $$
  select public.restaurant_normalize_unit_code(p_code) in ('mg','g','kg','ml','l','piece')
$$;

create or replace function public.restaurant_purchase_configuration_error(
  p_purchase_unit text,
  p_base_unit text,
  p_factor numeric
) returns text language plpgsql immutable set search_path=public as $$
declare
  v_code text:=upper(trim(coalesce(p_purchase_unit,'')));
  v_base_dimension text:=public.restaurant_unit_dimension(p_base_unit);
  v_expected numeric:=public.restaurant_unit_conversion_factor(p_purchase_unit,p_base_unit);
begin
  if v_code='' or coalesce(p_factor,0)<=0 then
    return 'Selecciona la presentación de compra y captura su contenido real.';
  end if;
  if not public.restaurant_purchase_presentation_is_standard(p_purchase_unit) and v_code !~ '[[:alpha:]]' then
    return 'La presentación debe tener un nombre, por ejemplo BOTELLA, CAJA o BOLSA; no puede ser sólo un número.';
  end if;
  if v_code='BOTELLA' and v_base_dimension<>'volume' then
    return 'Botella requiere una unidad de consumo de volumen: mililitros o litros.';
  end if;
  if v_code in ('SACO','BOLSA') and v_base_dimension<>'mass' then
    return format('%s requiere una unidad de consumo de peso: miligramos, gramos o kilogramos.',initcap(lower(v_code)));
  end if;
  if v_expected is not null and p_factor<>v_expected then
    return format('La conversión correcta es 1 %s = %s %s.',v_code,v_expected,lower(public.restaurant_normalize_unit_code(p_base_unit)));
  end if;
  if public.restaurant_purchase_presentation_is_standard(p_purchase_unit) and v_expected is null then
    return 'La unidad de compra no es compatible con la unidad de consumo.';
  end if;
  return null;
end $$;

-- Completa configuraciones estándar demostrables. También corrige una unidad
-- heredada puramente numérica hacia la unidad base sólo si nunca tuvo compras,
-- recepciones, movimientos ni existencias. No infiere cajas o envases.
with scope as materialized (
  select product.id product_id,product.company_id,product.base_unit_id,
    coalesce(config.purchase_unit_id,product.purchase_unit_id,product.base_unit_id) current_purchase_unit_id,
    config.purchase_unit_id configured_purchase_unit_id,config.base_units_per_purchase_unit previous_factor,
    purchase_unit.code purchase_code,base_unit.code base_code,
    public.restaurant_unit_conversion_factor(purchase_unit.code,base_unit.code) standard_factor,
    not exists(select 1 from public.purchase_order_lines line where line.product_id=product.id)
      and not exists(select 1 from public.purchase_receipt_lines line where line.product_id=product.id)
      and not exists(select 1 from public.inventory_ledger ledger where ledger.product_id=product.id)
      and not exists(select 1 from public.inventory_balances balance where balance.product_id=product.id and balance.quantity_on_hand<>0) has_no_operational_history
  from public.products product
  join public.companies company on company.id=product.company_id and company.product_experience_code='restaurant'
  join public.product_culinary_roles role_data on role_data.product_id=product.id and role_data.role='ingredient'
  left join public.product_purchase_units config on config.product_id=product.id
  left join public.units_of_measure purchase_unit on purchase_unit.id=coalesce(config.purchase_unit_id,product.purchase_unit_id,product.base_unit_id)
  left join public.units_of_measure base_unit on base_unit.id=product.base_unit_id
), desired as materialized (
  select scope.*,scope.current_purchase_unit_id desired_purchase_unit_id,scope.standard_factor desired_factor,'standard_matrix'::text repair_reason
  from scope where scope.standard_factor is not null
  union all
  select scope.*,scope.base_unit_id,1::numeric,'invalid_numeric_without_history'::text
  from scope
  where scope.standard_factor is null and scope.has_no_operational_history
    and trim(coalesce(scope.purchase_code,''))~'^[0-9]+([.,][0-9]+)?$'
), changes as materialized (
  select desired.*
  from desired
  where desired.desired_purchase_unit_id is not null
    and (desired.configured_purchase_unit_id is distinct from desired.desired_purchase_unit_id
      or desired.previous_factor is distinct from desired.desired_factor
      or desired.current_purchase_unit_id is distinct from desired.desired_purchase_unit_id)
), configured as (
  insert into public.product_purchase_units(product_id,purchase_unit_id,base_units_per_purchase_unit,updated_at,updated_by,presentation_content_confirmed_at,presentation_content_confirmed_by)
  select product_id,desired_purchase_unit_id,desired_factor,now(),null,null,null from changes
  on conflict(product_id) do update set purchase_unit_id=excluded.purchase_unit_id,
    base_units_per_purchase_unit=excluded.base_units_per_purchase_unit,updated_at=now(),updated_by=null,
    presentation_content_confirmed_at=null,presentation_content_confirmed_by=null
  returning product_id
), normalized_products as (
  update public.products product set purchase_unit_id=changes.desired_purchase_unit_id,updated_at=now()
  from changes where product.id=changes.product_id returning product.id
)
insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
select company_id,null,'product.purchase_unit_conversion_completed','product',product_id,
  jsonb_build_object('previous_purchase_unit',purchase_code,'previous_factor',previous_factor,
    'purchase_unit',(select code from public.units_of_measure where id=desired_purchase_unit_id),
    'factor',desired_factor,'reason',repair_reason)
from changes;

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
    left join public.units_of_measure purchase_unit on purchase_unit.id=coalesce(purchase.purchase_unit_id,product.purchase_unit_id,product.base_unit_id)
    left join public.units_of_measure base_unit on base_unit.id=product.base_unit_id
    where product.company_id=p_company_id and product.is_active
  ),issues as(select * from scope where issue_code is not null),paged as(select * from issues order by name,id limit v_size offset(v_page-1)*v_size)
  select(select count(*)from issues),coalesce((select jsonb_agg(jsonb_build_object('id',item.id,'internal_sku',item.internal_sku,'alpha_sku',item.alpha_sku,'name',item.name,'barcode',item.barcode,'unit',item.unit,'product_group',item.product_group,'inventory_policy',item.inventory_policy,'is_active',item.is_active,'is_sellable',item.is_sellable,'is_inventory_tracked',item.is_inventory_tracked,'price',null,'currency_code',null,'pos_ready',false,'catalog_role',item.catalog_role,'issue_code',item.issue_code,'message',item.message,'purchase_unit_code',item.purchase_unit_code,'base_unit_code',item.base_unit_code,'base_units_per_purchase_unit',item.base_units_per_purchase_unit)order by item.name,item.id)from paged item),'[]'::jsonb)into v_total,v_items;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size);
end $$;

revoke all on function public.restaurant_unit_dimension(text) from public,anon;
grant execute on function public.list_restaurant_catalog_integrity_issues(uuid,integer,integer) to authenticated;

notify pgrst, 'reload schema';
commit;
