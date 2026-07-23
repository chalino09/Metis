-- Satrapy · Module 2 hardening: session ownership, credit privacy and operational cash controls.
-- This migration is intentionally additive: installations that already ran 002-005 keep their history.

-- Do not silently rewrite historical commercial policy timelines.
do $$
begin
  if exists (
    select 1
    from public.discount_role_limits a
    join public.discount_role_limits b
      on a.id < b.id
     and a.company_id = b.company_id
     and a.role_id = b.role_id
     and a.scope = b.scope
     and tstzrange(a.valid_from, coalesce(a.valid_to, 'infinity'::timestamptz), '[)')
         && tstzrange(b.valid_from, coalesce(b.valid_to, 'infinity'::timestamptz), '[)')
  ) then
    raise exception 'Hay políticas de descuento históricas traslapadas. Corrige los registros conflictivos antes de instalar este refuerzo.';
  end if;
end $$;

create extension if not exists btree_gist with schema extensions;

create unique index if not exists cash_sessions_one_unfinished_user_idx
  on public.cash_sessions(company_id, opened_by)
  where status in ('open', 'pending_variance_approval');

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.discount_role_limits'::regclass
      and conname = 'discount_role_limits_no_overlap'
  ) then
    alter table public.discount_role_limits
      add constraint discount_role_limits_no_overlap
      exclude using gist (
        company_id with =,
        role_id with =,
        scope with =,
        tstzrange(valid_from, coalesce(valid_to, 'infinity'::timestamptz), '[)') with &&
      );
  end if;
end $$;

create or replace function public.assert_formal_cash_count(
  p_company_id uuid,
  p_currency_code text,
  p_count_lines jsonb
)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.cash_denominations
    where company_id = p_company_id and currency_code = p_currency_code and is_active
  ) then
    raise exception 'Configura denominaciones activas antes de abrir o cerrar caja.';
  end if;

  if exists (
    (select denomination.id
     from public.cash_denominations denomination
     where denomination.company_id = p_company_id and denomination.currency_code = p_currency_code and denomination.is_active
     except
     select input.denomination_id
     from jsonb_to_recordset(coalesce(p_count_lines, '[]'::jsonb)) as input(denomination_id uuid, quantity integer))
    union all
    (select input.denomination_id
     from jsonb_to_recordset(coalesce(p_count_lines, '[]'::jsonb)) as input(denomination_id uuid, quantity integer)
     except
     select denomination.id
     from public.cash_denominations denomination
     where denomination.company_id = p_company_id and denomination.currency_code = p_currency_code and denomination.is_active)
  ) then
    raise exception 'El conteo debe incluir exactamente todas las denominaciones activas, incluso con cantidad cero.';
  end if;
end $$;

create or replace function public.get_pos_context(p_company_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'use_pos') then
    raise exception 'No autorizado.';
  end if;
  return jsonb_build_object(
    'locations', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'code', l.external_code) order by l.name) from public.locations l where l.company_id = p_company_id and l.is_active and public.can_access_location(l.id)), '[]'::jsonb),
    'registers', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'location_id', r.location_id, 'name', r.display_name, 'code', r.code, 'currency_code', r.currency_code) order by r.display_name) from public.cash_registers r where r.company_id = p_company_id and r.is_active and public.can_access_location(r.location_id)), '[]'::jsonb),
    'payment_methods', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'code', m.code, 'name', m.display_name, 'settlement_kind', m.settlement_kind) order by m.display_name) from public.payment_methods m where m.company_id = p_company_id and m.is_active), '[]'::jsonb),
    'own_open_session', (
      select jsonb_build_object('id', s.id, 'cash_register_id', s.cash_register_id, 'location_id', s.location_id, 'status', s.status, 'opening_amount', s.opening_amount)
      from public.cash_sessions s
      where s.company_id = p_company_id and s.opened_by = auth.uid() and s.status in ('open', 'pending_variance_approval')
      order by s.opened_at desc limit 1
    )
  );
end $$;

