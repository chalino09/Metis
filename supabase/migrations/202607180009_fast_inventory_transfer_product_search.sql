-- Satrapy · Fast operational selector for inventory transfers.
-- The transfer builder only needs current positive stock; snapshot, ledger and
-- total-count work belongs to the inventory inquiry screen, not this picker.

create or replace function public.search_inventory_transfer_products(
  p_company_id uuid,
  p_source_location_id uuid,
  p_query text,
  p_limit integer default 25
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_query text := lower(trim(coalesce(p_query, '')));
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 50);
  v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_inventory') then
    raise exception 'No autorizado para consultar inventario.';
  end if;

  if not exists (
    select 1
    from public.locations location_data
    where location_data.id = p_source_location_id
      and location_data.company_id = p_company_id
      and location_data.is_active
      and public.can_access_location(location_data.id)
  ) then
    raise exception 'Ubicación de origen no disponible.';
  end if;

  if length(v_query) < 2 then
    return jsonb_build_object('items', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(to_jsonb(item) order by item.search_rank, item.product_name, item.product_id), '[]'::jsonb)
  into v_items
  from (
    select
      balance.product_id,
      coalesce(product.internal_sku, product.alpha_sku) as product_code,
      product.name as product_name,
      product.unit,
      balance.quantity_on_hand,
      case
        when lower(coalesce(product.internal_sku, '')) = v_query
          or lower(product.alpha_sku) = v_query
          or lower(coalesce(product.barcode, '')) = v_query then 0
        when lower(coalesce(product.internal_sku, '')) like v_query || '%'
          or lower(product.alpha_sku) like v_query || '%' then 1
        when lower(product.name) like v_query || '%' then 2
        else 3
      end as search_rank
    from public.inventory_balances balance
    join public.products product
      on product.id = balance.product_id
      and product.company_id = p_company_id
      and product.is_active
      and product.is_inventory_tracked
    where balance.company_id = p_company_id
      and balance.location_id = p_source_location_id
      and balance.quantity_on_hand > 0
      and (
        lower(product.name) like '%' || v_query || '%'
        or lower(product.alpha_sku) like '%' || v_query || '%'
        or lower(coalesce(product.internal_sku, '')) like '%' || v_query || '%'
        or lower(coalesce(product.barcode, '')) = v_query
      )
    order by search_rank, product.name, balance.product_id
    limit v_limit
  ) item;

  return jsonb_build_object('items', v_items);
end;
$$;

revoke all on function public.search_inventory_transfer_products(uuid,uuid,text,integer) from public, anon;
grant execute on function public.search_inventory_transfer_products(uuid,uuid,text,integer) to authenticated;
