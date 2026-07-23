-- Operational inventory opening: bootstrap once from the first imported snapshot.
begin;

do $installation$
begin
  if to_regprocedure('public.bootstrap_inventory_balances_from_snapshot(uuid)') is null then
    raise exception 'Falta la RPC de apertura de inventario operativo.';
  end if;
  if has_function_privilege('authenticated', 'public.bootstrap_inventory_balances_from_snapshot(uuid)', 'execute') then
    raise exception 'authenticated no debe poder abrir saldos directamente.';
  end if;
end;
$installation$;

create temporary table inventory_opening_context (
  company_id uuid,
  location_id uuid,
  product_id uuid,
  actor_id uuid,
  second_company_id uuid,
  second_location_id uuid,
  second_product_id uuid,
  second_snapshot_id uuid
);

do $fixtures$
declare
  v_company uuid := '15170000-0000-4000-8000-000000000001';
  v_location uuid := '15170000-0000-4000-8000-000000000002';
  v_product uuid := '15170000-0000-4000-8000-000000000003';
  v_actor uuid := '15170000-0000-4000-8000-000000000004';
  v_second_company uuid := '15170000-0000-4000-8000-000000000005';
  v_second_location uuid := '15170000-0000-4000-8000-000000000006';
  v_second_product uuid := '15170000-0000-4000-8000-000000000007';
  v_second_snapshot uuid := '15170000-0000-4000-8000-000000000008';
