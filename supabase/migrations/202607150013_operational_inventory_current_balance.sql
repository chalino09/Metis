-- Satrapy · Operational inventory: current balances with snapshot reference.
-- inventory_balances is the live source; imported snapshots remain dated evidence.

insert into public.permissions (code, description) values
  ('view_inventory', 'Consultar la existencia operativa de ubicaciones autorizadas.')
on conflict (code) do update set description = excluded.description;

insert into public.role_permissions (role_id, permission_id)
select role_data.id, permission_data.id
from public.roles role_data
join public.permissions permission_data on permission_data.code = 'view_inventory'
where role_data.code in (
  'super_admin', 'direccion_admin', 'sucursal', 'ingeniero_campo', 'almacen', 'punto_venta'
)
on conflict do nothing;

drop policy if exists inventory_balances_read on public.inventory_balances;
create policy inventory_balances_read on public.inventory_balances
  for select to authenticated
  using (
    public.has_company_permission(company_id, 'view_inventory')
    and public.can_access_location(location_id)
  );

create or replace function public.search_inventory_balances(
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
      and public.can_access_location(location_data.id)
  ) then
    raise exception 'Ubicación no disponible.';
  end if;

  select count(*) into v_total
  from public.inventory_balances balance
  join public.products product on product.id = balance.product_id and product.company_id = p_company_id
  join public.locations location_data on location_data.id = balance.location_id and location_data.company_id = p_company_id
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
    );

  with latest_snapshot_per_location as materialized (
    select distinct on (snapshot_item.location_id)
      snapshot_item.location_id,
      snapshot_data.id as snapshot_id,
      snapshot_data.snapshot_date,
      snapshot_data.source_file_name
    from public.inventory_snapshot_items snapshot_item
    join public.inventory_snapshots snapshot_data on snapshot_data.id = snapshot_item.snapshot_id
    where snapshot_data.company_id = p_company_id
      and snapshot_data.status = 'completed'
      and (p_location_id is null or snapshot_item.location_id = p_location_id)
    order by snapshot_item.location_id, snapshot_data.snapshot_date desc nulls last, snapshot_data.created_at desc, snapshot_data.id desc
  ), filtered as materialized (
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
    join public.products product on product.id = balance.product_id and product.company_id = p_company_id
    join public.locations location_data on location_data.id = balance.location_id and location_data.company_id = p_company_id
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
  ), paged as (
    select *
    from filtered
    order by location_name, product_name, product_id
    limit v_size offset (v_page - 1) * v_size
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'location_id', page_data.location_id,
    'location_code', page_data.location_code,
    'location_name', page_data.location_name,
    'product_id', page_data.product_id,
    'product_code', page_data.product_code,
    'product_name', page_data.product_name,
    'unit', page_data.unit,
    'quantity_on_hand', page_data.quantity_on_hand,
    'balance_updated_at', page_data.updated_at,
    'last_movement_type', last_movement.movement_type,
    'last_movement_at', last_movement.occurred_at,
    'snapshot_quantity', snapshot_item.quantity,
    'snapshot_date', latest_snapshot.snapshot_date,
    'snapshot_source_file', latest_snapshot.source_file_name,
    'difference_from_snapshot', case
      when snapshot_item.id is null then null
      else page_data.quantity_on_hand - snapshot_item.quantity
    end
  ) order by page_data.location_name, page_data.product_name, page_data.product_id), '[]'::jsonb)
  into v_items
  from paged page_data
  left join latest_snapshot_per_location latest_snapshot on latest_snapshot.location_id = page_data.location_id
  left join public.inventory_snapshot_items snapshot_item
    on snapshot_item.snapshot_id = latest_snapshot.snapshot_id
   and snapshot_item.location_id = page_data.location_id
   and snapshot_item.product_id = page_data.product_id
  left join lateral (
    select ledger.movement_type, ledger.occurred_at
    from public.inventory_ledger ledger
    where ledger.location_id = page_data.location_id
      and ledger.product_id = page_data.product_id
    order by ledger.occurred_at desc, ledger.id desc
    limit 1
  ) last_movement on true;

  return jsonb_build_object(
    'items', coalesce(v_items, '[]'::jsonb),
    'total', coalesce(v_total, 0),
    'page', v_page,
    'page_size', v_size
  );
end;
$$;

revoke all on function public.search_inventory_balances(uuid, uuid, text, integer, integer) from public, anon;
grant execute on function public.search_inventory_balances(uuid, uuid, text, integer, integer) to authenticated;
