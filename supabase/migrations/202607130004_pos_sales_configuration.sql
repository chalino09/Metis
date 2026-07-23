-- Satrapy · Module 2 configuration and controlled cash movement RPCs.

create or replace function public.upsert_payment_method(
  p_company_id uuid,
  p_payment_method_id uuid default null,
  p_code text default null,
  p_display_name text default null,
  p_settlement_kind text default null,
  p_is_active boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_payment_methods') then raise exception 'No autorizado para configurar medios de pago.'; end if;
  if nullif(trim(coalesce(p_code, '')), '') is null or nullif(trim(coalesce(p_display_name, '')), '') is null or p_settlement_kind not in ('cash_drawer','external') then raise exception 'Configuración de medio de pago inválida.'; end if;
  if p_payment_method_id is null then
    insert into public.payment_methods(company_id, code, display_name, settlement_kind, is_active) values (p_company_id, upper(trim(p_code)), trim(p_display_name), p_settlement_kind, coalesce(p_is_active, true)) returning id into v_id;
  else
    update public.payment_methods set code = upper(trim(p_code)), display_name = trim(p_display_name), settlement_kind = p_settlement_kind, is_active = coalesce(p_is_active, true) where id = p_payment_method_id and company_id = p_company_id returning id into v_id;
    if v_id is null then raise exception 'Medio de pago no encontrado.'; end if;
  end if;
  perform public.write_sales_audit(p_company_id, 'payment_method.configured', 'payment_methods', v_id, jsonb_build_object('code', upper(trim(p_code)), 'settlement_kind', p_settlement_kind, 'is_active', coalesce(p_is_active, true)));
  return v_id;
end $$;

create or replace function public.upsert_cash_register(
  p_company_id uuid,
  p_cash_register_id uuid default null,
  p_location_id uuid default null,
  p_code text default null,
  p_display_name text default null,
  p_currency_code text default 'MXN',
  p_is_active boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_locations') then raise exception 'No autorizado para configurar cajas.'; end if;
  if p_location_id is null or not exists (select 1 from public.locations where id = p_location_id and company_id = p_company_id and is_active) then raise exception 'Ubicación de caja inválida.'; end if;
  if nullif(trim(coalesce(p_code, '')), '') is null or nullif(trim(coalesce(p_display_name, '')), '') is null or length(trim(coalesce(p_currency_code, ''))) <> 3 then raise exception 'Configuración de caja inválida.'; end if;
  if p_cash_register_id is null then
    insert into public.cash_registers(company_id, location_id, code, display_name, currency_code, is_active) values (p_company_id, p_location_id, upper(trim(p_code)), trim(p_display_name), upper(trim(p_currency_code)), coalesce(p_is_active, true)) returning id into v_id;
  else
    if exists (select 1 from public.cash_sessions where cash_register_id = p_cash_register_id and status in ('open','pending_variance_approval')) then raise exception 'No se puede reconfigurar una caja con sesión pendiente.'; end if;
    update public.cash_registers set location_id = p_location_id, code = upper(trim(p_code)), display_name = trim(p_display_name), currency_code = upper(trim(p_currency_code)), is_active = coalesce(p_is_active, true) where id = p_cash_register_id and company_id = p_company_id returning id into v_id;
    if v_id is null then raise exception 'Caja no encontrada.'; end if;
  end if;
  perform public.write_sales_audit(p_company_id, 'cash_register.configured', 'cash_registers', v_id, jsonb_build_object('location_id', p_location_id, 'code', upper(trim(p_code))));
  return v_id;
end $$;

create or replace function public.upsert_cash_denomination(
  p_company_id uuid,
  p_denomination_id uuid default null,
  p_currency_code text default 'MXN',
  p_value numeric default null,
  p_display_name text default null,
  p_is_active boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_payment_methods') then raise exception 'No autorizado para configurar denominaciones.'; end if;
  if coalesce(p_value, 0) <= 0 or length(trim(coalesce(p_currency_code, ''))) <> 3 or nullif(trim(coalesce(p_display_name, '')), '') is null then raise exception 'Denominación inválida.'; end if;
  if p_denomination_id is null then
    insert into public.cash_denominations(company_id, currency_code, value, display_name, is_active) values (p_company_id, upper(trim(p_currency_code)), round(p_value, 2), trim(p_display_name), coalesce(p_is_active, true)) returning id into v_id;
  else
    update public.cash_denominations set currency_code = upper(trim(p_currency_code)), value = round(p_value, 2), display_name = trim(p_display_name), is_active = coalesce(p_is_active, true) where id = p_denomination_id and company_id = p_company_id returning id into v_id;
    if v_id is null then raise exception 'Denominación no encontrada.'; end if;
  end if;
  perform public.write_sales_audit(p_company_id, 'cash_denomination.configured', 'cash_denominations', v_id, jsonb_build_object('value', round(p_value, 2), 'currency_code', upper(trim(p_currency_code))));
  return v_id;
end $$;

create or replace function public.upsert_discount_role_limit(
  p_company_id uuid,
  p_role_id uuid,
  p_scope text,
  p_max_percent numeric,
  p_valid_from timestamptz default null,
  p_valid_to timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_discount_policies') then raise exception 'No autorizado para configurar descuentos.'; end if;
  if p_scope not in ('line','sale') or coalesce(p_max_percent, -1) < 0 or p_max_percent > 100 or not exists (select 1 from public.roles where id = p_role_id) then raise exception 'Límite de descuento inválido.'; end if;
  insert into public.discount_role_limits(company_id, role_id, scope, max_percent, valid_from, valid_to)
  values (p_company_id, p_role_id, p_scope, p_max_percent, coalesce(p_valid_from, now()), p_valid_to)
  returning id into v_id;
  perform public.write_sales_audit(p_company_id, 'discount_limit.created', 'discount_role_limits', v_id, jsonb_build_object('role_id', p_role_id, 'scope', p_scope, 'max_percent', p_max_percent));
  return v_id;
end $$;

create or replace function public.set_location_sale_price_list(
  p_company_id uuid,
  p_location_id uuid,
  p_price_list_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_prices') then raise exception 'No autorizado para asignar listas de precio.'; end if;
  if p_price_list_id is not null and not exists (select 1 from public.price_lists where id = p_price_list_id and company_id = p_company_id and is_active and status = 'active') then raise exception 'Lista de precio no disponible.'; end if;
  update public.locations set default_price_list_id = p_price_list_id where id = p_location_id and company_id = p_company_id;
  if not found then raise exception 'Ubicación no encontrada.'; end if;
  perform public.write_sales_audit(p_company_id, 'location.price_list_assigned', 'locations', p_location_id, jsonb_build_object('price_list_id', p_price_list_id));
end $$;

create or replace function public.record_cash_drawer_movement(
  p_cash_session_id uuid,
  p_movement_type text,
  p_amount numeric,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.cash_sessions%rowtype;
  v_id uuid;
begin
  if p_movement_type not in ('paid_in','paid_out') or coalesce(p_amount, 0) <= 0 or nullif(trim(coalesce(p_reason, '')), '') is null then raise exception 'Movimiento de caja inválido.'; end if;
  select * into v_session from public.cash_sessions where id = p_cash_session_id and status = 'open' and opened_by = auth.uid() for share;
  if not found then raise exception 'La sesión de caja no está disponible.'; end if;
  perform public.assert_pos_access(v_session.company_id, v_session.location_id, 'record_cash_movement');
  insert into public.cash_movements(company_id, cash_session_id, movement_type, amount, actor_id, reason)
  values (v_session.company_id, v_session.id, p_movement_type, case when p_movement_type = 'paid_out' then -round(p_amount, 2) else round(p_amount, 2) end, auth.uid(), trim(p_reason)) returning id into v_id;
  perform public.write_sales_audit(v_session.company_id, 'cash_movement.recorded', 'cash_movements', v_id, jsonb_build_object('movement_type', p_movement_type, 'amount', p_amount));
  return v_id;
end $$;

grant execute on function public.upsert_payment_method(uuid, uuid, text, text, text, boolean) to authenticated;
grant execute on function public.upsert_cash_register(uuid, uuid, uuid, text, text, text, boolean) to authenticated;
grant execute on function public.upsert_cash_denomination(uuid, uuid, text, numeric, text, boolean) to authenticated;
grant execute on function public.upsert_discount_role_limit(uuid, uuid, text, numeric, timestamptz, timestamptz) to authenticated;
grant execute on function public.set_location_sale_price_list(uuid, uuid, uuid) to authenticated;
grant execute on function public.record_cash_drawer_movement(uuid, text, numeric, text) to authenticated;
