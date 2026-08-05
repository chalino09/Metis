-- Satrapy · Historial contextual del ledger para una existencia por ubicación.
-- La consulta queda paginada y restringida a la ubicación que el usuario ya puede consultar.

begin;

create index if not exists inventory_ledger_location_product_timeline_idx
  on public.inventory_ledger(company_id, location_id, product_id, occurred_at desc, id desc);

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
    select 1
    from public.locations location_data
    where location_data.id = p_location_id
      and location_data.company_id = p_company_id
      and location_data.is_active
      and public.can_access_location(location_data.id)
  ) then
    raise exception 'Ubicación no disponible.';
  end if;

  if not exists (
    select 1
    from public.products product_data
    where product_data.id = p_product_id
      and product_data.company_id = p_company_id
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
      count_data.id as inventory_count_id,
      ledger.sale_cancellation_item_id,
      ledger.sale_return_item_id,
      ledger.source_snapshot_item_id,
      ledger.inventory_count_line_id
    from public.inventory_ledger ledger
    left join public.profiles profile_data on profile_data.id = ledger.actor_id
    left join public.inventory_transfer_lines transfer_line on transfer_line.id = ledger.inventory_transfer_line_id
    left join public.inventory_transfers transfer_data on transfer_data.id = transfer_line.inventory_transfer_id
    left join public.locations transfer_source on transfer_source.id = transfer_data.source_location_id
    left join public.locations transfer_destination on transfer_destination.id = transfer_data.destination_location_id
    left join public.purchase_receipts receipt_data on receipt_data.id = ledger.purchase_receipt_id
    left join public.sale_items sale_item on sale_item.id = ledger.sale_item_id
    left join public.sales sale_data on sale_data.id = sale_item.sale_id
    left join public.canonical_tickets ticket_data on ticket_data.sale_id = sale_data.id
    left join public.inventory_count_lines count_line on count_line.id = ledger.inventory_count_line_id
    left join public.inventory_counts count_data on count_data.id = count_line.inventory_count_id
    where ledger.company_id = p_company_id
      and ledger.location_id = p_location_id
      and ledger.product_id = p_product_id
  ), paged_movements as materialized (
    select *
    from movement_scope
    order by occurred_at desc, id desc
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
      'reference_type', case
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
        when movement.transfer_id is not null then concat('Transferencia · ', movement.transfer_source_code, ' → ', movement.transfer_destination_code)
        when movement.purchase_receipt_id is not null and movement.movement_type = 'purchase_receipt_reversal' then concat('Reversa de recepción ', movement.purchase_receipt_folio)
        when movement.purchase_receipt_id is not null then concat('Recepción ', movement.purchase_receipt_folio)
        when movement.sale_id is not null and movement.sale_folio is not null then concat('Venta ', movement.sale_folio)
        when movement.sale_id is not null then 'Venta'
        when movement.inventory_count_id is not null then 'Conteo físico aplicado'
        when movement.sale_return_item_id is not null then 'Devolución de venta'
        when movement.sale_cancellation_item_id is not null then 'Cancelación de venta'
        when movement.source_snapshot_item_id is not null then 'Saldo inicial importado'
        else 'Ajuste controlado'
      end
    ) order by movement.occurred_at desc, movement.id desc), '[]'::jsonb)
  into v_total, v_items
  from paged_movements movement;

  return jsonb_build_object(
    'items', v_items,
    'total', coalesce(v_total, 0),
    'page', v_page,
    'page_size', v_size
  );
end;
$$;

revoke all on function public.list_inventory_location_movements(uuid,uuid,uuid,integer,integer) from public, anon;
grant execute on function public.list_inventory_location_movements(uuid,uuid,uuid,integer,integer) to authenticated;

commit;
