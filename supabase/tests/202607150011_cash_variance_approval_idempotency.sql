-- Cash variance approval UAT: response idempotency and location-scoped approval.
-- All fixtures and mutations are rolled back.
begin;

insert into auth.users(
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('15110000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cashier-1511@example.invalid', '', now(), '{"provider":"email","providers":["email"]}', '{}', now(), now()),
  ('15110000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'supervisor-a-1511@example.invalid', '', now(), '{"provider":"email","providers":["email"]}', '{}', now(), now()),
  ('15110000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'supervisor-b-1511@example.invalid', '', now(), '{"provider":"email","providers":["email"]}', '{}', now(), now());

insert into public.companies(id, legal_name, display_name)
values ('15110000-0000-4000-8000-000000000010', 'Empresa UAT caja 1511', 'Empresa UAT caja 1511');

insert into public.locations(id, company_id, external_code, name, location_type, classification_source)
values
  ('15110000-0000-4000-8000-000000000011', '15110000-0000-4000-8000-000000000010', 'UAT-A', 'Sucursal UAT A', 'sucursal', 'manual_review'),
  ('15110000-0000-4000-8000-000000000012', '15110000-0000-4000-8000-000000000010', 'UAT-B', 'Sucursal UAT B', 'sucursal', 'manual_review');

insert into public.user_roles(user_id, role_id, company_id)
select fixture.user_id, r.id, '15110000-0000-4000-8000-000000000010'
from (values
  ('15110000-0000-4000-8000-000000000001'::uuid, 'punto_venta'::text),
  ('15110000-0000-4000-8000-000000000002'::uuid, 'direccion_admin'::text),
  ('15110000-0000-4000-8000-000000000003'::uuid, 'direccion_admin'::text)
) fixture(user_id, role_code)
join public.roles r on r.code = fixture.role_code;

insert into public.user_location_access(user_id, location_id)
values
  ('15110000-0000-4000-8000-000000000001', '15110000-0000-4000-8000-000000000011'),
  ('15110000-0000-4000-8000-000000000002', '15110000-0000-4000-8000-000000000011'),
  ('15110000-0000-4000-8000-000000000003', '15110000-0000-4000-8000-000000000012');

insert into public.cash_registers(id, company_id, location_id, code, display_name, currency_code)
values
  ('15110000-0000-4000-8000-000000000020', '15110000-0000-4000-8000-000000000010', '15110000-0000-4000-8000-000000000011', 'UAT-A-01', 'Caja UAT A', 'MXN'),
  ('15110000-0000-4000-8000-000000000021', '15110000-0000-4000-8000-000000000010', '15110000-0000-4000-8000-000000000012', 'UAT-B-01', 'Caja UAT B', 'MXN'),
  ('15110000-0000-4000-8000-000000000022', '15110000-0000-4000-8000-000000000010', '15110000-0000-4000-8000-000000000011', 'UAT-A-02', 'Caja UAT A 2', 'MXN');

insert into public.cash_sessions(
  id, company_id, cash_register_id, location_id, opened_by, status,
  opening_amount, expected_closing_amount, counted_closing_amount,
  variance_amount, close_requested_by, variance_reason
) values
  ('15110000-0000-4000-8000-000000000030', '15110000-0000-4000-8000-000000000010', '15110000-0000-4000-8000-000000000020', '15110000-0000-4000-8000-000000000011', '15110000-0000-4000-8000-000000000001', 'pending_variance_approval', 0, 10, 9, -1, '15110000-0000-4000-8000-000000000001', 'UAT idempotencia'),
  ('15110000-0000-4000-8000-000000000031', '15110000-0000-4000-8000-000000000010', '15110000-0000-4000-8000-000000000022', '15110000-0000-4000-8000-000000000011', '15110000-0000-4000-8000-000000000002', 'pending_variance_approval', 0, 10, 9, -1, '15110000-0000-4000-8000-000000000002', 'UAT otra sucursal'),
  ('15110000-0000-4000-8000-000000000032', '15110000-0000-4000-8000-000000000010', '15110000-0000-4000-8000-000000000021', '15110000-0000-4000-8000-000000000012', '15110000-0000-4000-8000-000000000003', 'pending_variance_approval', 0, 10, 9, -1, '15110000-0000-4000-8000-000000000003', 'UAT mismo cajero');

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '15110000-0000-4000-8000-000000000002', true);

do $test$
declare
  v_first jsonb;
  v_retry jsonb;
  v_pending jsonb;
begin
  v_pending := public.get_pos_context('15110000-0000-4000-8000-000000000010');
  if jsonb_array_length(v_pending -> 'locations') <> 2 then
    raise exception 'Dirección no puede cargar el contexto completo de caja.';
  end if;

  v_pending := public.list_pending_cash_variances('15110000-0000-4000-8000-000000000010');
  if jsonb_array_length(v_pending) <> 2
    or not (v_pending @> '[{"cash_session_id":"15110000-0000-4000-8000-000000000030"}]'::jsonb) then
    raise exception 'Dirección no ve todas las diferencias pendientes.';
  end if;

  v_first := public.approve_cash_variance(
    '15110000-0000-4000-8000-000000000030',
    null,
    '15110000-0000-4000-8000-000000000040'
  );
  v_retry := public.approve_cash_variance(
    '15110000-0000-4000-8000-000000000030',
    null,
    '15110000-0000-4000-8000-000000000040'
  );

  if v_first ->> 'cash_session_id' <> v_retry ->> 'cash_session_id'
    or v_retry ->> 'status' <> 'closed'
    or not coalesce((v_retry ->> 'idempotent')::boolean, false) then
    raise exception 'El reintento no devolvió el mismo cierre aprobado.';
  end if;

end;
$test$;

reset role;

do $test$
begin
  if (select count(*) from public.audit_log where entity_id = '15110000-0000-4000-8000-000000000030' and action = 'cash_session.variance_approved') <> 1 then
    raise exception 'La aprobación idempotente no dejó exactamente un evento de auditoría.';
  end if;
end;
$test$;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '15110000-0000-4000-8000-000000000003', true);

do $test$
begin
  perform public.approve_cash_variance(
    '15110000-0000-4000-8000-000000000031',
    'Aprobación central de Dirección',
    '15110000-0000-4000-8000-000000000042'
  );

  begin
    perform public.approve_cash_variance(
      '15110000-0000-4000-8000-000000000032',
      null,
      '15110000-0000-4000-8000-000000000041'
    );
    raise exception 'El mismo cajero pudo aprobar su propia diferencia.';
  exception when others then
    if position('aprobador autorizado distinto' in sqlerrm) = 0 then raise; end if;
  end;
end;
$test$;

reset role;
rollback;
