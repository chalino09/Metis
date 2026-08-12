-- Prueba transaccional de retiro de descuento y descarte de carrito.
-- Reutiliza cualquier Super Admin local y revierte todas las fixtures.
begin;

do $fixtures$
declare
  v_actor_id uuid;
  v_role_id uuid;
begin
  select role_data.id into v_role_id
  from public.roles role_data
  where role_data.code = 'super_admin';

  select assignment.user_id into v_actor_id
  from public.user_roles assignment
  join public.roles role_data on role_data.id = assignment.role_id
  where role_data.code = 'super_admin'
  limit 1;
  if v_actor_id is null then
    v_actor_id := '81130000-0000-4000-8000-000000000000';
    insert into auth.users(id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (v_actor_id, 'authenticated', 'authenticated', 'pos-cart-reset@example.invalid', '{}'::jsonb, '{}'::jsonb, now(), now());
  end if;
  perform set_config('app.pos_cart_reset_actor', v_actor_id::text, true);

  insert into public.companies(id, legal_name, display_name)
  values ('81130000-0000-4000-8000-000000000001', 'Empresa temporal POS', 'Empresa temporal POS');
  insert into public.locations(id, company_id, external_code, name, location_type, classification_source)
  values ('81130000-0000-4000-8000-000000000002', '81130000-0000-4000-8000-000000000001', 'SUC-RESET', 'Sucursal temporal', 'sucursal', 'manual_review');
  insert into public.cash_registers(id, company_id, location_id, code, display_name, currency_code)
  values ('81130000-0000-4000-8000-000000000003', '81130000-0000-4000-8000-000000000001', '81130000-0000-4000-8000-000000000002', 'CAJA-RESET', 'Caja temporal', 'MXN');
  insert into public.cash_sessions(id, company_id, location_id, cash_register_id, opened_by, status, opening_amount)
  values ('81130000-0000-4000-8000-000000000004', '81130000-0000-4000-8000-000000000001', '81130000-0000-4000-8000-000000000002', '81130000-0000-4000-8000-000000000003', v_actor_id, 'open', 0);
  insert into public.sale_carts(id, company_id, location_id, cash_register_id, cash_session_id, cashier_id, sale_discount_percent, sale_discount_reason, sale_discount_status)
  values ('81130000-0000-4000-8000-000000000005', '81130000-0000-4000-8000-000000000001', '81130000-0000-4000-8000-000000000002', '81130000-0000-4000-8000-000000000003', '81130000-0000-4000-8000-000000000004', v_actor_id, 10, 'Prueba', 'pending');
  insert into public.discount_approvals(id, company_id, cart_id, scope, requested_percent, requester_id, requested_reason)
  values ('81130000-0000-4000-8000-000000000006', '81130000-0000-4000-8000-000000000001', '81130000-0000-4000-8000-000000000005', 'sale', 10, v_actor_id, 'Prueba');
  insert into public.user_roles(user_id, company_id, role_id)
  values (v_actor_id, '81130000-0000-4000-8000-000000000001', v_role_id)
  on conflict do nothing;
end;
$fixtures$;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', current_setting('app.pos_cart_reset_actor', true), true);

do $assertions$
declare
  v_quote jsonb;
  v_empty_quote jsonb;
begin
  v_quote := public.cancel_own_cart_discount('81130000-0000-4000-8000-000000000005', 1);
  if (v_quote ->> 'discount_amount')::numeric <> 0
    or coalesce((v_quote ->> 'pending_discount_approval')::boolean, false)
    or (select status from public.discount_approvals where id = '81130000-0000-4000-8000-000000000006') <> 'cancelled'
    or not exists (
      select 1 from public.audit_log
      where company_id = '81130000-0000-4000-8000-000000000001'
        and action = 'discount.cancelled'
    ) then
    raise exception 'El descuento no se retiró de forma auditada: %', v_quote;
  end if;

  v_empty_quote := public.discard_own_sale_cart('81130000-0000-4000-8000-000000000005', 2);
  if (select status from public.sale_carts where id = '81130000-0000-4000-8000-000000000005') <> 'discarded'
    or v_empty_quote ->> 'cart_id' = '81130000-0000-4000-8000-000000000005'
    or jsonb_array_length(v_empty_quote -> 'items') <> 0
    or not exists (
      select 1 from public.audit_log
      where company_id = '81130000-0000-4000-8000-000000000001'
        and action = 'sale_cart.discarded'
    ) then
    raise exception 'El carrito no se descartó de forma auditada: %', v_empty_quote;
  end if;
end;
$assertions$;

rollback;
