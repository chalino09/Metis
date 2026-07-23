-- POS Fase 1: read-only stock lookup across authorized branches.
-- Sales continue to validate only the active location's operational balance.

create or replace function public.list_pos_product_other_location_stock(
  p_company_id uuid,
  p_product_id uuid,
  p_current_location_id uuid,
  p_page integer default 1,
  p_page_size integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 20), 1), 100);
  v_product record;
  v_total bigint;
  v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_inventory') then
    raise exception 'No autorizado para consultar existencias.';
  end if;

  if not exists (
    select 1
    from public.locations location_data
    where location_data.id = p_current_location_id
      and location_data.company_id = p_company_id
      and public.can_access_location(location_data.id)
  ) then
    raise exception 'Sucursal activa no disponible.';
  end if;

  select product.name, product.unit
  into v_product
  from public.products product
  where product.id = p_product_id
    and product.company_id = p_company_id;
  if not found then
    raise exception 'Producto no encontrado.';
  end if;

  with authorized_locations as materialized (
    select
      location_data.id as location_id,
      location_data.external_code as location_code,
      location_data.name as location_name,
      coalesce(balance.quantity_on_hand, 0) as quantity_on_hand,
      balance.updated_at
    from public.locations location_data
    left join public.inventory_balances balance
      on balance.company_id = location_data.company_id
      and balance.location_id = location_data.id
      and balance.product_id = p_product_id
    where location_data.company_id = p_company_id
      and location_data.is_active
      and location_data.id <> p_current_location_id
      and public.can_access_location(location_data.id)
  ), paged as materialized (
    select *
    from authorized_locations
    order by location_name, location_id
    limit v_size offset (v_page - 1) * v_size
  )
  select
    (select count(*) from authorized_locations),
    coalesce(jsonb_agg(jsonb_build_object(
      'location_id', location_id,
      'location_code', location_code,
      'location_name', location_name,
      'quantity_on_hand', quantity_on_hand,
      'updated_at', updated_at
    ) order by location_name, location_id), '[]'::jsonb)
  into v_total, v_items
  from paged;

  return jsonb_build_object(
    'product_name', v_product.name,
    'unit', v_product.unit,
    'items', v_items,
    'total', coalesce(v_total, 0),
    'page', v_page,
    'page_size', v_size
  );
end;
$$;

revoke all on function public.list_pos_product_other_location_stock(uuid,uuid,uuid,integer,integer) from public, anon;
grant execute on function public.list_pos_product_other_location_stock(uuid,uuid,uuid,integer,integer) to authenticated;
notify pgrst, 'reload schema';
