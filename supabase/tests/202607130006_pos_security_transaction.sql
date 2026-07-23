-- Satrapy · Module 2 transactional hardening regression.
-- Requires a Super Admin and runs entirely inside a rollback.
begin;

do $fixtures$
declare v_actor_id uuid;
begin
  select ur.user_id into v_actor_id from public.user_roles ur join public.roles r on r.id = ur.role_id where r.code = 'super_admin' limit 1;
  if v_actor_id is null then raise exception 'La prueba requiere un Super Admin existente.'; end if;
  perform set_config('app.pos_test_actor', v_actor_id::text, true);
  insert into public.companies(id, legal_name, display_name) values ('16000000-0000-4000-8000-000000000001', 'Empresa seguridad POS', 'Empresa seguridad POS');
  insert into public.locations(id, company_id, external_code, name, location_type, classification_source) values ('16000000-0000-4000-8000-000000000002', '16000000-0000-4000-8000-000000000001', 'SEG-TEST', 'Sucursal seguridad', 'sucursal', 'manual_review');
  insert into public.user_roles(user_id, role_id, company_id)
  select v_actor_id, id, '16000000-0000-4000-8000-000000000001' from public.roles where code = 'super_admin'
  on conflict do nothing;
  insert into public.user_location_access(user_id, location_id)
  values (v_actor_id, '16000000-0000-4000-8000-000000000002')
  on conflict do nothing;
  insert into public.cash_registers(id, company_id, location_id, code, display_name, currency_code) values
    ('16000000-0000-4000-8000-000000000003', '16000000-0000-4000-8000-000000000001', '16000000-0000-4000-8000-000000000002', 'SEG-01', 'Caja seguridad 1', 'MXN'),
    ('16000000-0000-4000-8000-000000000004', '16000000-0000-4000-8000-000000000001', '16000000-0000-4000-8000-000000000002', 'SEG-02', 'Caja seguridad 2', 'MXN');
  insert into public.cash_denominations(id, company_id, currency_code, value, display_name) values ('16000000-0000-4000-8000-000000000005', '16000000-0000-4000-8000-000000000001', 'MXN', 100, '$100');
  insert into public.customers(id, company_id, code, display_name, credit_enabled, credit_limit, credit_term_days, created_by) values ('16000000-0000-4000-8000-000000000006', '16000000-0000-4000-8000-000000000001', 'SEG-CLI', 'Cliente seguridad', true, 1000, 30, v_actor_id);
end;
$fixtures$;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', current_setting('app.pos_test_actor', true), true);

do $assertions$
declare v_session jsonb; v_retry jsonb; v_context jsonb; v_customers jsonb; v_cart jsonb;
begin
  v_session := public.open_cash_session('16000000-0000-4000-8000-000000000001', '16000000-0000-4000-8000-000000000003', jsonb_build_array(jsonb_build_object('denomination_id', '16000000-0000-4000-8000-000000000005'::uuid, 'quantity', 0)), '16000000-0000-4000-8000-000000000007');
  v_retry := public.open_cash_session('16000000-0000-4000-8000-000000000001', '16000000-0000-4000-8000-000000000003', jsonb_build_array(jsonb_build_object('denomination_id', '16000000-0000-4000-8000-000000000005'::uuid, 'quantity', 0)), '16000000-0000-4000-8000-000000000007');
  if v_session ->> 'cash_session_id' <> v_retry ->> 'cash_session_id' or not coalesce((v_retry ->> 'idempotent')::boolean, false) then raise exception 'La apertura idempotente no devolvió la propia sesión.'; end if;
  begin
    perform public.open_cash_session('16000000-0000-4000-8000-000000000001', '16000000-0000-4000-8000-000000000004', jsonb_build_array(jsonb_build_object('denomination_id', '16000000-0000-4000-8000-000000000005'::uuid, 'quantity', 0)), '16000000-0000-4000-8000-000000000008');
    raise exception 'Se permitió una segunda sesión activa al mismo usuario.';
  exception when others then if position('Ya tienes una sesión' in sqlerrm) = 0 then raise; end if;
  end;
  begin
    perform public.close_cash_session((v_session ->> 'cash_session_id')::uuid, '[]'::jsonb, null, '16000000-0000-4000-8000-000000000009');
    raise exception 'Se permitió un arqueo sin todas las denominaciones.';
  exception when others then if position('exactamente todas las denominaciones' in sqlerrm) = 0 then raise; end if;
  end;
  v_context := public.get_pos_context('16000000-0000-4000-8000-000000000001');
  if not (v_context ? 'own_open_session') or v_context ? 'sessions' then raise exception 'El contexto POS no está limitado a la sesión propia.'; end if;
  v_cart := public.get_or_create_sale_cart('16000000-0000-4000-8000-000000000001', (v_session ->> 'cash_session_id')::uuid);
  if v_cart ->> 'cash_session_id' <> v_session ->> 'cash_session_id' then raise exception 'El carrito no conservó la sesión explícita.'; end if;
  begin
    perform public.get_or_create_sale_cart('16000000-0000-4000-8000-000000000001', '16000000-0000-4000-8000-000000000004');
    raise exception 'Se aceptó una sesión de caja ajena o inexistente.';
  exception when others then if position('sesión de caja propia' in sqlerrm) = 0 then raise; end if;
  end;
  v_customers := public.search_sale_customers('16000000-0000-4000-8000-000000000001', 'SEG', 1, 10);
  if (v_customers -> 'items' -> 0) ? 'available_credit' or (v_customers -> 'items' -> 0) ? 'credit_limit' then raise exception 'La búsqueda básica filtró datos financieros.'; end if;
end;
$assertions$;

reset role;
rollback;
