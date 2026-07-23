-- Transfer lifecycle, stock timing, idempotency and security.
begin;

do $installation$
begin
  if to_regclass('public.inventory_transfers') is null or to_regclass('public.inventory_transfer_lines') is null then
    raise exception 'Faltan las tablas de transferencias.';
  end if;
  if to_regprocedure('public.create_inventory_transfer(uuid,uuid,uuid,jsonb,uuid)') is null
    or to_regprocedure('public.create_inventory_transfer_items(uuid,uuid,uuid,jsonb,uuid)') is null
    or to_regprocedure('public.search_inventory_transfer_products(uuid,uuid,text,integer)') is null
    or to_regprocedure('public.mark_inventory_transfer_in_transit(uuid,uuid)') is null
    or to_regprocedure('public.receive_inventory_transfer(uuid,uuid)') is null then
    raise exception 'Faltan las RPCs de transferencias.';
  end if;
  if has_table_privilege('authenticated', 'public.inventory_transfers', 'insert')
    or has_table_privilege('authenticated', 'public.inventory_transfer_lines', 'update')
    or has_table_privilege('authenticated', 'public.inventory_ledger', 'insert') then
    raise exception 'authenticated no debe mutar directamente transferencias ni ledger.';
  end if;
  if has_function_privilege('anon', 'public.receive_inventory_transfer(uuid,uuid)', 'execute') then
    raise exception 'anon no debe recibir transferencias.';
  end if;
end;
$installation$;

create temporary table transfer_context (
  company_id uuid,
  source_location_id uuid,
  destination_location_id uuid,
  product_id uuid,
  sender_id uuid,
  receiver_id uuid,
  transfer_id uuid
);

do $fixtures$
declare
  v_company uuid := '15150000-0000-4000-8000-000000000001';
  v_source uuid := '15150000-0000-4000-8000-000000000002';
  v_destination uuid := '15150000-0000-4000-8000-000000000003';
  v_product uuid := '15150000-0000-4000-8000-000000000004';
  v_sender uuid := '15150000-0000-4000-8000-000000000005';
  v_receiver uuid := '15150000-0000-4000-8000-000000000006';
  v_user uuid;
begin
  foreach v_user in array array[v_sender, v_receiver] loop
    insert into auth.users(id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
      'transfer-' || v_user || '@example.invalid', '', now(), '{"provider":"email","providers":["email"]}'::jsonb,
      '{}'::jsonb, now(), now());
  end loop;

  insert into public.companies(id, legal_name, display_name)
  values (v_company, 'Transferencia temporal', 'Transferencia temporal');
  insert into public.locations(id, company_id, external_code, name, location_type, classification_source)
  values
    (v_source, v_company, 'TR-ORIGEN', 'Origen temporal', 'almacen_central', 'manual_review'),
    (v_destination, v_company, 'TR-DESTINO', 'Destino temporal', 'sucursal', 'manual_review');
  insert into public.products(id, company_id, alpha_sku, internal_sku, name, unit, product_type, is_inventory_tracked)
  values (v_product, v_company, 'ALPHA-TRANSFER-1', 'TRANSFER-1', 'Producto transferible', 'PZA', 'P. TERMINADO', true);
  insert into public.inventory_balances(company_id, location_id, product_id, quantity_on_hand)
  values (v_company, v_source, v_product, 10);

  insert into public.user_roles(user_id, role_id, company_id)
  select v_sender, id, v_company from public.roles where code = 'sucursal'
  union all
  select v_receiver, id, v_company from public.roles where code = 'almacen';
  insert into public.user_location_access(user_id, location_id)
  values (v_sender, v_source), (v_sender, v_destination), (v_receiver, v_destination);
  insert into transfer_context values (v_company, v_source, v_destination, v_product, v_sender, v_receiver, null);
end;
$fixtures$;

do $canonical_product_fixture$
declare
  v_context transfer_context%rowtype;
begin
  select * into v_context from transfer_context;
  if not exists (
    select 1
    from public.products product
    where product.id = v_context.product_id
      and product.company_id = v_context.company_id
      and product.is_active
      and product.is_inventory_tracked
  ) then
    raise exception 'El producto temporal no quedó activo y controlado por inventario.';
  end if;
end;
$canonical_product_fixture$;

grant select, update on transfer_context to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', sender_id::text, true) from transfer_context;

do $fast_product_search$
declare
  v_context transfer_context%rowtype;
  v_result jsonb;
