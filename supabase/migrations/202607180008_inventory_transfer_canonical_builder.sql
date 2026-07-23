-- Satrapy · Canonical product identities for the visual transfer builder.
-- Alpha codes remain supported only by the legacy bulk-import boundary.

create or replace function public.create_inventory_transfer_items(
  p_company_id uuid,
  p_source_location_id uuid,
  p_destination_location_id uuid,
  p_lines jsonb,
  p_client_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request_id uuid := coalesce(p_client_request_id, gen_random_uuid());
  v_transfer_id uuid;
  v_received integer;
  v_distinct integer;
begin
  perform public.assert_inventory_transfer_access(p_company_id, p_source_location_id);
  perform public.assert_inventory_transfer_access(p_company_id, p_destination_location_id);
  if p_source_location_id = p_destination_location_id then
    raise exception 'El origen y el destino deben ser distintos.';
  end if;
  if jsonb_typeof(coalesce(p_lines, 'null'::jsonb)) <> 'array' then
    raise exception 'Las partidas deben enviarse como una lista.';
  end if;

  select id into v_transfer_id
  from public.inventory_transfers
  where sent_request_id = v_request_id;
  if found then
    return jsonb_build_object('inventory_transfer_id', v_transfer_id,
      'status', (select status from public.inventory_transfers where id = v_transfer_id),
      'line_count', (select line_count from public.inventory_transfers where id = v_transfer_id),
      'idempotent', true);
  end if;

  select count(*), count(distinct input.product_id)
  into v_received, v_distinct
  from jsonb_to_recordset(p_lines) input(product_id uuid, quantity numeric);
  if v_received < 1 or v_received > 500 or v_received <> v_distinct then
    raise exception 'Envía entre 1 y 500 productos distintos por lote.';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_lines) input(product_id uuid, quantity numeric)
    left join public.products product
      on product.id = input.product_id
      and product.company_id = p_company_id
      and product.is_active
      and product.is_inventory_tracked
    where input.product_id is null or input.quantity is null or input.quantity <= 0 or product.id is null
  ) then
    raise exception 'La transferencia contiene productos o cantidades no válidos.';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_lines) input(product_id uuid, quantity numeric)
    left join public.inventory_balances balance
      on balance.location_id = p_source_location_id and balance.product_id = input.product_id
    where coalesce(balance.quantity_on_hand, 0) < input.quantity
  ) then
    raise exception 'El origen no tiene existencia suficiente para preparar todas las partidas.';
  end if;

  insert into public.inventory_transfers(
    company_id, source_location_id, destination_location_id, line_count, sent_request_id, sent_by
  ) values (
    p_company_id, p_source_location_id, p_destination_location_id, v_received, v_request_id, auth.uid()
  ) returning id into v_transfer_id;

  insert into public.inventory_transfer_lines(inventory_transfer_id, product_id, quantity)
  select v_transfer_id, input.product_id, input.quantity
  from jsonb_to_recordset(p_lines) input(product_id uuid, quantity numeric);

  perform public.write_sales_audit(p_company_id, 'inventory_transfer.prepared', 'inventory_transfers', v_transfer_id,
    jsonb_build_object('source_location_id', p_source_location_id,
      'destination_location_id', p_destination_location_id,
      'line_count', v_received, 'client_request_id', v_request_id));
  return jsonb_build_object('inventory_transfer_id', v_transfer_id, 'status', 'sent',
    'line_count', v_received, 'idempotent', false);
exception when unique_violation then
  select id into v_transfer_id from public.inventory_transfers where sent_request_id = v_request_id;
  if v_transfer_id is not null then
    return jsonb_build_object('inventory_transfer_id', v_transfer_id,
      'status', (select status from public.inventory_transfers where id = v_transfer_id),
      'line_count', (select line_count from public.inventory_transfers where id = v_transfer_id),
      'idempotent', true);
  end if;
  raise;
end;
$$;

revoke all on function public.create_inventory_transfer_items(uuid,uuid,uuid,jsonb,uuid) from public, anon;
grant execute on function public.create_inventory_transfer_items(uuid,uuid,uuid,jsonb,uuid) to authenticated;
