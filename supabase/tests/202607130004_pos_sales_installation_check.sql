-- Satrapy · Module 2 installation and security contract check.
-- Run after 202607130004. It mutates no business data.
begin;

do $test$
declare
  v_name text;
begin
  foreach v_name in array array[
    'customers', 'payment_methods', 'cash_registers', 'cash_sessions',
    'sale_carts', 'sales', 'sale_items', 'customer_receivables',
    'inventory_balances', 'inventory_ledger', 'canonical_tickets', 'ticket_print_outbox'
  ] loop
    if to_regclass('public.' || v_name) is null then
      raise exception 'Falta la tabla POS requerida: %', v_name;
    end if;
  end loop;

  foreach v_name in array array[
    'public.search_pos_sale_products(uuid,uuid,uuid,text,integer,integer,timestamp with time zone)',
    'public.search_sale_customers(uuid,text,integer,integer)',
    'public.open_cash_session(uuid,uuid,jsonb,uuid)',
    'public.get_or_create_sale_cart(uuid,uuid)',
    'public.change_sale_cart_item(uuid,uuid,numeric,integer)',
    'public.quote_sale_cart(uuid)',
    'public.complete_sale(uuid,integer,text,uuid,numeric,uuid)',
    'public.close_cash_session(uuid,jsonb,text,uuid)',
    'public.record_receivable_payment(uuid,uuid,uuid,numeric,uuid,uuid,text)',
    'public.get_canonical_ticket(uuid)'
  ] loop
    if to_regprocedure(v_name) is null then
      raise exception 'Falta la RPC POS requerida: %', v_name;
    end if;
  end loop;

  if has_table_privilege('authenticated', 'public.sales', 'insert')
    or has_table_privilege('authenticated', 'public.sale_items', 'update')
    or has_table_privilege('authenticated', 'public.inventory_ledger', 'insert')
    or has_table_privilege('authenticated', 'public.cash_movements', 'delete') then
    raise exception 'authenticated no debe mutar documentos críticos directamente.';
  end if;

  if not has_function_privilege('authenticated', 'public.complete_sale(uuid,integer,text,uuid,numeric,uuid)', 'execute')
    or not has_function_privilege('authenticated', 'public.close_cash_session(uuid,jsonb,text,uuid)', 'execute') then
    raise exception 'Faltan grants de ejecución para operaciones POS.';
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgrelid = 'public.canonical_tickets'::regclass
      and tgname = 'canonical_tickets_immutable'
      and not tgisinternal
  ) then
    raise exception 'El ticket canónico debe contar con protección de inmutabilidad.';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'sales' and policyname = 'sales_read'
  ) then
    raise exception 'Falta la política RLS de lectura para ventas.';
  end if;
end;
$test$;

rollback;