begin
  select * into v_context from transfer_context;
  v_result := public.search_inventory_transfer_products(
    v_context.company_id, v_context.source_location_id, 'transfer', 25
  );
  if jsonb_array_length(v_result -> 'items') <> 1
    or v_result #>> '{items,0,product_id}' <> v_context.product_id::text
    or (v_result #>> '{items,0,quantity_on_hand}')::numeric <> 10 then
    raise exception 'El selector rápido no devolvió la existencia del origen: %', v_result;
  end if;
end;
$fast_product_search$;

do $sent_flow$
declare
  v_context transfer_context%rowtype;
  v_result jsonb;
  v_balance numeric;
  v_ledger_count integer;
begin
  select * into v_context from transfer_context;
  v_result := public.create_inventory_transfer_items(
    v_context.company_id, v_context.source_location_id, v_context.destination_location_id,
    jsonb_build_array(jsonb_build_object('product_id', v_context.product_id, 'quantity', 4)),
    '15150000-0000-4000-8000-000000000010'
  );
  update transfer_context set transfer_id = (v_result ->> 'inventory_transfer_id')::uuid;
  if v_result ->> 'status' <> 'sent' or coalesce((v_result ->> 'idempotent')::boolean, true) then
    raise exception 'La transferencia no quedó enviada: %', v_result;
  end if;
  select quantity_on_hand into v_balance from public.inventory_balances
  where location_id = v_context.source_location_id and product_id = v_context.product_id;
  select count(*) into v_ledger_count from public.inventory_ledger where movement_type in ('transfer_out', 'transfer_in');
  if v_balance <> 10 or v_ledger_count <> 0 then
    raise exception 'Enviar no debe mover existencias todavía: saldo %, ledger %.', v_balance, v_ledger_count;
  end if;
end;
$sent_flow$;

select set_config('request.jwt.claim.sub', receiver_id::text, true) from transfer_context;

do $premature_receipt_is_blocked$
declare
  v_transfer_id uuid;
  v_blocked boolean := false;
begin
  select transfer_id into v_transfer_id from transfer_context;
  begin
    perform public.receive_inventory_transfer(v_transfer_id, '15150000-0000-4000-8000-000000000011');
  exception when others then v_blocked := true;
  end;
  if not v_blocked then raise exception 'Se pudo recibir una transferencia que aún no está en tránsito.'; end if;
end;
$premature_receipt_is_blocked$;

select set_config('request.jwt.claim.sub', sender_id::text, true) from transfer_context;

do $transit_flow$
declare
  v_transfer_id uuid;
  v_result jsonb;
  v_retry jsonb;
  v_balance numeric;
  v_ledger_count integer;
begin
  select transfer_id into v_transfer_id from transfer_context;
  v_result := public.mark_inventory_transfer_in_transit(v_transfer_id, '15150000-0000-4000-8000-000000000012');
  v_retry := public.mark_inventory_transfer_in_transit(v_transfer_id, '15150000-0000-4000-8000-000000000012');
  if v_result ->> 'status' <> 'in_transit' or coalesce((v_result ->> 'idempotent')::boolean, true)
    or not coalesce((v_retry ->> 'idempotent')::boolean, false) then
    raise exception 'El tránsito no fue idempotente: %, %', v_result, v_retry;
  end if;
  select quantity_on_hand into v_balance from public.inventory_balances
  where location_id = (select source_location_id from transfer_context) and product_id = (select product_id from transfer_context);
  select count(*) into v_ledger_count from public.inventory_ledger where movement_type = 'transfer_out'
    and inventory_transfer_line_id in (select id from public.inventory_transfer_lines where inventory_transfer_id = v_transfer_id);
  if v_balance <> 6 or v_ledger_count <> 1 then
    raise exception 'El tránsito no descontó el origen exactamente una vez: saldo %, ledger %.', v_balance, v_ledger_count;
  end if;
end;
$transit_flow$;

select set_config('request.jwt.claim.sub', receiver_id::text, true) from transfer_context;

do $receipt_flow$
declare
  v_transfer_id uuid;
  v_result jsonb;
  v_retry jsonb;
  v_balance numeric;
begin
  select transfer_id into v_transfer_id from transfer_context;
  v_result := public.receive_inventory_transfer(v_transfer_id, '15150000-0000-4000-8000-000000000013');
  v_retry := public.receive_inventory_transfer(v_transfer_id, '15150000-0000-4000-8000-000000000013');
  if v_result ->> 'status' <> 'received' or coalesce((v_result ->> 'idempotent')::boolean, true)
    or not coalesce((v_retry ->> 'idempotent')::boolean, false) then
    raise exception 'La recepción no fue idempotente: %, %', v_result, v_retry;
  end if;
  select quantity_on_hand into v_balance from public.inventory_balances
  where location_id = (select destination_location_id from transfer_context) and product_id = (select product_id from transfer_context);
  if v_balance <> 4 then
    raise exception 'La recepción no abonó el destino: saldo %.', v_balance;
  end if;
end;
$receipt_flow$;

reset role;

do $receipt_ledger_assertion$
declare
  v_transfer_id uuid;
  v_ledger_count integer;
begin
  select transfer_id into v_transfer_id from transfer_context;
  select count(*) into v_ledger_count from public.inventory_ledger where movement_type = 'transfer_in'
    and inventory_transfer_line_id in (select id from public.inventory_transfer_lines where inventory_transfer_id = v_transfer_id);
  if v_ledger_count <> 1 then
    raise exception 'La recepción no generó exactamente un movimiento de entrada: %.', v_ledger_count;
  end if;
end;
$receipt_ledger_assertion$;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', sender_id::text, true) from transfer_context;

do $insufficient_stock_is_blocked$
declare
  v_context transfer_context%rowtype;
  v_blocked boolean := false;
begin
  select * into v_context from transfer_context;
  begin
    perform public.create_inventory_transfer(
      v_context.company_id, v_context.source_location_id, v_context.destination_location_id,
      jsonb_build_array(jsonb_build_object('product_code', 'ALPHA-TRANSFER-1', 'quantity', 7)),
      '15150000-0000-4000-8000-000000000014'
    );
  exception when others then v_blocked := true;
  end;
  if not v_blocked then raise exception 'Se creó una transferencia mayor a la existencia disponible.'; end if;
end;
$insufficient_stock_is_blocked$;

reset role;

-- A sent document is not a reservation. If another operational movement consumes
-- stock before dispatch, transit must fail without partially posting the transfer.
set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', sender_id::text, true) from transfer_context;

do $sent_then_stock_changes$
declare
  v_context transfer_context%rowtype;
  v_result jsonb;
begin
  select * into v_context from transfer_context;
  v_result := public.create_inventory_transfer(
    v_context.company_id, v_context.source_location_id, v_context.destination_location_id,
    jsonb_build_array(jsonb_build_object('product_code', 'ALPHA-TRANSFER-1', 'quantity', 5)),
    '15150000-0000-4000-8000-000000000016'
  );
  if v_result ->> 'status' <> 'sent' then raise exception 'No se creó la transferencia para la prueba de saldo cambiante.'; end if;
end;
$sent_then_stock_changes$;

reset role;
update public.inventory_balances
set quantity_on_hand = 4, updated_at = now()
where location_id = '15150000-0000-4000-8000-000000000002'
  and product_id = '15150000-0000-4000-8000-000000000004';
insert into public.inventory_ledger(company_id, location_id, product_id, quantity_delta, balance_after, movement_type)
values ('15150000-0000-4000-8000-000000000001', '15150000-0000-4000-8000-000000000002',
  '15150000-0000-4000-8000-000000000004', -2, 4, 'controlled_adjustment');

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', sender_id::text, true) from transfer_context;

do $transit_after_stock_change_is_blocked$
declare
  v_transfer_id uuid;
  v_blocked boolean := false;
  v_ledger_count integer;
begin
  select id into v_transfer_id
  from public.inventory_transfers
  where sent_request_id = '15150000-0000-4000-8000-000000000016';
  begin
    perform public.mark_inventory_transfer_in_transit(v_transfer_id, '15150000-0000-4000-8000-000000000017');
  exception when others then v_blocked := true;
  end;
  select count(*) into v_ledger_count
  from public.inventory_ledger
  where movement_type = 'transfer_out'
    and inventory_transfer_line_id in (
      select id from public.inventory_transfer_lines where inventory_transfer_id = v_transfer_id
    );
  if not v_blocked
    or (select status from public.inventory_transfers where id = v_transfer_id) <> 'sent'
    or v_ledger_count <> 0 then
    raise exception 'El tránsito aceptó o movió parcialmente una transferencia con saldo ya consumido.';
  end if;
end;
$transit_after_stock_change_is_blocked$;

reset role;
rollback;