create or replace function public.open_cash_session(
  p_company_id uuid,
  p_cash_register_id uuid,
  p_count_lines jsonb default '[]'::jsonb,
  p_client_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_register public.cash_registers%rowtype;
  v_existing public.cash_sessions%rowtype;
  v_session_id uuid;
  v_count_id uuid;
  v_total numeric;
  v_request_id uuid := coalesce(p_client_request_id, gen_random_uuid());
begin
  select * into v_existing from public.cash_sessions
  where company_id = p_company_id and opened_by = auth.uid() and open_request_id = v_request_id;
  if found then
    return jsonb_build_object('cash_session_id', v_existing.id, 'status', v_existing.status, 'opening_amount', v_existing.opening_amount, 'idempotent', true);
  end if;

  select * into v_register from public.cash_registers
  where id = p_cash_register_id and company_id = p_company_id and is_active;
  if not found then raise exception 'Caja no encontrada o inactiva.'; end if;
  perform public.assert_pos_access(p_company_id, v_register.location_id, 'open_cash_session');
  perform public.assert_formal_cash_count(p_company_id, v_register.currency_code, p_count_lines);
  v_total := public.cash_count_total(p_company_id, v_register.currency_code, p_count_lines);

  insert into public.cash_sessions(company_id, cash_register_id, location_id, opened_by, opening_amount, open_request_id)
  values (p_company_id, p_cash_register_id, v_register.location_id, auth.uid(), v_total, v_request_id)
  returning id into v_session_id;
  insert into public.cash_counts(cash_session_id, count_type, total_amount, counted_by)
  values (v_session_id, 'opening', v_total, auth.uid()) returning id into v_count_id;
  insert into public.cash_count_lines(cash_count_id, denomination_id, denomination_value, quantity)
  select v_count_id, d.id, d.value, input.quantity
  from jsonb_to_recordset(p_count_lines) as input(denomination_id uuid, quantity integer)
  join public.cash_denominations d on d.id = input.denomination_id;
  if v_total <> 0 then
    insert into public.cash_movements(company_id, cash_session_id, movement_type, amount, actor_id, reason, source_entity_type, source_entity_id)
    values (p_company_id, v_session_id, 'opening', v_total, auth.uid(), 'Apertura de caja', 'cash_counts', v_count_id);
  end if;
  perform public.write_sales_audit(p_company_id, 'cash_session.opened', 'cash_sessions', v_session_id, jsonb_build_object('cash_register_id', p_cash_register_id, 'opening_amount', v_total));
  return jsonb_build_object('cash_session_id', v_session_id, 'status', 'open', 'opening_amount', v_total, 'idempotent', false);
exception when unique_violation then
  select * into v_existing from public.cash_sessions
  where company_id = p_company_id and opened_by = auth.uid() and open_request_id = v_request_id;
  if found then
    return jsonb_build_object('cash_session_id', v_existing.id, 'status', v_existing.status, 'opening_amount', v_existing.opening_amount, 'idempotent', true);
  end if;
  if exists (select 1 from public.cash_sessions where company_id = p_company_id and opened_by = auth.uid() and status in ('open', 'pending_variance_approval')) then
    raise exception 'Ya tienes una sesión de caja sin finalizar.';
  end if;
  raise exception 'La caja ya está siendo utilizada por otra sesión.';
end $$;

-- PostgreSQL identifies a function by argument types, not argument names. Drop the
-- former signature so the public RPC parameter can safely change to cash_session_id.
drop function if exists public.get_or_create_sale_cart(uuid, uuid);

create function public.get_or_create_sale_cart(
  p_company_id uuid,
  p_cash_session_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_session public.cash_sessions%rowtype; v_cart public.sale_carts%rowtype;
begin
  if p_cash_session_id is null then raise exception 'Selecciona una sesión de caja propia para iniciar una venta.'; end if;
  select s.* into v_session
  from public.cash_sessions s join public.cash_registers r on r.id = s.cash_register_id
  where s.id = p_cash_session_id and s.company_id = p_company_id and s.opened_by = auth.uid() and s.status = 'open' and r.is_active
  for share;
  if not found then raise exception 'La sesión de caja propia no está disponible.'; end if;
  perform public.assert_pos_access(p_company_id, v_session.location_id, 'use_pos');
  select * into v_cart from public.sale_carts where cash_session_id = v_session.id and cashier_id = auth.uid() and status = 'active';
  if not found then
    insert into public.sale_carts(company_id, location_id, cash_register_id, cash_session_id, cashier_id)
    values (p_company_id, v_session.location_id, v_session.cash_register_id, v_session.id, auth.uid()) returning * into v_cart;
  end if;
  return jsonb_build_object('cart_id', v_cart.id, 'revision', v_cart.revision, 'location_id', v_cart.location_id, 'cash_session_id', v_cart.cash_session_id, 'customer_id', v_cart.customer_id);
end $$;

create or replace function public.search_sale_customers(
  p_company_id uuid, p_query text default null, p_page integer default 1, p_page_size integer default 30
)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_page integer := greatest(coalesce(p_page, 1), 1); v_size integer := least(greatest(coalesce(p_page_size, 30), 1), 100); v_query text := lower(trim(coalesce(p_query, ''))); v_total integer; v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'use_pos') then raise exception 'No autorizado.'; end if;
  with filtered as (select c.id, c.code, c.display_name, c.credit_enabled, c.price_list_id from public.customers c where c.company_id = p_company_id and c.is_active and (v_query = '' or lower(c.code) like '%' || v_query || '%' or lower(c.display_name) like '%' || v_query || '%' or lower(coalesce(c.tax_id, '')) like '%' || v_query || '%' or lower(coalesce(c.phone, '')) like '%' || v_query || '%')) select count(*) into v_total from filtered;
  with filtered as (select c.id, c.code, c.display_name, c.credit_enabled, c.price_list_id from public.customers c where c.company_id = p_company_id and c.is_active and (v_query = '' or lower(c.code) like '%' || v_query || '%' or lower(c.display_name) like '%' || v_query || '%' or lower(coalesce(c.tax_id, '')) like '%' || v_query || '%' or lower(coalesce(c.phone, '')) like '%' || v_query || '%')) select coalesce(jsonb_agg(jsonb_build_object('id', id, 'code', code, 'display_name', display_name, 'credit_enabled', credit_enabled, 'price_list_id', price_list_id) order by display_name), '[]'::jsonb) into v_items from (select * from filtered order by display_name limit v_size offset (v_page - 1) * v_size) p;
  return jsonb_build_object('items', v_items, 'total', coalesce(v_total, 0), 'page', v_page, 'page_size', v_size);
end $$;

create or replace function public.search_sale_customers_credit(
  p_company_id uuid, p_query text default null, p_page integer default 1, p_page_size integer default 30
)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_page integer := greatest(coalesce(p_page, 1), 1); v_size integer := least(greatest(coalesce(p_page_size, 30), 1), 100); v_query text := lower(trim(coalesce(p_query, ''))); v_total integer; v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_customer_credit') then raise exception 'No autorizado para consultar crédito de clientes.'; end if;
  with filtered as (select c.id, c.code, c.display_name, c.credit_enabled, c.price_list_id, c.credit_limit, c.credit_term_days, coalesce((select sum(r.outstanding_amount) from public.customer_receivables r where r.customer_id = c.id), 0) outstanding_amount from public.customers c where c.company_id = p_company_id and c.is_active and (v_query = '' or lower(c.code) like '%' || v_query || '%' or lower(c.display_name) like '%' || v_query || '%' or lower(coalesce(c.tax_id, '')) like '%' || v_query || '%' or lower(coalesce(c.phone, '')) like '%' || v_query || '%')) select count(*) into v_total from filtered;
  with filtered as (select c.id, c.code, c.display_name, c.credit_enabled, c.price_list_id, c.credit_limit, c.credit_term_days, coalesce((select sum(r.outstanding_amount) from public.customer_receivables r where r.customer_id = c.id), 0) outstanding_amount from public.customers c where c.company_id = p_company_id and c.is_active and (v_query = '' or lower(c.code) like '%' || v_query || '%' or lower(c.display_name) like '%' || v_query || '%' or lower(coalesce(c.tax_id, '')) like '%' || v_query || '%' or lower(coalesce(c.phone, '')) like '%' || v_query || '%')) select coalesce(jsonb_agg(jsonb_build_object('id', id, 'code', code, 'display_name', display_name, 'credit_enabled', credit_enabled, 'price_list_id', price_list_id, 'credit_limit', credit_limit, 'credit_term_days', credit_term_days, 'outstanding_amount', outstanding_amount, 'available_credit', greatest(credit_limit - outstanding_amount, 0)) order by display_name), '[]'::jsonb) into v_items from (select * from filtered order by display_name limit v_size offset (v_page - 1) * v_size) p;
  return jsonb_build_object('items', v_items, 'total', coalesce(v_total, 0), 'page', v_page, 'page_size', v_size);
end $$;

create or replace function public.list_customer_price_lists(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_customers') then raise exception 'No autorizado para administrar clientes.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'currency_code', p.currency_code) order by p.name) from public.price_lists p where p.company_id = p_company_id and p.is_active and p.status = 'active'), '[]'::jsonb);
end $$;

