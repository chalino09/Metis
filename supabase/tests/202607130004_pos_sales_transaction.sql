-- Satrapy · Module 2 transactional sale regression.
-- Requires an existing Super Admin. All fixtures are rolled back.
begin;

do $fixtures$
declare
  v_actor_id uuid;
begin
  select role_assignment.user_id into v_actor_id
  from public.user_roles role_assignment
  join public.roles role_data on role_data.id = role_assignment.role_id
  where role_data.code = 'super_admin'
  limit 1;
  if v_actor_id is null then raise exception 'La prueba POS requiere un Super Admin existente.'; end if;
  perform set_config('app.pos_sales_test_actor', v_actor_id::text, true);

  insert into public.companies(id, legal_name, display_name)
  values ('14000000-0000-4000-8000-000000000001', 'Empresa POS temporal', 'Empresa POS temporal');
  insert into public.units_of_measure(id, company_id, code, name)
  values ('14000000-0000-4000-8000-000000000002', '14000000-0000-4000-8000-000000000001', 'PZA', 'Pieza');
  insert into public.tax_categories(id, company_id, code, name)
  values ('14000000-0000-4000-8000-000000000003', '14000000-0000-4000-8000-000000000001', 'IVA16', 'IVA 16%');
  insert into public.tax_rates(id, tax_category_id, jurisdiction_code, rate, valid_from, created_by)
  values ('14000000-0000-4000-8000-000000000004', '14000000-0000-4000-8000-000000000003', 'MX', .16, now() - interval '1 day', v_actor_id);
  insert into public.price_lists(id, company_id, external_code, name, currency_code, is_active, status, is_default)
  values ('14000000-0000-4000-8000-000000000005', '14000000-0000-4000-8000-000000000001', 'MOSTRADOR', 'Mostrador', 'MXN', true, 'active', true);
  update public.companies set default_price_list_id = '14000000-0000-4000-8000-000000000005' where id = '14000000-0000-4000-8000-000000000001';
  insert into public.locations(id, company_id, external_code, name, location_type, classification_source)
  values ('14000000-0000-4000-8000-000000000006', '14000000-0000-4000-8000-000000000001', 'SUC-TEST', 'Sucursal de prueba', 'sucursal', 'manual_review');
  insert into public.products(id, company_id, alpha_sku, name, unit, product_type, is_active, is_sellable, is_inventory_tracked, sales_unit_id, tax_category_id, commercial_review_required)
  values ('14000000-0000-4000-8000-000000000007', '14000000-0000-4000-8000-000000000001', 'POS-TEST', 'Producto POS temporal', 'PZA', 'P. TERMINADO', true, true, true, '14000000-0000-4000-8000-000000000002', '14000000-0000-4000-8000-000000000003', false);
  insert into public.product_prices(id, product_id, price_list_id, amount, currency_code, valid_from, created_by)
  values ('14000000-0000-4000-8000-000000000008', '14000000-0000-4000-8000-000000000007', '14000000-0000-4000-8000-000000000005', 100, 'MXN', now() - interval '1 day', v_actor_id);
  insert into public.sales_assortments(id, company_id, code, name, status)
  values ('14000000-0000-4000-8000-000000000009', '14000000-0000-4000-8000-000000000001', 'POS-TEST', 'Surtido POS temporal', 'draft');
  insert into public.sales_assortment_items(assortment_id, product_id) values ('14000000-0000-4000-8000-000000000009', '14000000-0000-4000-8000-000000000007');
  insert into public.location_sales_assortments(id, location_id, assortment_id, valid_from)
  values ('14000000-0000-4000-8000-000000000010', '14000000-0000-4000-8000-000000000006', '14000000-0000-4000-8000-000000000009', now() - interval '1 day');
  update public.sales_assortments
  set status = 'active'
  where id = '14000000-0000-4000-8000-000000000009';
  insert into public.inventory_snapshots(id, company_id, source_file_name, snapshot_date, status, created_by)
  values ('14000000-0000-4000-8000-000000000011', '14000000-0000-4000-8000-000000000001', 'pos-test.xlsx', current_date, 'completed', v_actor_id);
  insert into public.inventory_snapshot_items(id, snapshot_id, product_id, location_id, quantity, unit, physical_quantity, available_quantity, source_file_name, source_alpha_sku)
  values ('14000000-0000-4000-8000-000000000012', '14000000-0000-4000-8000-000000000011', '14000000-0000-4000-8000-000000000007', '14000000-0000-4000-8000-000000000006', 5, 'PZA', 5, 5, 'pos-test.xlsx', 'POS-TEST');
  insert into public.cash_registers(id, company_id, location_id, code, display_name, currency_code)
  values ('14000000-0000-4000-8000-000000000013', '14000000-0000-4000-8000-000000000001', '14000000-0000-4000-8000-000000000006', 'CAJA-TEST', 'Caja temporal', 'MXN');
  insert into public.payment_methods(id, company_id, code, display_name, settlement_kind)
  values ('14000000-0000-4000-8000-000000000014', '14000000-0000-4000-8000-000000000001', 'EFECTIVO', 'Efectivo', 'cash_drawer');
  insert into public.cash_denominations(id, company_id, currency_code, value, display_name)
  values
    ('14000000-0000-4000-8000-000000000015', '14000000-0000-4000-8000-000000000001', 'MXN', 100, '$100'),
    ('14000000-0000-4000-8000-000000000018', '14000000-0000-4000-8000-000000000001', 'MXN', 10, '$10'),
    ('14000000-0000-4000-8000-000000000019', '14000000-0000-4000-8000-000000000001', 'MXN', 5, '$5'),
    ('14000000-0000-4000-8000-000000000020', '14000000-0000-4000-8000-000000000001', 'MXN', 1, '$1');
