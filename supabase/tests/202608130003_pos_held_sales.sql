-- Prueba transaccional de suspender, listar, intercambiar y descartar ventas POS.
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
    v_actor_id := '81330000-0000-4000-8000-000000000000';
    insert into auth.users(id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (v_actor_id, 'authenticated', 'authenticated', 'pos-held-sales@example.invalid', '{}'::jsonb, '{}'::jsonb, now(), now());
  end if;
  perform set_config('app.pos_held_sales_actor', v_actor_id::text, true);

  insert into public.companies(id, legal_name, display_name)
  values ('81330000-0000-4000-8000-000000000001', 'Empresa temporal POS', 'Empresa temporal POS');
  insert into public.units_of_measure(id, company_id, code, name)
  values ('81330000-0000-4000-8000-000000000007', '81330000-0000-4000-8000-000000000001', 'PZA', 'Pieza');
  insert into public.tax_categories(id, company_id, code, name)
  values ('81330000-0000-4000-8000-000000000008', '81330000-0000-4000-8000-000000000001', 'IVA16', 'IVA 16%');
  insert into public.tax_rates(id, tax_category_id, jurisdiction_code, rate, valid_from, created_by)
  values ('81330000-0000-4000-8000-000000000009', '81330000-0000-4000-8000-000000000008', 'MX', .16, now() - interval '1 day', v_actor_id);
  insert into public.price_lists(id, company_id, external_code, name, currency_code, is_active, status, is_default)
  values ('81330000-0000-4000-8000-000000000010', '81330000-0000-4000-8000-000000000001', 'MOSTRADOR', 'Mostrador', 'MXN', true, 'active', true);
  update public.companies set default_price_list_id = '81330000-0000-4000-8000-000000000010'
  where id = '81330000-0000-4000-8000-000000000001';
  insert into public.locations(id, company_id, external_code, name, location_type, classification_source)
  values ('81330000-0000-4000-8000-000000000002', '81330000-0000-4000-8000-000000000001', 'SUC-HOLD', 'Sucursal temporal', 'sucursal', 'manual_review');
  insert into public.cash_registers(id, company_id, location_id, code, display_name, currency_code)
  values ('81330000-0000-4000-8000-000000000003', '81330000-0000-4000-8000-000000000001', '81330000-0000-4000-8000-000000000002', 'CAJA-HOLD', 'Caja temporal', 'MXN');
  insert into public.cash_sessions(id, company_id, location_id, cash_register_id, opened_by, status, opening_amount)
  values ('81330000-0000-4000-8000-000000000004', '81330000-0000-4000-8000-000000000001', '81330000-0000-4000-8000-000000000002', '81330000-0000-4000-8000-000000000003', v_actor_id, 'open', 0);
  insert into public.sale_carts(id, company_id, location_id, cash_register_id, cash_session_id, cashier_id)
  values ('81330000-0000-4000-8000-000000000005', '81330000-0000-4000-8000-000000000001', '81330000-0000-4000-8000-000000000002', '81330000-0000-4000-8000-000000000003', '81330000-0000-4000-8000-000000000004', v_actor_id);
  insert into public.user_roles(user_id, company_id, role_id)
  values (v_actor_id, '81330000-0000-4000-8000-000000000001', v_role_id)
  on conflict do nothing;

  -- El contrato solo necesita una partida para suspender; la cotización vacía de
  -- reemplazo evita depender aquí del catálogo comercial completo.
  insert into public.products(id, company_id, alpha_sku, name, unit, is_active, is_sellable, is_inventory_tracked, commercial_review_required, sales_unit_id, tax_category_id)
  values ('81330000-0000-4000-8000-000000000006', '81330000-0000-4000-8000-000000000001', 'HOLD-1', 'Producto temporal', 'PZA', true, true, false, false, '81330000-0000-4000-8000-000000000007', '81330000-0000-4000-8000-000000000008');
  insert into public.product_prices(id, product_id, price_list_id, amount, currency_code, valid_from, created_by)
  values ('81330000-0000-4000-8000-000000000011', '81330000-0000-4000-8000-000000000006', '81330000-0000-4000-8000-000000000010', 100, 'MXN', now() - interval '1 day', v_actor_id);
  insert into public.sale_cart_items(cart_id, product_id, quantity)
  values ('81330000-0000-4000-8000-000000000005', '81330000-0000-4000-8000-000000000006', 2);
end;
$fixtures$;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', current_setting('app.pos_held_sales_actor', true), true);

do $assertions$
declare
  v_hold jsonb;
  v_list jsonb;
  v_resume jsonb;
  v_active_id uuid;
  v_active_revision integer;
  v_held_revision integer;
begin
  v_hold := public.hold_own_sale_cart('81330000-0000-4000-8000-000000000005', 1);
  v_active_id := (v_hold #>> '{quote,cart_id}')::uuid;
  v_active_revision := (v_hold #>> '{quote,revision}')::integer;
  select revision into v_held_revision from public.sale_carts where id = '81330000-0000-4000-8000-000000000005';

  v_list := public.list_own_held_sale_carts('81330000-0000-4000-8000-000000000004', 1, 20);
  if (v_hold ->> 'held_count')::integer <> 1
    or (v_list ->> 'total')::integer <> 1
    or v_list #>> '{items,0,cart_id}' <> '81330000-0000-4000-8000-000000000005'
    or (select status from public.sale_carts where id = '81330000-0000-4000-8000-000000000005') <> 'held'
    or (select status from public.sale_carts where id = v_active_id) <> 'active'
    or not exists (select 1 from public.audit_log where action = 'sale_cart.held' and entity_id = '81330000-0000-4000-8000-000000000005') then
    raise exception 'La venta no se puso en espera de forma consistente: % / %', v_hold, v_list;
  end if;

  v_resume := public.resume_own_held_sale_cart(
    '81330000-0000-4000-8000-000000000005', v_held_revision,
    v_active_id, v_active_revision
  );
  if (v_resume ->> 'held_count')::integer <> 0
    or v_resume #>> '{quote,cart_id}' <> '81330000-0000-4000-8000-000000000005'
    or (select status from public.sale_carts where id = v_active_id) <> 'discarded'
    or (select status from public.sale_carts where id = '81330000-0000-4000-8000-000000000005') <> 'active'
    or not exists (select 1 from public.audit_log where action = 'sale_cart.resumed' and entity_id = '81330000-0000-4000-8000-000000000005') then
    raise exception 'La venta no se retomó de forma consistente: %', v_resume;
  end if;

  -- Suspender de nuevo permite comprobar el descarte específico de una venta en espera.
  v_hold := public.hold_own_sale_cart(
    '81330000-0000-4000-8000-000000000005',
    (v_resume #>> '{quote,revision}')::integer
  );
  select revision into v_held_revision from public.sale_carts where id = '81330000-0000-4000-8000-000000000005';
  perform public.discard_own_held_sale_cart('81330000-0000-4000-8000-000000000005', v_held_revision);
  if (select status from public.sale_carts where id = '81330000-0000-4000-8000-000000000005') <> 'discarded'
    or not exists (select 1 from public.audit_log where action = 'sale_cart.held_discarded' and entity_id = '81330000-0000-4000-8000-000000000005') then
    raise exception 'La venta en espera no se descartó con auditoría.';
  end if;
end;
$assertions$;

set local role postgres;
do $close_guard$
declare
  v_blocked boolean := false;
begin
  -- Crear una venta en espera adicional permite comprobar el trigger con el
  -- propietario de la tabla; las operaciones normales siguen pasando por RPC.
  update public.sale_carts
  set status = 'held', held_at = now()
  where id = (
    select id from public.sale_carts
    where cash_session_id = '81330000-0000-4000-8000-000000000004' and status = 'active'
    limit 1
  );
  begin
    update public.cash_sessions set status = 'closed'
    where id = '81330000-0000-4000-8000-000000000004';
  exception when others then
    v_blocked := position('venta(s) en espera' in sqlerrm) > 0;
  end;
  if not v_blocked then raise exception 'El cierre de caja no bloqueó ventas en espera.'; end if;
end;
$close_guard$;

rollback;
