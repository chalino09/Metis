-- Restaurante · explica el consumo y el reintegro de ingredientes sin alterar el ledger.

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
    select 1 from public.locations location_data
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
    select product.id, coalesce(product.internal_sku, product.alpha_sku) as product_code, product.name, product.unit
    from public.products product
    where product.company_id = p_company_id
      and exists (
        select 1 from public.inventory_balances balance
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
          select 1 from public.product_external_references reference
          where reference.product_id = product.id
            and lower(reference.external_code) like '%' || v_query || '%'
        )
      )
  ), paged_products as materialized (
    select * from product_scope order by name, id
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
      last_movement.reference_label as last_movement_reference_label,
      exists (
        select 1 from public.inventory_snapshot_items snapshot_item
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
      select
        ledger.movement_type,
        ledger.occurred_at,
        case
          when ledger.movement_type in ('culinary_sale', 'culinary_sale_reversal')
            then concat_ws(' · ', culinary_item.product_name, case when ticket_data.folio is not null then concat('Ticket ', ticket_data.folio) end)
          when ledger.movement_type in ('sale', 'sale_reversal')
            then concat_ws(' · ', direct_item.product_name, case when ticket_data.folio is not null then concat('Ticket ', ticket_data.folio) end)
          else null
        end as reference_label
      from public.inventory_ledger ledger
      left join public.culinary_sale_consumptions direct_consumption
        on direct_consumption.id = ledger.culinary_consumption_id
      left join public.culinary_sale_consumption_reversals culinary_reversal
        on culinary_reversal.id = ledger.culinary_consumption_reversal_id
      left join public.culinary_sale_consumptions culinary_consumption
        on culinary_consumption.id = coalesce(direct_consumption.id, culinary_reversal.consumption_id)
      left join public.culinary_sale_item_snapshots culinary_snapshot
        on culinary_snapshot.id = culinary_consumption.snapshot_id
      left join public.sale_items culinary_item
        on culinary_item.id = culinary_snapshot.sale_item_id
      left join public.sale_cancellation_items cancellation_item
        on cancellation_item.id = ledger.sale_cancellation_item_id
      left join public.sale_items direct_item
        on direct_item.id = coalesce(ledger.sale_item_id, cancellation_item.sale_item_id)
      left join public.sales sale_data
        on sale_data.id = coalesce(culinary_item.sale_id, direct_item.sale_id)
      left join public.canonical_tickets ticket_data
        on ticket_data.sale_id = sale_data.id
      where ledger.company_id = p_company_id
        and ledger.location_id = location_data.id
        and ledger.product_id = product.id
      order by ledger.occurred_at desc,
        case when ledger.movement_type in ('sale_reversal', 'culinary_sale_reversal', 'purchase_receipt_reversal') then 1 else 0 end desc,
        ledger.id desc
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
        'last_movement_reference_label', row_data.last_movement_reference_label,
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

  return jsonb_build_object('items', v_items, 'total', coalesce(v_total, 0), 'page', v_page, 'page_size', v_size);
end;
$$;

revoke all on function public.search_inventory_products_by_location(uuid,uuid,text,integer,integer) from public, anon;
grant execute on function public.search_inventory_products_by_location(uuid,uuid,text,integer,integer) to authenticated;

create or replace function public.list_inventory_location_movements(
  p_company_id uuid,
  p_location_id uuid,
  p_product_id uuid,
  p_page integer default 1,
  p_page_size integer default 25
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 25), 1), 100);
  v_total bigint;
  v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_inventory') then
    raise exception 'No autorizado para consultar movimientos de inventario.';
  end if;

  if not exists (
    select 1 from public.locations location_data
    where location_data.id = p_location_id
      and location_data.company_id = p_company_id
      and location_data.is_active
      and public.can_access_location(location_data.id)
  ) then
    raise exception 'Ubicación no disponible.';
  end if;

  if not exists (
    select 1 from public.products product_data
    where product_data.id = p_product_id and product_data.company_id = p_company_id
  ) then
    raise exception 'Producto no disponible.';
  end if;

  with movement_scope as materialized (
    select
      ledger.id,
      ledger.movement_type,
      ledger.quantity_delta,
      ledger.balance_after,
      ledger.occurred_at,
      profile_data.full_name as actor_name,
      transfer_data.id as transfer_id,
      transfer_source.external_code as transfer_source_code,
      transfer_destination.external_code as transfer_destination_code,
      receipt_data.id as purchase_receipt_id,
      receipt_data.folio as purchase_receipt_folio,
      sale_data.id as sale_id,
      ticket_data.folio as sale_folio,
      coalesce(culinary_item.product_name, direct_item.product_name) as dish_name,
      count_data.id as inventory_count_id,
      ledger.sale_cancellation_item_id,
      ledger.sale_return_item_id,
      ledger.source_snapshot_item_id,
      ledger.inventory_count_line_id,
      ledger.culinary_consumption_id,
      ledger.culinary_consumption_reversal_id
    from public.inventory_ledger ledger
    left join public.profiles profile_data on profile_data.id = ledger.actor_id
    left join public.inventory_transfer_lines transfer_line on transfer_line.id = ledger.inventory_transfer_line_id
    left join public.inventory_transfers transfer_data on transfer_data.id = transfer_line.inventory_transfer_id
    left join public.locations transfer_source on transfer_source.id = transfer_data.source_location_id
    left join public.locations transfer_destination on transfer_destination.id = transfer_data.destination_location_id
    left join public.purchase_receipts receipt_data on receipt_data.id = ledger.purchase_receipt_id
    left join public.culinary_sale_consumptions direct_consumption on direct_consumption.id = ledger.culinary_consumption_id
    left join public.culinary_sale_consumption_reversals culinary_reversal on culinary_reversal.id = ledger.culinary_consumption_reversal_id
    left join public.culinary_sale_consumptions culinary_consumption on culinary_consumption.id = coalesce(direct_consumption.id, culinary_reversal.consumption_id)
    left join public.culinary_sale_item_snapshots culinary_snapshot on culinary_snapshot.id = culinary_consumption.snapshot_id
    left join public.sale_items culinary_item on culinary_item.id = culinary_snapshot.sale_item_id
    left join public.sale_cancellation_items cancellation_item on cancellation_item.id = ledger.sale_cancellation_item_id
    left join public.sale_items direct_item on direct_item.id = coalesce(ledger.sale_item_id, cancellation_item.sale_item_id)
    left join public.sales sale_data on sale_data.id = coalesce(culinary_item.sale_id, direct_item.sale_id)
    left join public.canonical_tickets ticket_data on ticket_data.sale_id = sale_data.id
    left join public.inventory_count_lines count_line on count_line.id = ledger.inventory_count_line_id
    left join public.inventory_counts count_data on count_data.id = count_line.inventory_count_id
    where ledger.company_id = p_company_id
      and ledger.location_id = p_location_id
      and ledger.product_id = p_product_id
  ), paged_movements as materialized (
    select * from movement_scope
    order by occurred_at desc,
      case when movement_type in ('sale_reversal', 'culinary_sale_reversal', 'purchase_receipt_reversal') then 1 else 0 end desc,
      id desc
    limit v_size offset (v_page - 1) * v_size
  )
  select
    (select count(*) from movement_scope),
    coalesce(jsonb_agg(jsonb_build_object(
      'id', movement.id,
      'movement_type', movement.movement_type,
      'quantity_delta', movement.quantity_delta,
      'balance_after', movement.balance_after,
      'occurred_at', movement.occurred_at,
      'actor_name', movement.actor_name,
      'dish_name', movement.dish_name,
      'ticket_folio', movement.sale_folio,
      'reference_type', case
        when movement.culinary_consumption_reversal_id is not null then 'culinary_sale_reversal'
        when movement.culinary_consumption_id is not null then 'culinary_sale'
        when movement.transfer_id is not null then 'transfer'
        when movement.purchase_receipt_id is not null then 'purchase_receipt'
        when movement.sale_id is not null then 'sale'
        when movement.inventory_count_id is not null then 'inventory_count'
        when movement.sale_return_item_id is not null then 'sale_return'
        when movement.sale_cancellation_item_id is not null then 'sale_cancellation'
        when movement.source_snapshot_item_id is not null then 'opening_snapshot'
        else 'adjustment'
      end,
      'reference_id', coalesce(
        movement.culinary_consumption_reversal_id,
        movement.culinary_consumption_id,
        movement.transfer_id,
        movement.purchase_receipt_id,
        movement.sale_id,
        movement.inventory_count_id,
        movement.sale_return_item_id,
        movement.sale_cancellation_item_id,
        movement.source_snapshot_item_id,
        movement.inventory_count_line_id
      ),
      'reference_label', case
        when movement.culinary_consumption_reversal_id is not null then concat_ws(' · ', movement.dish_name, case when movement.sale_folio is not null then concat('Ticket ', movement.sale_folio) end)
        when movement.culinary_consumption_id is not null then concat_ws(' · ', movement.dish_name, case when movement.sale_folio is not null then concat('Ticket ', movement.sale_folio) end)
        when movement.transfer_id is not null then concat('Transferencia · ', movement.transfer_source_code, ' → ', movement.transfer_destination_code)
        when movement.purchase_receipt_id is not null and movement.movement_type = 'purchase_receipt_reversal' then concat('Reversa de recepción ', movement.purchase_receipt_folio)
        when movement.purchase_receipt_id is not null then concat('Recepción ', movement.purchase_receipt_folio)
        when movement.sale_id is not null and movement.sale_folio is not null then concat_ws(' · ', movement.dish_name, concat('Ticket ', movement.sale_folio))
        when movement.sale_id is not null then coalesce(movement.dish_name, 'Venta')
        when movement.inventory_count_id is not null then 'Conteo físico aplicado'
        when movement.sale_return_item_id is not null then 'Devolución de venta'
        when movement.sale_cancellation_item_id is not null then 'Cancelación de venta'
        when movement.source_snapshot_item_id is not null then 'Saldo inicial importado'
        else 'Ajuste controlado'
      end
    ) order by movement.occurred_at desc,
      case when movement.movement_type in ('sale_reversal', 'culinary_sale_reversal', 'purchase_receipt_reversal') then 1 else 0 end desc,
      movement.id desc), '[]'::jsonb)
  into v_total, v_items
  from paged_movements movement;

  return jsonb_build_object('items', v_items, 'total', coalesce(v_total, 0), 'page', v_page, 'page_size', v_size);
end;
$$;

revoke all on function public.list_inventory_location_movements(uuid,uuid,uuid,integer,integer) from public, anon;
grant execute on function public.list_inventory_location_movements(uuid,uuid,uuid,integer,integer) to authenticated;

commit;
