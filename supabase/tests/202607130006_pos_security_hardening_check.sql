-- Satrapy · Module 2 security and operation hardening contract.
-- Run after migration 202607130006. It makes no business changes.
begin;

do $test$
declare v_definition text;
begin
  if not exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'cash_sessions_one_unfinished_user_idx') then
    raise exception 'Falta la restricción de una sesión no finalizada por usuario.';
  end if;

  if not exists (select 1 from pg_constraint where conrelid = 'public.discount_role_limits'::regclass and conname = 'discount_role_limits_no_overlap' and contype = 'x') then
    raise exception 'Falta la exclusión de vigencias traslapadas de descuentos.';
  end if;

  foreach v_definition in array array[
    'public.search_sale_customers_credit(uuid,text,integer,integer)',
    'public.list_customer_price_lists(uuid)',
    'public.list_pending_discount_approvals(uuid)',
    'public.list_pending_cash_variances(uuid)',
    'public.list_cash_session_movements(uuid)'
  ] loop
    if to_regprocedure(v_definition) is null then raise exception 'Falta la RPC de seguridad/operación: %', v_definition; end if;
  end loop;

  if has_table_privilege('authenticated', 'public.customers', 'select') then
    raise exception 'authenticated no debe leer directamente datos de clientes con campos financieros.';
  end if;

  if not has_function_privilege('authenticated', 'public.get_or_create_sale_cart(uuid,uuid)', 'execute')
    or not has_function_privilege('authenticated', 'public.search_sale_customers_credit(uuid,text,integer,integer)', 'execute') then
    raise exception 'Faltan grants de las RPCs endurecidas.';
  end if;

  if not exists (select 1 from pg_trigger where tgrelid = 'public.sales'::regclass and tgname = 'sales_credit_visibility' and not tgisinternal) then
    raise exception 'Falta la protección de visibilidad para ventas a crédito.';
  end if;

  select pg_get_functiondef('public.open_cash_session(uuid,uuid,jsonb,uuid)'::regprocedure) into v_definition;
  if position('opened_by = auth.uid() and open_request_id' in v_definition) = 0 or position('assert_formal_cash_count' in v_definition) = 0 then
    raise exception 'La apertura no tiene idempotencia propia y conteo formal.';
  end if;

  select pg_get_functiondef('public.get_or_create_sale_cart(uuid,uuid)'::regprocedure) into v_definition;
  if position('p_cash_session_id' in v_definition) = 0 or position('opened_by = auth.uid()' in v_definition) = 0 then
    raise exception 'El carrito no exige una sesión propia explícita.';
  end if;
end;
$test$;

rollback;