begin
  insert into auth.users(id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_actor, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    'inventory-opening@example.invalid', '', now(), '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb, now(), now());
  insert into public.user_roles(user_id, role_id, company_id)
  select v_actor, id, null from public.roles where code = 'super_admin';

  insert into public.companies(id, legal_name, display_name)
  values
    (v_company, 'Apertura automática', 'Apertura automática'),
    (v_second_company, 'Apertura histórica', 'Apertura histórica');
  insert into public.locations(id, company_id, external_code, name, location_type, classification_source)
  values
    (v_location, v_company, 'OPEN-01', 'Almacén de apertura', 'almacen_operativo', 'manual_review'),
    (v_second_location, v_second_company, 'OPEN-02', 'Almacén histórico', 'almacen_operativo', 'manual_review');
  insert into public.products(id, company_id, alpha_sku, internal_sku, name, unit, product_type, is_inventory_tracked)
  values
    (v_product, v_company, 'OPEN-SKU-1', 'OPEN-SKU-1', 'Producto de apertura', 'PZA', 'P. Terminado', true),
    (v_second_product, v_second_company, 'OPEN-SKU-2', 'OPEN-SKU-2', 'Producto histórico', 'PZA', 'P. Terminado', true);
  insert into public.product_external_references(company_id, product_id, source_system, external_code, is_primary)
  values
    (v_company, v_product, 'alpha', 'OPEN-SKU-1', true),
    (v_second_company, v_second_product, 'alpha', 'OPEN-SKU-2', true);

  -- This mimics a completed legacy snapshot: it must be safely backfilled once.
  insert into public.inventory_snapshots(id, company_id, source_file_name, snapshot_date, status, created_by)
  values (v_second_snapshot, v_second_company, 'inventario-historico.xlsx', date '2026-07-01', 'completed', v_actor);
  insert into public.inventory_snapshot_items(snapshot_id, product_id, location_id, quantity, unit, source_alpha_sku)
  values (v_second_snapshot, v_second_product, v_second_location, 7, 'PZA', 'OPEN-SKU-2');

  insert into inventory_opening_context
  values (v_company, v_location, v_product, v_actor, v_second_company, v_second_location, v_second_product, v_second_snapshot);
end;
$fixtures$;

grant select on inventory_opening_context to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', actor_id::text, true) from inventory_opening_context;

do $first_import_opens_operational_inventory$
declare
  v_context inventory_opening_context%rowtype;
  v_stage jsonb;
  v_confirm jsonb;
  v_batch_id uuid;
  v_balance numeric;
  v_ledger_count integer;
  v_audit_count integer;
begin
  select * into v_context from inventory_opening_context;
  if not exists (
    select 1 from public.products
    where id = v_context.product_id and company_id = v_context.company_id and is_active
  ) then
    raise exception 'La fixture de apertura no dejó un producto activo.';
  end if;
  v_stage := public.stage_alpha_import(
    v_context.company_id, 'inventory', 'manual_upload', 'inventario-inicial.xlsx', 'xlsx', repeat('1', 64), date '2026-07-15',
    jsonb_build_array(jsonb_build_object(
      'row_number', 2, 'source_file', 'inventario-inicial.xlsx', 'detected_type', 'inventory',
      'raw_data', jsonb_build_object('cells', jsonb_build_array('OPEN-SKU-1', 4)),
      'normalized_data', jsonb_build_object('alphaSku', 'OPEN-SKU-1', 'description', 'Producto de apertura',
        'locationCode', 'OPEN-01', 'locationName', 'Almacén de apertura', 'locationType', 'almacen_operativo',
        'classificationSource', 'manual_review', 'quantity', 4, 'unit', 'PZA'),
      'validation_status', 'valid'
    )), '[]'::jsonb
  );
  v_batch_id := (v_stage ->> 'batch_id')::uuid;
  if not exists (
    select 1
    from public.import_staging_rows row_data
    join public.product_external_references reference on reference.company_id = v_context.company_id
      and reference.source_system = 'alpha'
      and reference.external_code = row_data.normalized_data ->> 'alphaSku'
    where row_data.import_batch_id = v_batch_id
  ) then
    raise exception 'La staging no encuentra el producto: sku %, productos %.',
      (select normalized_data ->> 'alphaSku' from public.import_staging_rows where import_batch_id = v_batch_id),
      (select string_agg(alpha_sku, ', ') from public.products where company_id = v_context.company_id);
  end if;
  v_confirm := public.confirm_staged_import(v_batch_id);
  if v_confirm ->> 'status' <> 'completed'
    or not coalesce((v_confirm ->> 'operational_inventory_initialized')::boolean, false)
    or (v_confirm ->> 'opening_balance_line_count')::integer <> 1
    or (v_confirm ->> 'opening_ledger_line_count')::integer <> 1 then
    raise exception 'La primera importación no abrió el inventario operativo: %', v_confirm;
  end if;
  select quantity_on_hand into v_balance from public.inventory_balances
  where location_id = v_context.location_id and product_id = v_context.product_id;
  select count(*) into v_ledger_count from public.inventory_ledger
  where company_id = v_context.company_id and product_id = v_context.product_id and movement_type = 'opening_snapshot';
  select count(*) into v_audit_count from public.audit_log
  where company_id = v_context.company_id and action = 'inventory.opening_initialized';
  if v_balance <> 4 or v_ledger_count <> 1 or v_audit_count <> 1 then
    raise exception 'La apertura no dejó saldo, ledger y auditoría consistentes: saldo %, ledger %, auditoría %.',
      v_balance, v_ledger_count, v_audit_count;
  end if;
end;
$first_import_opens_operational_inventory$;

do $later_snapshot_does_not_overwrite_live_stock$
declare
  v_context inventory_opening_context%rowtype;
  v_stage jsonb;
  v_confirm jsonb;
  v_balance numeric;
  v_ledger_count integer;
begin
  select * into v_context from inventory_opening_context;
  v_stage := public.stage_alpha_import(
    v_context.company_id, 'inventory', 'manual_upload', 'inventario-referencia.xlsx', 'xlsx', repeat('2', 64), date '2026-07-16',
    jsonb_build_array(jsonb_build_object(
      'row_number', 2, 'source_file', 'inventario-referencia.xlsx', 'detected_type', 'inventory',
      'raw_data', jsonb_build_object('cells', jsonb_build_array('OPEN-SKU-1', 9)),
      'normalized_data', jsonb_build_object('alphaSku', 'OPEN-SKU-1', 'description', 'Producto de apertura',
        'locationCode', 'OPEN-01', 'locationName', 'Almacén de apertura', 'locationType', 'almacen_operativo',
        'classificationSource', 'manual_review', 'quantity', 9, 'unit', 'PZA'),
      'validation_status', 'valid'
    )), '[]'::jsonb
  );
  v_confirm := public.confirm_staged_import((v_stage ->> 'batch_id')::uuid);
  if v_confirm ->> 'status' <> 'completed'
    or coalesce((v_confirm ->> 'operational_inventory_initialized')::boolean, true) then
    raise exception 'Un snapshot posterior intentó reinicializar existencias: %', v_confirm;
  end if;
  select quantity_on_hand into v_balance from public.inventory_balances
  where location_id = v_context.location_id and product_id = v_context.product_id;
  select count(*) into v_ledger_count from public.inventory_ledger
  where company_id = v_context.company_id and product_id = v_context.product_id and movement_type = 'opening_snapshot';
  if v_balance <> 4 or v_ledger_count <> 1 then
    raise exception 'El snapshot de referencia alteró el inventario vivo: saldo %, ledger %.', v_balance, v_ledger_count;
  end if;
end;
$later_snapshot_does_not_overwrite_live_stock$;

reset role;

do $legacy_snapshot_is_backfilled_once$
declare
  v_context inventory_opening_context%rowtype;
  v_first jsonb;
  v_second jsonb;
  v_balance numeric;
  v_ledger_count integer;
begin
  select * into v_context from inventory_opening_context;
  v_first := public.bootstrap_inventory_balances_from_snapshot(v_context.second_snapshot_id);
  v_second := public.bootstrap_inventory_balances_from_snapshot(v_context.second_snapshot_id);
  select quantity_on_hand into v_balance from public.inventory_balances
  where location_id = v_context.second_location_id and product_id = v_context.second_product_id;
  select count(*) into v_ledger_count from public.inventory_ledger
  where company_id = v_context.second_company_id and product_id = v_context.second_product_id and movement_type = 'opening_snapshot';
  if not coalesce((v_first ->> 'initialized')::boolean, false)
    or coalesce((v_second ->> 'initialized')::boolean, true)
    or v_balance <> 7 or v_ledger_count <> 1 then
    raise exception 'El backfill histórico no fue único ni consistente: %, %, saldo %, ledger %.',
      v_first, v_second, v_balance, v_ledger_count;
  end if;
end;
$legacy_snapshot_is_backfilled_once$;

rollback;