create or replace function public.upsert_sale_customer(
  p_company_id uuid, p_customer_id uuid default null, p_code text default null, p_display_name text default null, p_tax_id text default null, p_email text default null, p_phone text default null, p_price_list_id uuid default null, p_credit_enabled boolean default false, p_credit_limit numeric default 0, p_credit_term_days integer default 0
)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_customer_id uuid; v_can_manage_credit boolean;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_customers') then raise exception 'No autorizado para administrar clientes.'; end if;
  v_can_manage_credit := public.has_company_permission(p_company_id, 'view_customer_credit');
  if p_customer_id is null and coalesce(p_credit_enabled, false) and not v_can_manage_credit then raise exception 'No autorizado para configurar crédito de clientes.'; end if;
  if nullif(trim(coalesce(p_display_name, '')), '') is null then raise exception 'El nombre del cliente es obligatorio.'; end if;
  if p_price_list_id is not null and not exists (select 1 from public.price_lists p where p.id = p_price_list_id and p.company_id = p_company_id and p.is_active and p.status = 'active') then raise exception 'Lista de precio no disponible.'; end if;
  if p_credit_enabled and (coalesce(p_credit_limit, 0) <= 0 or coalesce(p_credit_term_days, 0) <= 0) then raise exception 'El crédito requiere límite y plazo mayores a cero.'; end if;
  if p_customer_id is null then
    insert into public.customers(company_id, code, display_name, tax_id, email, phone, price_list_id, credit_enabled, credit_limit, credit_term_days, created_by) values (p_company_id, coalesce(nullif(trim(p_code), ''), 'CLI-' || upper(substr(gen_random_uuid()::text, 1, 8))), trim(p_display_name), nullif(trim(p_tax_id), ''), nullif(trim(p_email), ''), nullif(trim(p_phone), ''), p_price_list_id, coalesce(p_credit_enabled, false), coalesce(p_credit_limit, 0), coalesce(p_credit_term_days, 0), auth.uid()) returning id into v_customer_id;
  else
    update public.customers set code = coalesce(nullif(trim(p_code), ''), code), display_name = trim(p_display_name), tax_id = nullif(trim(p_tax_id), ''), email = nullif(trim(p_email), ''), phone = nullif(trim(p_phone), ''), price_list_id = p_price_list_id, credit_enabled = case when v_can_manage_credit then coalesce(p_credit_enabled, false) else credit_enabled end, credit_limit = case when v_can_manage_credit then coalesce(p_credit_limit, 0) else credit_limit end, credit_term_days = case when v_can_manage_credit then coalesce(p_credit_term_days, 0) else credit_term_days end where id = p_customer_id and company_id = p_company_id returning id into v_customer_id;
    if v_customer_id is null then raise exception 'Cliente no encontrado.'; end if;
  end if;
  perform public.write_sales_audit(p_company_id, case when p_customer_id is null then 'customer.created' else 'customer.updated' end, 'customers', v_customer_id, jsonb_build_object('credit_enabled', coalesce(p_credit_enabled, false), 'price_list_id', p_price_list_id));
  return v_customer_id;
