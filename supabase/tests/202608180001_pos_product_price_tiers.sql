-- Prueba transaccional: el rango elige precio final y el cajero autorizado
-- puede volver temporalmente a un nivel ya configurado.
begin;

do $fixtures$
declare
  v_actor_id uuid;
  v_role_id uuid;
begin
  select role_data.id into v_role_id from public.roles role_data where role_data.code = 'super_admin';
  select assignment.user_id into v_actor_id
  from public.user_roles assignment
  join public.roles role_data on role_data.id = assignment.role_id
  where role_data.code = 'super_admin'
  limit 1;
  if v_actor_id is null then
    v_actor_id := '81720000-0000-4000-8000-000000000000';
    insert into auth.users(id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (v_actor_id, 'authenticated', 'authenticated', 'pos-price-tiers@example.invalid', '{}'::jsonb, '{}'::jsonb, now(), now());
  end if;
  perform set_config('app.pos_price_tier_actor', v_actor_id::text, true);

  insert into public.companies(id, legal_name, display_name)
  values ('81720000-0000-4000-8000-000000000001', 'Empresa temporal POS', 'Empresa temporal POS');
  insert into public.units_of_measure(id, company_id, code, name)
  values ('81720000-0000-4000-8000-000000000002', '81720000-0000-4000-8000-000000000001', 'PZA', 'Pieza');
  insert into public.tax_categories(id, company_id, code, name)
  values ('81720000-0000-4000-8000-000000000003', '81720000-0000-4000-8000-000000000001', 'IVA16', 'IVA 16%');
  insert into public.tax_rates(id, tax_category_id, jurisdiction_code, rate, valid_from, created_by)
  values ('81720000-0000-4000-8000-000000000004', '81720000-0000-4000-8000-000000000003', 'MX', .16, now() - interval '1 day', v_actor_id);
  insert into public.price_lists(id, company_id, external_code, name, currency_code, is_active, status, is_default)
  values
    ('81720000-0000-4000-8000-000000000010', '81720000-0000-4000-8000-000000000001', 'ALPHA_LIST_1', 'Precio 1', 'MXN', true, 'active', true),
    ('81720000-0000-4000-8000-000000000011', '81720000-0000-4000-8000-000000000001', 'ALPHA_LIST_2', 'Descuento 1', 'MXN', true, 'active', false),
    ('81720000-0000-4000-8000-000000000012', '81720000-0000-4000-8000-000000000001', 'ALPHA_LIST_3', 'Descuento 2', 'MXN', true, 'active', false),
    ('81720000-0000-4000-8000-000000000013', '81720000-0000-4000-8000-000000000001', 'ALPHA_LIST_4', 'Top', 'MXN', true, 'active', false);
  update public.companies set default_price_list_id = '81720000-0000-4000-8000-000000000010'
  where id = '81720000-0000-4000-8000-000000000001';
  insert into public.locations(id, company_id, external_code, name, location_type, classification_source)
  values ('81720000-0000-4000-8000-000000000005', '81720000-0000-4000-8000-000000000001', 'SUC-TIER', 'Sucursal temporal', 'sucursal', 'manual_review');
  insert into public.cash_registers(id, company_id, location_id, code, display_name, currency_code)
  values ('81720000-0000-4000-8000-000000000006', '81720000-0000-4000-8000-000000000001', '81720000-0000-4000-8000-000000000005', 'CAJA-TIER', 'Caja temporal', 'MXN');
  insert into public.cash_sessions(id, company_id, location_id, cash_register_id, opened_by, status, opening_amount)
  values ('81720000-0000-4000-8000-000000000007', '81720000-0000-4000-8000-000000000001', '81720000-0000-4000-8000-000000000005', '81720000-0000-4000-8000-000000000006', v_actor_id, 'open', 0);
  insert into public.sale_carts(id, company_id, location_id, cash_register_id, cash_session_id, cashier_id)
  values ('81720000-0000-4000-8000-000000000008', '81720000-0000-4000-8000-000000000001', '81720000-0000-4000-8000-000000000005', '81720000-0000-4000-8000-000000000006', '81720000-0000-4000-8000-000000000007', v_actor_id);
  insert into public.user_roles(user_id, company_id, role_id)
  values (v_actor_id, '81720000-0000-4000-8000-000000000001', v_role_id)
  on conflict do nothing;
  insert into public.products(id, company_id, alpha_sku, name, unit, is_active, is_sellable, is_inventory_tracked, commercial_review_required, sales_unit_id, tax_category_id)
  values ('81720000-0000-4000-8000-000000000009', '81720000-0000-4000-8000-000000000001', 'PERFIL-TIER', 'Perfil temporal', 'PZA', true, true, false, false, '81720000-0000-4000-8000-000000000002', '81720000-0000-4000-8000-000000000003');
  insert into public.product_prices(id, product_id, price_list_id, amount, currency_code, valid_from, created_by)
  values
    ('81720000-0000-4000-8000-000000000020', '81720000-0000-4000-8000-000000000009', '81720000-0000-4000-8000-000000000010', 95, 'MXN', now() - interval '1 day', v_actor_id),
    ('81720000-0000-4000-8000-000000000021', '81720000-0000-4000-8000-000000000009', '81720000-0000-4000-8000-000000000011', 90, 'MXN', now() - interval '1 day', v_actor_id),
    ('81720000-0000-4000-8000-000000000022', '81720000-0000-4000-8000-000000000009', '81720000-0000-4000-8000-000000000012', 85, 'MXN', now() - interval '1 day', v_actor_id),
    ('81720000-0000-4000-8000-000000000023', '81720000-0000-4000-8000-000000000009', '81720000-0000-4000-8000-000000000013', 75, 'MXN', now() - interval '1 day', v_actor_id);
  insert into public.product_price_quantity_tiers(id, company_id, product_id, price_list_id, min_quantity, max_quantity)
  values
    ('81720000-0000-4000-8000-000000000030', '81720000-0000-4000-8000-000000000001', '81720000-0000-4000-8000-000000000009', '81720000-0000-4000-8000-000000000010', 1, 9),
    ('81720000-0000-4000-8000-000000000031', '81720000-0000-4000-8000-000000000001', '81720000-0000-4000-8000-000000000009', '81720000-0000-4000-8000-000000000011', 10, 49),
    ('81720000-0000-4000-8000-000000000032', '81720000-0000-4000-8000-000000000001', '81720000-0000-4000-8000-000000000009', '81720000-0000-4000-8000-000000000012', 50, 99),
    ('81720000-0000-4000-8000-000000000033', '81720000-0000-4000-8000-000000000001', '81720000-0000-4000-8000-000000000009', '81720000-0000-4000-8000-000000000013', 100, null);
  insert into public.sale_cart_items(cart_id, product_id, quantity)
  values ('81720000-0000-4000-8000-000000000008', '81720000-0000-4000-8000-000000000009', 50);
end;
$fixtures$;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', current_setting('app.pos_price_tier_actor', true), true);

do $assertions$
declare
  v_quote jsonb;
  v_after_manual jsonb;
  v_after_automatic jsonb;
  v_revision integer;
begin
  v_quote := public.quote_sale_cart('81720000-0000-4000-8000-000000000008');
  if v_quote #>> '{items,0,unit_price_amount}' <> '85.00'
    or v_quote #>> '{items,0,price_tier_name}' <> 'Descuento 2'
    or v_quote #>> '{items,0,price_tier_mode}' <> 'automatic'
    or (v_quote #>> '{items,0,discount_percent}')::numeric <> 0 then
    raise exception 'No se resolvió automáticamente el precio 50-99: %', v_quote;
  end if;

  v_revision := (v_quote ->> 'revision')::integer;
  perform public.set_sale_cart_item_price_tier(
    '81720000-0000-4000-8000-000000000008',
    (v_quote #>> '{items,0,cart_item_id}')::uuid,
    '81720000-0000-4000-8000-000000000030',
    v_revision
  );
  v_after_manual := public.quote_sale_cart('81720000-0000-4000-8000-000000000008');
  if v_after_manual #>> '{items,0,unit_price_amount}' <> '95.00'
    or v_after_manual #>> '{items,0,price_tier_mode}' <> 'manual'
    or not exists (select 1 from public.audit_log where action = 'sale_cart_item.price_tier_selected') then
    raise exception 'No se pudo forzar el precio 1 de manera auditada: %', v_after_manual;
  end if;

  perform public.set_sale_cart_item_price_tier(
    '81720000-0000-4000-8000-000000000008',
    (v_after_manual #>> '{items,0,cart_item_id}')::uuid,
    null,
    (select revision from public.sale_carts where id = '81720000-0000-4000-8000-000000000008')
  );
  v_after_automatic := public.quote_sale_cart('81720000-0000-4000-8000-000000000008');
  if v_after_automatic #>> '{items,0,unit_price_amount}' <> '85.00'
    or v_after_automatic #>> '{items,0,price_tier_mode}' <> 'automatic' then
    raise exception 'No se restauró el precio automático: %', v_after_automatic;
  end if;
end;
$assertions$;

rollback;
