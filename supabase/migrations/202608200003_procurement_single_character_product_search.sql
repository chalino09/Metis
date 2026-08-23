-- Satrapy · Búsqueda progresiva de productos para solicitudes de compra.
-- Una letra usa coincidencia por prefijo y mantiene un límite server-side.
-- Dos o más letras habilitan coincidencias parciales y alias.

create or replace function public.search_purchase_order_products(
  p_company_id uuid,
  p_query text,
  p_limit integer default 30
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_query text := lower(trim(coalesce(p_query, '')));
  v_limit integer := least(greatest(coalesce(p_limit, 30), 1), 50);
  v_items jsonb;
begin
  if auth.uid() is null or not (
    public.has_company_permission(p_company_id, 'view_products')
    or public.has_company_permission(p_company_id, 'create_purchase_orders')
    or public.has_company_permission(p_company_id, 'edit_purchase_orders')
    or public.has_company_permission(p_company_id, 'create_procurement_requisitions')
  ) then
    raise exception 'No autorizado para seleccionar productos de compra.';
  end if;

  if length(v_query) < 1 then
    return jsonb_build_object('items', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', item.id,
    'alpha_sku', item.alpha_sku,
    'internal_sku', item.internal_sku,
    'barcode', item.barcode,
    'name', item.name,
    'unit', item.purchase_unit,
    'base_unit', item.base_unit,
    'base_units_per_purchase_unit', item.base_units_per_purchase_unit,
    'is_inventory_tracked', item.is_inventory_tracked
  ) order by item.search_rank, item.name, item.id), '[]'::jsonb)
  into v_items
  from (
    select
      product.id,
      product.alpha_sku,
      product.internal_sku,
      product.barcode,
      product.name,
      product.is_inventory_tracked,
      purchase.code as purchase_unit,
      base.code as base_unit,
      coalesce(config.base_units_per_purchase_unit, 1) as base_units_per_purchase_unit,
      case
        when lower(coalesce(product.barcode, '')) = v_query
          or lower(coalesce(product.internal_sku, '')) = v_query
          or lower(product.alpha_sku) = v_query then 0
        when lower(coalesce(product.internal_sku, '')) like v_query || '%'
          or lower(product.alpha_sku) like v_query || '%' then 1
        when lower(product.name) like v_query || '%' then 2
        when exists (
          select 1 from public.product_aliases alias
          where alias.product_id = product.id and alias.normalized_value like '%' || v_query || '%'
        ) then 3
        else 4
      end as search_rank
    from public.products product
    left join public.product_purchase_units config on config.product_id = product.id
    left join public.units_of_measure purchase on purchase.id = coalesce(config.purchase_unit_id, product.purchase_unit_id, product.base_unit_id)
    left join public.units_of_measure base on base.id = product.base_unit_id
    where product.company_id = p_company_id
      and product.is_active
      and product.is_inventory_tracked
      and (
        (
          length(v_query) = 1
          and (
            lower(product.name) like v_query || '%'
            or lower(product.alpha_sku) like v_query || '%'
            or lower(coalesce(product.internal_sku, '')) like v_query || '%'
            or lower(coalesce(product.barcode, '')) like v_query || '%'
            or exists (
              select 1 from public.product_aliases alias
              where alias.product_id = product.id and alias.normalized_value like v_query || '%'
            )
          )
        )
        or (
          length(v_query) > 1
          and (
            lower(product.name) like '%' || v_query || '%'
            or lower(product.alpha_sku) like '%' || v_query || '%'
            or lower(coalesce(product.internal_sku, '')) like '%' || v_query || '%'
            or lower(coalesce(product.barcode, '')) = v_query
            or exists (
              select 1 from public.product_aliases alias
              where alias.product_id = product.id and alias.normalized_value like '%' || v_query || '%'
            )
          )
        )
      )
    order by search_rank, product.name, product.id
    limit v_limit
  ) item;

  return jsonb_build_object('items', v_items);
end;
$$;

revoke all on function public.search_purchase_order_products(uuid, text, integer) from public, anon;
grant execute on function public.search_purchase_order_products(uuid, text, integer) to authenticated;
