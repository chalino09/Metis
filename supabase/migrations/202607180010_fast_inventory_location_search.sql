-- Satrapy · Fast inventory-by-location inquiry.
-- The page lists operational balances. Imported snapshot evidence is loaded
-- only for the single product whose reference modal the user opens.

create index if not exists inventory_snapshot_items_reference_lookup_idx
  on public.inventory_snapshot_items(location_id, product_id, snapshot_id);

create or replace function public.search_inventory_balances_operational(
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
    select 1 from public.locations location_data
    where location_data.id = p_location_id
      and location_data.company_id = p_company_id
      and public.can_access_location(location_data.id)
  ) then
    raise exception 'Ubicación no disponible.';
  end if;

  with filtered as materialized (
    select
      balance.location_id,
      balance.product_id,
      balance.quantity_on_hand,
      balance.updated_at,
      product.name as product_name,
      coalesce(product.internal_sku, product.alpha_sku) as product_code,
      product.unit,
      location_data.external_code as location_code,
      location_data.name as location_name
    from public.inventory_balances balance
    join public.products product
      on product.id = balance.product_id and product.company_id = p_company_id
    join public.locations location_data
      on location_data.id = balance.location_id and location_data.company_id = p_company_id
    where balance.company_id = p_company_id
      and public.can_access_location(balance.location_id)
      and (p_location_id is null or balance.location_id = p_location_id)
      and (
        v_query = ''
        or lower(product.name) like '%' || v_query || '%'
        or lower(product.alpha_sku) like '%' || v_query || '%'
        or lower(coalesce(product.internal_sku, '')) like '%' || v_query || '%'
        or lower(coalesce(product.barcode, '')) = v_query
        or exists (
          select 1 from public.product_external_references reference
          where reference.product_id = product.id
            and lower(reference.external_code) like '%' || v_query || '%'
        )
      )
  ), paged as materialized (
    select * from filtered
    order by location_name, product_name, product_id
    limit v_size offset (v_page - 1) * v_size
  ), detailed as (
    select
      page_data.*,
      last_movement.movement_type as last_movement_type,
      last_movement.occurred_at as last_movement_at,
      exists (
        select 1
        from public.inventory_snapshot_items snapshot_item
        join public.inventory_snapshots snapshot_data on snapshot_data.id = snapshot_item.snapshot_id
        where snapshot_item.location_id = page_data.location_id
          and snapshot_item.product_id = page_data.product_id
          and snapshot_data.company_id = p_company_id
          and snapshot_data.status = 'completed'
      ) as has_snapshot_reference
    from paged page_data
    left join lateral (
      select ledger.movement_type, ledger.occurred_at
      from public.inventory_ledger ledger
      where ledger.location_id = page_data.location_id
        and ledger.product_id = page_data.product_id
      order by ledger.occurred_at desc, ledger.id desc
      limit 1
    ) last_movement on true
  )
  select
    (select count(*) from filtered),
    coalesce(jsonb_agg(jsonb_build_object(
      'location_id', item.location_id,
      'location_code', item.location_code,
      'location_name', item.location_name,
      'product_id', item.product_id,
      'product_code', item.product_code,
      'product_name', item.product_name,
      'unit', item.unit,
      'quantity_on_hand', item.quantity_on_hand,
      'balance_updated_at', item.updated_at,
      'last_movement_type', item.last_movement_type,
      'last_movement_at', item.last_movement_at,
      'has_snapshot_reference', item.has_snapshot_reference,
      'snapshot_quantity', null,
      'snapshot_date', null,
      'snapshot_source_file', null,
      'difference_from_snapshot', null
    ) order by item.location_name, item.product_name, item.product_id), '[]'::jsonb)
  into v_total, v_items
  from detailed item;

  return jsonb_build_object(
    'items', v_items,
    'total', coalesce(v_total, 0),
    'page', v_page,
    'page_size', v_size
  );
end;
$$;

create or replace function public.get_inventory_snapshot_reference(
  p_company_id uuid,
  p_location_id uuid,
  p_product_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_reference jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_inventory') then
    raise exception 'No autorizado para consultar inventario.';
  end if;
  if not exists (
    select 1 from public.locations location_data
    where location_data.id = p_location_id
      and location_data.company_id = p_company_id
      and public.can_access_location(location_data.id)
  ) then
    raise exception 'Ubicación no disponible.';
  end if;

  select jsonb_build_object(
    'available', true,
    'snapshot_quantity', snapshot_item.quantity,
    'snapshot_date', snapshot_data.snapshot_date,
    'snapshot_source_file', snapshot_data.source_file_name,
    'difference_from_snapshot', case
      when balance.product_id is null then null
      else balance.quantity_on_hand - snapshot_item.quantity
    end
  )
  into v_reference
  from public.inventory_snapshot_items snapshot_item
  join public.inventory_snapshots snapshot_data on snapshot_data.id = snapshot_item.snapshot_id
  join public.products product on product.id = snapshot_item.product_id and product.company_id = p_company_id
  left join public.inventory_balances balance
    on balance.location_id = snapshot_item.location_id and balance.product_id = snapshot_item.product_id
  where snapshot_item.location_id = p_location_id
    and snapshot_item.product_id = p_product_id
    and snapshot_data.company_id = p_company_id
    and snapshot_data.status = 'completed'
  order by snapshot_data.snapshot_date desc nulls last, snapshot_data.created_at desc, snapshot_data.id desc
  limit 1;

  return coalesce(v_reference, jsonb_build_object('available', false));
end;
$$;

revoke all on function public.search_inventory_balances_operational(uuid,uuid,text,integer,integer) from public, anon;
revoke all on function public.get_inventory_snapshot_reference(uuid,uuid,uuid) from public, anon;
grant execute on function public.search_inventory_balances_operational(uuid,uuid,text,integer,integer) to authenticated;
grant execute on function public.get_inventory_snapshot_reference(uuid,uuid,uuid) to authenticated;
