begin;

create or replace function public.search_inventory_products_by_location(
  p_company_id uuid,
  p_location_id uuid default null,
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 50), 1), 100);
  v_query text := lower(trim(coalesce(p_query, '')));
  v_total bigint;
  v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_inventory') then
    raise exception 'No autorizado para consultar inventario.';
  end if;

  if p_location_id is not null and not exists (
    select 1
    from public.locations location_data
    where location_data.id = p_location_id
      and location_data.company_id = p_company_id
      and location_data.is_active
      and public.can_access_location(location_data.id)
  ) then
    raise exception 'Ubicación no disponible.';
  end if;

  with accessible_locations as materialized (
    select location_data.id, location_data.external_code, location_data.name
    from public.locations location_data
    where location_data.company_id = p_company_id
      and location_data.is_active
      and public.can_access_location(location_data.id)
      and (p_location_id is null or location_data.id = p_location_id)
  ), product_scope as materialized (
    select
      product.id,
      coalesce(product.internal_sku, product.alpha_sku) as product_code,
      product.name,
      product.unit
    from public.products product
    where product.company_id = p_company_id
      and exists (
        select 1
        from public.inventory_balances balance
        join public.locations location_data on location_data.id = balance.location_id
        where balance.company_id = p_company_id
          and balance.product_id = product.id
          and location_data.is_active
          and public.can_access_location(balance.location_id)
      )
      and (
        v_query = ''
        or lower(product.name) like '%' || v_query || '%'
        or lower(coalesce(product.alpha_sku, '')) like '%' || v_query || '%'
        or lower(coalesce(product.internal_sku, '')) like '%' || v_query || '%'
        or lower(coalesce(product.barcode, '')) = v_query
        or exists (
          select 1
          from public.product_external_references reference
          where reference.product_id = product.id
            and lower(reference.external_code) like '%' || v_query || '%'
        )
      )
  ), paged_products as materialized (
    select *
    from product_scope
    order by name, id
    limit v_size offset (v_page - 1) * v_size
  ), location_rows as (
    select
      product.id as product_id,
      product.product_code,
      product.name as product_name,
      product.unit,
      location_data.id as location_id,
      location_data.external_code as location_code,
      location_data.name as location_name,
      coalesce(balance.quantity_on_hand, 0) as quantity_on_hand,
      balance.updated_at as balance_updated_at,
      last_movement.movement_type as last_movement_type,
      last_movement.occurred_at as last_movement_at,
      exists (
        select 1
        from public.inventory_snapshot_items snapshot_item
        join public.inventory_snapshots snapshot_data on snapshot_data.id = snapshot_item.snapshot_id
        where snapshot_item.location_id = location_data.id
          and snapshot_item.product_id = product.id
          and snapshot_data.company_id = p_company_id
          and snapshot_data.status = 'completed'
      ) as has_snapshot_reference
    from paged_products product
    cross join accessible_locations location_data
    left join public.inventory_balances balance
      on balance.company_id = p_company_id
      and balance.location_id = location_data.id
      and balance.product_id = product.id
    left join lateral (
      select ledger.movement_type, ledger.occurred_at
      from public.inventory_ledger ledger
      where ledger.company_id = p_company_id
        and ledger.location_id = location_data.id
        and ledger.product_id = product.id
      order by ledger.occurred_at desc, ledger.id desc
      limit 1
    ) last_movement on true
  ), grouped as (
    select
      row_data.product_id,
      row_data.product_code,
      row_data.product_name,
      row_data.unit,
      sum(row_data.quantity_on_hand) as total_quantity_on_hand,
      count(*)::integer as location_count,
      count(*) filter (where row_data.quantity_on_hand > 0)::integer as positive_location_count,
      max(row_data.balance_updated_at) as balance_updated_at,
      jsonb_agg(jsonb_build_object(
        'location_id', row_data.location_id,
        'location_code', row_data.location_code,
        'location_name', row_data.location_name,
        'product_id', row_data.product_id,
        'product_code', row_data.product_code,
        'product_name', row_data.product_name,
        'unit', row_data.unit,
        'quantity_on_hand', row_data.quantity_on_hand,
        'balance_updated_at', row_data.balance_updated_at,
        'last_movement_type', row_data.last_movement_type,
        'last_movement_at', row_data.last_movement_at,
        'has_snapshot_reference', row_data.has_snapshot_reference,
        'snapshot_quantity', null,
        'snapshot_date', null,
        'snapshot_source_file', null,
        'difference_from_snapshot', null
      ) order by row_data.location_name, row_data.location_id) as locations
    from location_rows row_data
    group by row_data.product_id, row_data.product_code, row_data.product_name, row_data.unit
  )
  select
    (select count(*) from product_scope),
    coalesce(jsonb_agg(jsonb_build_object(
      'product_id', item.product_id,
      'product_code', item.product_code,
      'product_name', item.product_name,
      'unit', item.unit,
      'total_quantity_on_hand', item.total_quantity_on_hand,
      'location_count', item.location_count,
      'positive_location_count', item.positive_location_count,
      'balance_updated_at', item.balance_updated_at,
      'locations', item.locations
    ) order by item.product_name, item.product_id), '[]'::jsonb)
  into v_total, v_items
  from grouped item;

  return jsonb_build_object(
    'items', v_items,
    'total', coalesce(v_total, 0),
    'page', v_page,
    'page_size', v_size
  );
end;
$$;

revoke all on function public.search_inventory_products_by_location(uuid,uuid,text,integer,integer) from public, anon;
grant execute on function public.search_inventory_products_by_location(uuid,uuid,text,integer,integer) to authenticated;

commit;
