-- Satrapy · CxC paginated customer search installation and behavior contract.
-- Requires an existing Super Admin. All fixtures are rolled back.
begin;

do $installation$
declare v_definition text;
begin
  if to_regprocedure('public.list_receivable_customers(uuid,text,integer,integer,text)') is null then
    raise exception 'Falta la RPC paginada de clientes con saldo.';
  end if;
  if not has_function_privilege('authenticated', 'public.list_receivable_customers(uuid,text,integer,integer,text)', 'execute') then
    raise exception 'authenticated no puede ejecutar la RPC paginada de CxC.';
  end if;
  if has_function_privilege('anon', 'public.list_receivable_customers(uuid,text,integer,integer,text)', 'execute') then
    raise exception 'anon no debe ejecutar la RPC paginada de CxC.';
  end if;
  select pg_get_functiondef('public.list_receivable_customers(uuid,text,integer,integer,text)'::regprocedure) into v_definition;
  if position('view_customer_credit' in v_definition) = 0 then
    raise exception 'La RPC paginada de CxC no exige el permiso financiero.';
  end if;
end;
$installation$;

do $fixtures$
declare
  v_actor_id uuid;
begin
  select role_assignment.user_id into v_actor_id
  from public.user_roles role_assignment
  join public.roles role_data on role_data.id = role_assignment.role_id
  where role_data.code = 'super_admin'
  limit 1;
  if v_actor_id is null then raise exception 'La prueba requiere un Super Admin existente.'; end if;
  perform set_config('app.receivable_pagination_test_actor', v_actor_id::text, true);

  insert into public.companies(id, legal_name, display_name)
  values ('1a000000-0000-4000-8000-000000000001', 'Empresa CxC temporal', 'Empresa CxC temporal');

  insert into public.customers(company_id, code, display_name, credit_enabled, credit_limit, credit_term_days, created_by)
  select
    '1a000000-0000-4000-8000-000000000001',
    'CXC-' || lpad(series::text, 3, '0'),
    'Cliente CxC ' || lpad(series::text, 3, '0'),
    true,
    1000,
    30,
    v_actor_id
  from generate_series(1, 126) series;

  insert into public.customer_receivables(
    company_id, customer_id, sale_id, due_date, original_amount, outstanding_amount,
    source_kind, source_document_key, source_row_hash, source_cutoff_date
  )
  select
    customer_data.company_id,
    customer_data.id,
    null,
    current_date,
    100,
    case when customer_data.code = 'CXC-126' then 0 else 100 end,
    'alpha_opening_balance',
    'test-' || customer_data.code,
    'hash-' || customer_data.code,
    current_date
  from public.customers customer_data
  where customer_data.company_id = '1a000000-0000-4000-8000-000000000001';
end;
$fixtures$;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', (
  select current_setting('app.receivable_pagination_test_actor', true)
), true);

do $assertions$
declare
  v_first jsonb;
  v_second jsonb;
  v_search jsonb;
begin
  v_first := public.list_receivable_customers('1a000000-0000-4000-8000-000000000001', null, 1, 100, 'largest_balance');
  v_second := public.list_receivable_customers('1a000000-0000-4000-8000-000000000001', null, 2, 100, 'largest_balance');
  v_search := public.list_receivable_customers('1a000000-0000-4000-8000-000000000001', 'CXC-125', 1, 50, 'largest_balance');

  if (v_first ->> 'total')::integer <> 125 or jsonb_array_length(v_first -> 'items') <> 100 then
    raise exception 'La primera página o el total de CxC son incorrectos: %', v_first;
  end if;
  if jsonb_array_length(v_second -> 'items') <> 25 then
    raise exception 'La segunda página de CxC no contiene los 25 clientes restantes: %', v_second;
  end if;
  if (v_second -> 'items' -> 24 ->> 'code') <> 'CXC-125' then
    raise exception 'El orden estable o el alcance de la segunda página es incorrecto: %', v_second;
  end if;
  if (v_search ->> 'total')::integer <> 1 or (v_search -> 'items' -> 0 ->> 'code') <> 'CXC-125' then
    raise exception 'La búsqueda server-side no encontró el cliente posterior a la primera página: %', v_search;
  end if;
end;
$assertions$;

reset role;
rollback;
