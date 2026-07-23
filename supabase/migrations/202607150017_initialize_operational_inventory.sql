-- Satrapy · Initialize live inventory from the first trusted snapshot.
-- A snapshot is historical evidence. It becomes operational stock only once,
-- before the company has balances or ledger movements. Later imports never
-- overwrite live inventory.

create or replace function public.bootstrap_inventory_balances_from_snapshot(
  p_snapshot_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_snapshot public.inventory_snapshots%rowtype;
  v_balance_lines integer := 0;
  v_ledger_lines integer := 0;
begin
  select * into v_snapshot
  from public.inventory_snapshots
  where id = p_snapshot_id
  for update;
  if not found then raise exception 'Snapshot de inventario no encontrado.'; end if;
  if v_snapshot.status <> 'completed' then raise exception 'Solo un snapshot completado puede inicializar inventario operativo.'; end if;

  -- Serializes initialization per company and prevents a later snapshot from
  -- racing the first import into becoming the operational opening balance.
  perform pg_advisory_xact_lock(hashtextextended(v_snapshot.company_id::text, 0));

  if exists (select 1 from public.inventory_balances where company_id = v_snapshot.company_id)
    or exists (select 1 from public.inventory_ledger where company_id = v_snapshot.company_id) then
    return jsonb_build_object('initialized', false, 'reason', 'existing_operational_inventory', 'balance_line_count', 0, 'ledger_line_count', 0);
  end if;

  if exists (
    select 1 from public.inventory_snapshot_items
    where snapshot_id = v_snapshot.id and quantity < 0
  ) then
    raise exception 'El snapshot contiene existencias negativas y no puede ser el saldo de apertura.';
  end if;

  insert into public.inventory_balances(company_id, location_id, product_id, quantity_on_hand)
  select v_snapshot.company_id, item.location_id, item.product_id, item.quantity
  from public.inventory_snapshot_items item
  where item.snapshot_id = v_snapshot.id and item.quantity > 0;
  get diagnostics v_balance_lines = row_count;

  insert into public.inventory_ledger(
    company_id, location_id, product_id, quantity_delta, balance_after,
    movement_type, source_snapshot_item_id, actor_id
  )
  select v_snapshot.company_id, item.location_id, item.product_id, item.quantity, item.quantity,
    'opening_snapshot', item.id, auth.uid()
  from public.inventory_snapshot_items item
  where item.snapshot_id = v_snapshot.id and item.quantity > 0;
  get diagnostics v_ledger_lines = row_count;

  perform public.write_sales_audit(
    v_snapshot.company_id,
    'inventory.opening_initialized',
    'inventory_snapshot',
    v_snapshot.id,
    jsonb_build_object(
      'import_batch_id', v_snapshot.import_batch_id,
      'balance_line_count', v_balance_lines,
      'ledger_line_count', v_ledger_lines
    )
  );

  return jsonb_build_object('initialized', true, 'reason', 'opening_snapshot', 'balance_line_count', v_balance_lines, 'ledger_line_count', v_ledger_lines);
end;
$$;

-- Preserve the product-tax wrapper and add inventory initialization around it.
alter function public.confirm_staged_import(uuid)
  rename to confirm_staged_import_before_inventory_opening;

revoke all on function public.confirm_staged_import_before_inventory_opening(uuid) from public, anon, authenticated;

create function public.confirm_staged_import(p_import_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_batch public.import_batches%rowtype;
  v_snapshot_id uuid;
  v_bootstrap jsonb;
begin
  v_result := public.confirm_staged_import_before_inventory_opening(p_import_batch_id);
  if v_result ->> 'status' <> 'completed' then return v_result; end if;

  select * into v_batch from public.import_batches where id = p_import_batch_id;
  if v_batch.import_type <> 'inventory' then return v_result; end if;

  select id into v_snapshot_id
  from public.inventory_snapshots
  where import_batch_id = p_import_batch_id and company_id = v_batch.company_id and status = 'completed'
  order by created_at desc, id desc
  limit 1;
  if v_snapshot_id is null then raise exception 'La importación de inventario terminó sin snapshot operativo.'; end if;

  v_bootstrap := public.bootstrap_inventory_balances_from_snapshot(v_snapshot_id);
  return v_result || jsonb_build_object(
    'operational_inventory_initialized', coalesce((v_bootstrap ->> 'initialized')::boolean, false),
    'opening_balance_line_count', coalesce((v_bootstrap ->> 'balance_line_count')::integer, 0),
    'opening_ledger_line_count', coalesce((v_bootstrap ->> 'ledger_line_count')::integer, 0)
  );
end;
$$;

revoke all on function public.bootstrap_inventory_balances_from_snapshot(uuid) from public, anon, authenticated;
revoke all on function public.confirm_staged_import(uuid) from public, anon;
grant execute on function public.confirm_staged_import(uuid) to authenticated;

-- One-time reconciliation for companies that only have imported snapshots. The
-- latest completed snapshot is used, and any company with live activity is
-- intentionally skipped by the function above.
do $initialize_existing_snapshots$
declare
  v_snapshot_id uuid;
begin
  for v_snapshot_id in
    select distinct on (snapshot.company_id) snapshot.id
    from public.inventory_snapshots snapshot
    where snapshot.status = 'completed'
    order by snapshot.company_id, snapshot.snapshot_date desc nulls last, snapshot.created_at desc, snapshot.id desc
  loop
    perform public.bootstrap_inventory_balances_from_snapshot(v_snapshot_id);
  end loop;
end;
$initialize_existing_snapshots$;