end;
$fixtures$;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', (
  select current_setting('app.pos_sales_test_actor', true)
), true);

do $assertions$
declare
  v_backfill jsonb;
  v_session jsonb;
  v_cart jsonb;
  v_quote jsonb;
  v_sale jsonb;
  v_retry jsonb;
  v_close jsonb;
  v_balance numeric;
  v_ticket_count integer;
  v_cash_count integer;
  v_inventory_ledger_count integer;
  v_tracked boolean;
begin
  v_backfill := public.backfill_inventory_opening_balances('14000000-0000-4000-8000-000000000001', null, 100);
  if (v_backfill ->> 'processed')::integer <> 1 then raise exception 'El backfill no procesó el snapshot esperado: %', v_backfill; end if;

  v_session := public.open_cash_session(
    '14000000-0000-4000-8000-000000000001',
    '14000000-0000-4000-8000-000000000013',
    jsonb_build_array(
      jsonb_build_object('denomination_id','14000000-0000-4000-8000-000000000015'::uuid,'quantity',1),
      jsonb_build_object('denomination_id','14000000-0000-4000-8000-000000000018'::uuid,'quantity',0),
      jsonb_build_object('denomination_id','14000000-0000-4000-8000-000000000019'::uuid,'quantity',0),
      jsonb_build_object('denomination_id','14000000-0000-4000-8000-000000000020'::uuid,'quantity',0)
    ),
    '14000000-0000-4000-8000-000000000016'
  );
  v_cart := public.get_or_create_sale_cart('14000000-0000-4000-8000-000000000001', (v_session ->> 'cash_session_id')::uuid);
  perform public.change_sale_cart_item((v_cart ->> 'cart_id')::uuid, '14000000-0000-4000-8000-000000000007', 1, (v_cart ->> 'revision')::integer);
  v_quote := public.quote_sale_cart((v_cart ->> 'cart_id')::uuid);
  if (v_quote ->> 'total_amount')::numeric <> 116 then raise exception 'Total con impuesto inesperado: %', v_quote; end if;

  v_sale := public.complete_sale(
    (v_cart ->> 'cart_id')::uuid,
    (v_quote ->> 'revision')::integer,
    'cash',
    '14000000-0000-4000-8000-000000000014',
    120,
    '14000000-0000-4000-8000-000000000017'
  );
  v_retry := public.complete_sale(
    (v_cart ->> 'cart_id')::uuid,
    (v_quote ->> 'revision')::integer,
    'cash',
    '14000000-0000-4000-8000-000000000014',
    120,
    '14000000-0000-4000-8000-000000000017'
  );
  if not coalesce((v_retry ->> 'idempotent')::boolean, false) or v_retry ->> 'sale_id' <> v_sale ->> 'sale_id' then
    raise exception 'El reintento idempotente no devolvió la misma venta.';
  end if;

  select quantity_on_hand into v_balance from public.inventory_balances where location_id = '14000000-0000-4000-8000-000000000006' and product_id = '14000000-0000-4000-8000-000000000007';
  select count(*) into v_inventory_ledger_count from public.inventory_ledger where product_id='14000000-0000-4000-8000-000000000007' and movement_type='sale';
  select is_inventory_tracked into v_tracked from public.products where id='14000000-0000-4000-8000-000000000007';
  if v_balance <> 4 then raise exception 'La venta no descontó inventario: saldo %, movimientos %, tracked %',v_balance,v_inventory_ledger_count,v_tracked; end if;
  select count(*) into v_ticket_count from public.canonical_tickets where sale_id = (v_sale ->> 'sale_id')::uuid;
  select count(*) into v_cash_count from public.cash_movements where source_entity_type = 'sales' and source_entity_id = (v_sale ->> 'sale_id')::uuid and amount = 116;
  if v_ticket_count <> 1 or v_cash_count <> 1 then raise exception 'Faltó ticket o movimiento de efectivo.'; end if;

  v_close := public.close_cash_session(
    (v_session ->> 'cash_session_id')::uuid,
    jsonb_build_array(
      jsonb_build_object('denomination_id','14000000-0000-4000-8000-000000000015'::uuid,'quantity',2),
      jsonb_build_object('denomination_id','14000000-0000-4000-8000-000000000018'::uuid,'quantity',1),
      jsonb_build_object('denomination_id','14000000-0000-4000-8000-000000000019'::uuid,'quantity',1),
      jsonb_build_object('denomination_id','14000000-0000-4000-8000-000000000020'::uuid,'quantity',1)
    ),
    null,
    '14000000-0000-4000-8000-000000000021'
  );
  if v_close->>'status'<>'closed' or (v_close->>'variance_amount')::numeric<>0 then
    raise exception 'El cierre/arqueo canónico no cuadró: %',v_close;
  end if;
end;
$assertions$;

reset role;
rollback;