end $$;

create or replace function public.decide_cart_discount(p_discount_approval_id uuid, p_approve boolean, p_decision_reason text default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_approval public.discount_approvals%rowtype; v_cart public.sale_carts%rowtype; v_revision integer;
begin
  select * into v_approval from public.discount_approvals where id = p_discount_approval_id for update;
  if not found or v_approval.status <> 'pending' then raise exception 'Solicitud de descuento no disponible.'; end if;
  select * into v_cart from public.sale_carts where id = v_approval.cart_id for share;
  if auth.uid() = v_approval.requester_id or not public.has_company_permission(v_approval.company_id, 'approve_discount') then raise exception 'Se requiere un aprobador autorizado distinto al solicitante.'; end if;
  perform public.assert_pos_access(v_approval.company_id, v_cart.location_id, 'approve_discount');
  update public.discount_approvals set status = case when p_approve then 'approved' else 'rejected' end, decided_by = auth.uid(), decided_at = now(), decision_reason = nullif(trim(p_decision_reason), '') where id = v_approval.id;
  if v_approval.scope = 'sale' then update public.sale_carts set sale_discount_status = case when p_approve then 'approved' else 'none' end, sale_discount_percent = case when p_approve then sale_discount_percent else 0 end, sale_discount_approved_by = case when p_approve then auth.uid() else null end, sale_discount_approved_at = case when p_approve then now() else null end, revision = revision + 1 where id = v_approval.cart_id returning revision into v_revision;
  else update public.sale_cart_items set discount_status = case when p_approve then 'approved' else 'none' end, discount_percent = case when p_approve then discount_percent else 0 end, discount_approved_by = case when p_approve then auth.uid() else null end, discount_approved_at = case when p_approve then now() else null end where id = v_approval.cart_item_id; update public.sale_carts set revision = revision + 1 where id = v_approval.cart_id returning revision into v_revision; end if;
  perform public.write_sales_audit(v_approval.company_id, 'discount.' || case when p_approve then 'approved' else 'rejected' end, 'discount_approvals', v_approval.id, jsonb_build_object('cart_id', v_approval.cart_id));
  return jsonb_build_object('approval_id', v_approval.id, 'status', case when p_approve then 'approved' else 'rejected' end, 'revision', v_revision);
end $$;

create or replace function public.approve_cash_variance(p_cash_session_id uuid, p_approval_reason text default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_session public.cash_sessions%rowtype;
begin
  select * into v_session from public.cash_sessions where id = p_cash_session_id for update;
  if not found or v_session.status <> 'pending_variance_approval' then raise exception 'No hay una diferencia de caja pendiente.'; end if;
  if auth.uid() = v_session.close_requested_by or auth.uid() = v_session.opened_by or not public.has_company_permission(v_session.company_id, 'approve_cash_variance') then raise exception 'Se requiere un aprobador autorizado distinto al responsable del cierre.'; end if;
  perform public.assert_pos_access(v_session.company_id, v_session.location_id, 'approve_cash_variance');
  update public.cash_sessions set status = 'closed', closed_at = now(), variance_approved_by = auth.uid(), variance_approved_at = now(), variance_reason = coalesce(variance_reason, nullif(trim(p_approval_reason), '')) where id = v_session.id;
  perform public.write_sales_audit(v_session.company_id, 'cash_session.variance_approved', 'cash_sessions', v_session.id, jsonb_build_object('variance_amount', v_session.variance_amount));
  return jsonb_build_object('cash_session_id', v_session.id, 'status', 'closed', 'variance_amount', v_session.variance_amount);
end $$;

create or replace function public.record_receivable_payment(
  p_company_id uuid, p_customer_id uuid, p_payment_method_id uuid, p_amount numeric, p_cash_session_id uuid default null, p_client_request_id uuid default null
)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_customer public.customers%rowtype; v_method public.payment_methods%rowtype; v_session public.cash_sessions%rowtype; v_existing public.receivable_payments%rowtype; v_payment_id uuid; v_remaining numeric := round(coalesce(p_amount, 0), 2); v_total_open numeric; v_receivable record; v_applied numeric; v_request_id uuid := coalesce(p_client_request_id, gen_random_uuid());
begin
  if v_remaining <= 0 then raise exception 'El abono debe ser mayor a cero.'; end if;
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'record_receivable_payment') or not public.has_company_permission(p_company_id, 'view_customer_credit') then raise exception 'No autorizado para registrar abonos.'; end if;
  select * into v_existing from public.receivable_payments where company_id = p_company_id and client_request_id = v_request_id; if found then return jsonb_build_object('payment_id', v_existing.id, 'amount', v_existing.amount, 'idempotent', true); end if;
  select * into v_customer from public.customers where id = p_customer_id and company_id = p_company_id for update; if not found then raise exception 'Cliente no encontrado.'; end if;
  select * into v_method from public.payment_methods where id = p_payment_method_id and company_id = p_company_id and is_active; if not found then raise exception 'Forma de pago no disponible.'; end if;
  if v_method.settlement_kind = 'cash_drawer' then
    if p_cash_session_id is null then raise exception 'El abono en efectivo requiere una sesión de caja explícita.'; end if;
    select * into v_session from public.cash_sessions where id = p_cash_session_id and company_id = p_company_id and opened_by = auth.uid() and status = 'open' for share;
    if not found then raise exception 'La sesión de caja propia no está disponible.'; end if;
    perform public.assert_pos_access(p_company_id, v_session.location_id, 'record_receivable_payment');
  elsif p_cash_session_id is not null then raise exception 'Una forma de pago externa no debe afectar una caja.'; end if;
  select coalesce(sum(outstanding_amount), 0) into v_total_open from public.customer_receivables where customer_id = p_customer_id; if v_remaining > v_total_open then raise exception 'El abono excede el saldo abierto del cliente.'; end if;
  insert into public.receivable_payments(company_id, customer_id, payment_method_id, payment_method_code, settlement_kind, cash_session_id, amount, client_request_id, received_by) values (p_company_id, p_customer_id, v_method.id, v_method.code, v_method.settlement_kind, case when v_method.settlement_kind = 'cash_drawer' then v_session.id else null end, v_remaining, v_request_id, auth.uid()) returning id into v_payment_id;
  for v_receivable in select * from public.customer_receivables where customer_id = p_customer_id and outstanding_amount > 0 order by due_date, issued_at, id for update loop exit when v_remaining = 0; v_applied := least(v_remaining, v_receivable.outstanding_amount); update public.customer_receivables set outstanding_amount = outstanding_amount - v_applied where id = v_receivable.id; insert into public.receivable_payment_applications(receivable_payment_id, receivable_id, amount) values (v_payment_id, v_receivable.id, v_applied); v_remaining := v_remaining - v_applied; end loop;
  if v_method.settlement_kind = 'cash_drawer' then insert into public.cash_movements(company_id, cash_session_id, movement_type, amount, actor_id, source_entity_type, source_entity_id) values (p_company_id, v_session.id, 'receivable_payment', p_amount, auth.uid(), 'receivable_payments', v_payment_id); end if;
  perform public.write_sales_audit(p_company_id, 'receivable_payment.recorded', 'receivable_payments', v_payment_id, jsonb_build_object('customer_id', p_customer_id, 'amount', p_amount)); return jsonb_build_object('payment_id', v_payment_id, 'amount', p_amount, 'idempotent', false);
exception when unique_violation then select * into v_existing from public.receivable_payments where company_id = p_company_id and client_request_id = v_request_id; if found then return jsonb_build_object('payment_id', v_existing.id, 'amount', v_existing.amount, 'idempotent', true); end if; raise;
end $$;

create or replace function public.upsert_discount_role_limit(p_company_id uuid, p_role_id uuid, p_scope text, p_max_percent numeric, p_valid_from timestamptz default null, p_valid_to timestamptz default null)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_id uuid; v_from timestamptz := coalesce(p_valid_from, now()); v_to timestamptz := p_valid_to; v_next timestamptz;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_discount_policies') then raise exception 'No autorizado para configurar descuentos.'; end if;
  if p_scope not in ('line','sale') or coalesce(p_max_percent, -1) < 0 or p_max_percent > 100 or not exists (select 1 from public.roles where id = p_role_id) then raise exception 'Límite de descuento inválido.'; end if;
  perform pg_advisory_xact_lock(hashtext(p_company_id::text || p_role_id::text || p_scope));
  select min(valid_from) into v_next from public.discount_role_limits where company_id = p_company_id and role_id = p_role_id and scope = p_scope and valid_from > v_from;
  if v_next is not null and (v_to is null or v_to > v_next) then v_to := v_next; end if;
  if v_to is not null and v_to <= v_from then raise exception 'La vigencia final debe ser posterior al inicio.'; end if;
  update public.discount_role_limits set valid_to = v_from where company_id = p_company_id and role_id = p_role_id and scope = p_scope and valid_from < v_from and (valid_to is null or valid_to > v_from);
  insert into public.discount_role_limits(company_id, role_id, scope, max_percent, valid_from, valid_to) values (p_company_id, p_role_id, p_scope, p_max_percent, v_from, v_to) returning id into v_id;
  perform public.write_sales_audit(p_company_id, 'discount_limit.created', 'discount_role_limits', v_id, jsonb_build_object('role_id', p_role_id, 'scope', p_scope, 'max_percent', p_max_percent, 'valid_from', v_from, 'valid_to', v_to)); return v_id;
end $$;

create or replace function public.close_cash_session(p_cash_session_id uuid, p_count_lines jsonb default '[]'::jsonb, p_variance_reason text default null, p_client_request_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_session public.cash_sessions%rowtype; v_register public.cash_registers%rowtype; v_counted numeric; v_expected numeric; v_variance numeric; v_count_id uuid; v_request_id uuid := coalesce(p_client_request_id, gen_random_uuid());
begin
  select * into v_session from public.cash_sessions where id = p_cash_session_id for update; if not found then raise exception 'Sesión de caja no encontrada.'; end if;
  if v_session.close_request_id = v_request_id then return jsonb_build_object('cash_session_id', v_session.id, 'status', v_session.status, 'variance_amount', v_session.variance_amount, 'idempotent', true); end if;
  if v_session.status <> 'open' or v_session.opened_by <> auth.uid() then raise exception 'Solo el responsable puede cerrar una sesión de caja abierta.'; end if;
  perform public.assert_pos_access(v_session.company_id, v_session.location_id, 'close_own_cash_session'); select * into v_register from public.cash_registers where id = v_session.cash_register_id;
  perform public.assert_formal_cash_count(v_session.company_id, v_register.currency_code, p_count_lines); v_counted := public.cash_count_total(v_session.company_id, v_register.currency_code, p_count_lines);
  select coalesce(sum(amount), 0) into v_expected from public.cash_movements where cash_session_id = v_session.id; v_expected := round(v_expected, 2); v_variance := round(v_counted - v_expected, 2);
  if v_variance <> 0 and nullif(trim(coalesce(p_variance_reason, '')), '') is null then raise exception 'Toda diferencia de caja requiere un motivo.'; end if;
  insert into public.cash_counts(cash_session_id, count_type, total_amount, counted_by) values (v_session.id, 'closing', v_counted, auth.uid()) returning id into v_count_id;
  insert into public.cash_count_lines(cash_count_id, denomination_id, denomination_value, quantity) select v_count_id, d.id, d.value, input.quantity from jsonb_to_recordset(p_count_lines) as input(denomination_id uuid, quantity integer) join public.cash_denominations d on d.id = input.denomination_id;
  update public.cash_sessions set expected_closing_amount = v_expected, counted_closing_amount = v_counted, variance_amount = v_variance, close_requested_by = auth.uid(), variance_reason = nullif(trim(p_variance_reason), ''), close_request_id = v_request_id, status = case when v_variance = 0 then 'closed' else 'pending_variance_approval' end, closed_at = case when v_variance = 0 then now() else null end where id = v_session.id;
  perform public.write_sales_audit(v_session.company_id, case when v_variance = 0 then 'cash_session.closed' else 'cash_session.variance_pending' end, 'cash_sessions', v_session.id, jsonb_build_object('expected_amount', v_expected, 'counted_amount', v_counted, 'variance_amount', v_variance)); return jsonb_build_object('cash_session_id', v_session.id, 'status', case when v_variance = 0 then 'closed' else 'pending_variance_approval' end, 'expected_amount', v_expected, 'counted_amount', v_counted, 'variance_amount', v_variance);
end $$;

create or replace function public.list_pending_discount_approvals(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'approve_discount') then raise exception 'No autorizado.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'scope', a.scope, 'requested_percent', a.requested_percent, 'requested_reason', a.requested_reason, 'created_at', a.created_at, 'location_id', c.location_id) order by a.created_at) from public.discount_approvals a join public.sale_carts c on c.id = a.cart_id where a.company_id = p_company_id and a.status = 'pending' and a.requester_id <> auth.uid() and public.can_access_location(c.location_id)), '[]'::jsonb);
end $$;

create or replace function public.list_pending_cash_variances(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'approve_cash_variance') then raise exception 'No autorizado.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('cash_session_id', s.id, 'location_id', s.location_id, 'variance_amount', s.variance_amount, 'variance_reason', s.variance_reason, 'opened_at', s.opened_at) order by s.opened_at) from public.cash_sessions s where s.company_id = p_company_id and s.status = 'pending_variance_approval' and s.opened_by <> auth.uid() and s.close_requested_by <> auth.uid() and public.can_access_location(s.location_id)), '[]'::jsonb);
end $$;

create or replace function public.list_cash_session_movements(p_cash_session_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare v_session public.cash_sessions%rowtype;
begin
  select * into v_session from public.cash_sessions where id = p_cash_session_id; if not found then raise exception 'Sesión de caja no encontrada.'; end if;
  if not public.can_access_location(v_session.location_id) or (v_session.opened_by <> auth.uid() and not public.has_company_permission(v_session.company_id, 'view_cash_reports')) then raise exception 'No autorizado para consultar movimientos de caja.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'movement_type', m.movement_type, 'amount', m.amount, 'reason', m.reason, 'occurred_at', m.occurred_at) order by m.occurred_at desc) from public.cash_movements m where m.cash_session_id = p_cash_session_id), '[]'::jsonb);
end $$;

drop policy if exists discount_approvals_read on public.discount_approvals;
create policy discount_approvals_read on public.discount_approvals for select to authenticated using (
  exists (select 1 from public.sale_carts c where c.id = cart_id and public.can_access_location(c.location_id) and (requester_id = auth.uid() or public.has_company_permission(company_id, 'approve_discount')))
);

-- Credit fields are only emitted by the dedicated security-definer RPC. RLS cannot hide columns.
revoke select on public.customers from authenticated;

create or replace function public.enforce_credit_sale_visibility()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.sale_type = 'credit' and not public.has_company_permission(new.company_id, 'view_customer_credit') then
    raise exception 'No autorizado para consultar y usar crédito de clientes.';
  end if;
  return new;
end $$;

drop trigger if exists sales_credit_visibility on public.sales;
create trigger sales_credit_visibility before insert on public.sales
for each row execute function public.enforce_credit_sale_visibility();

revoke all on function public.assert_formal_cash_count(uuid, text, jsonb) from public;
revoke all on function public.enforce_credit_sale_visibility() from public;
grant execute on function public.get_pos_context(uuid), public.open_cash_session(uuid, uuid, jsonb, uuid), public.get_or_create_sale_cart(uuid, uuid), public.search_sale_customers(uuid, text, integer, integer), public.search_sale_customers_credit(uuid, text, integer, integer), public.list_customer_price_lists(uuid), public.upsert_sale_customer(uuid, uuid, text, text, text, text, text, uuid, boolean, numeric, integer), public.decide_cart_discount(uuid, boolean, text), public.approve_cash_variance(uuid, text), public.record_receivable_payment(uuid, uuid, uuid, numeric, uuid, uuid), public.upsert_discount_role_limit(uuid, uuid, text, numeric, timestamptz, timestamptz), public.close_cash_session(uuid, jsonb, text, uuid), public.list_pending_discount_approvals(uuid), public.list_pending_cash_variances(uuid), public.list_cash_session_movements(uuid) to authenticated;
