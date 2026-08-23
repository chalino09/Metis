-- Satrapy · Reserva transaccional de inventario para pedidos de venta.
-- El pedido asegura el surtido antes de aceptar pagos. La entrega consume la reserva.

begin;

alter table public.inventory_balances
  add column if not exists quantity_reserved numeric(18,6) not null default 0;

alter table public.inventory_balances
  drop constraint if exists inventory_balances_quantity_reserved_check;
alter table public.inventory_balances
  add constraint inventory_balances_quantity_reserved_check
  check (quantity_reserved >= 0 and quantity_reserved <= quantity_on_hand);

alter table public.sales_deposit_orders
  add column if not exists inventory_reservation_status text not null default 'pending',
  add column if not exists inventory_reservation_checked_at timestamptz,
  add column if not exists inventory_reservation_message text,
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid references auth.users(id) on delete set null,
  add column if not exists cancellation_reason text;

alter table public.sales_deposit_orders drop constraint if exists sales_deposit_orders_status_check;
alter table public.sales_deposit_orders drop constraint if exists sales_deposit_orders_check;
alter table public.sales_deposit_orders
  add constraint sales_deposit_orders_status_check check (status in ('open', 'completed', 'cancelled')),
  add constraint sales_deposit_orders_lifecycle_check check (
    (status = 'open' and sale_id is null and completed_at is null and cancelled_at is null)
    or (status = 'completed' and sale_id is not null and completed_at is not null and cancelled_at is null and paid_amount = total_amount)
    or (status = 'cancelled' and sale_id is null and completed_at is null and cancelled_at is not null)
  );

alter table public.sales_deposit_orders
  drop constraint if exists sales_deposit_orders_inventory_reservation_status_check;
alter table public.sales_deposit_orders
  add constraint sales_deposit_orders_inventory_reservation_status_check
  check (inventory_reservation_status in ('pending', 'reserved', 'blocked', 'consumed', 'released'));

update public.sales_deposit_orders
set inventory_reservation_status = case when status = 'completed' then 'consumed' else 'blocked' end,
    inventory_reservation_checked_at = now(),
    inventory_reservation_message = case when status = 'completed' then null else 'Pedido creado antes de habilitar reservas; revalida el surtido.' end
where inventory_reservation_status = 'pending';

create table if not exists public.sales_order_inventory_reservations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  order_id uuid not null references public.sales_deposit_orders(id) on delete restrict,
  location_id uuid not null references public.locations(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity numeric(18,6) not null check (quantity > 0),
  status text not null default 'active' check (status in ('active', 'released', 'consumed')),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create unique index if not exists sales_order_inventory_reservations_active_idx
  on public.sales_order_inventory_reservations(order_id, product_id) where status = 'active';
create index if not exists sales_order_inventory_reservations_balance_idx
  on public.sales_order_inventory_reservations(location_id, product_id, status);

alter table public.sales_order_inventory_reservations enable row level security;
drop policy if exists sales_order_inventory_reservations_read on public.sales_order_inventory_reservations;
create policy sales_order_inventory_reservations_read on public.sales_order_inventory_reservations
for select to authenticated using (
  public.has_company_permission(company_id, 'view_sales_orders') and public.can_access_location(location_id)
);

create or replace function public.get_sales_deposit_order_detail(p_company_id uuid, p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_order public.sales_deposit_orders%rowtype;
begin
  select * into v_order from public.sales_deposit_orders where id = p_order_id and company_id = p_company_id;
  if not found or not public.has_company_permission(p_company_id, 'view_sales_orders') or not public.can_access_location(v_order.location_id) then raise exception 'Pedido no disponible.'; end if;
  return jsonb_build_object(
    'id', v_order.id, 'folio', v_order.folio, 'status', v_order.status,
    'inventory_reservation_status', v_order.inventory_reservation_status,
    'inventory_reservation_checked_at', v_order.inventory_reservation_checked_at,
    'inventory_reservation_message', v_order.inventory_reservation_message,
    'expected_delivery_date', v_order.expected_delivery_date, 'currency_code', v_order.currency_code,
    'subtotal_amount', v_order.subtotal_amount, 'tax_amount', v_order.tax_amount, 'total_amount', v_order.total_amount,
    'paid_amount', v_order.paid_amount, 'outstanding_amount', round(v_order.total_amount - v_order.paid_amount, 2),
    'sale_id', v_order.sale_id, 'created_at', v_order.created_at, 'completed_at', v_order.completed_at,
    'cancelled_at', v_order.cancelled_at, 'cancellation_reason', v_order.cancellation_reason,
    'source', case when v_order.source_quote_id is not null then (select jsonb_build_object('kind', 'quote', 'id', quote_data.id, 'folio', quote_data.folio) from public.sales_quotes quote_data where quote_data.id = v_order.source_quote_id) else jsonb_build_object('kind', 'pos') end,
    'customer', (select jsonb_build_object('id', customer.id, 'code', customer.code, 'display_name', customer.display_name) from public.customers customer where customer.id = v_order.customer_id),
    'location', (select jsonb_build_object('id', location_data.id, 'name', location_data.name, 'code', location_data.external_code) from public.locations location_data where location_data.id = v_order.location_id),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', line.id, 'product_id', line.product_id, 'product_code', line.product_code,
        'product_name', line.product_name, 'unit_name', line.unit_name, 'quantity', line.quantity,
        'unit_total_amount', line.unit_total_amount, 'line_total_amount', line.line_total_amount,
        'inventory_tracked', line.inventory_tracked,
        'quantity_on_hand', case when line.inventory_tracked then coalesce(balance.quantity_on_hand, 0) else null end,
        'reserved_quantity', case when line.inventory_tracked then coalesce(reservation.quantity, 0) else null end,
        'available_quantity', case when line.inventory_tracked then greatest(coalesce(balance.quantity_on_hand, 0) - coalesce(balance.quantity_reserved, 0) + coalesce(reservation.quantity, 0), 0) else null end,
        'shortage_quantity', case when line.inventory_tracked then greatest(line.quantity - (coalesce(balance.quantity_on_hand, 0) - coalesce(balance.quantity_reserved, 0) + coalesce(reservation.quantity, 0)), 0) else 0 end
      ) order by line.created_at, line.id)
      from public.sales_deposit_order_lines line
      left join public.inventory_balances balance on balance.location_id = v_order.location_id and balance.product_id = line.product_id
      left join public.sales_order_inventory_reservations reservation on reservation.order_id = v_order.id and reservation.product_id = line.product_id and reservation.status = 'active'
      where line.order_id = v_order.id
    ), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', payment.id, 'payment_kind', payment.payment_kind, 'payment_method_id', payment.payment_method_id, 'payment_method_name', payment.payment_method_name, 'settlement_kind', payment.settlement_kind, 'amount', payment.amount, 'payment_reference', payment.payment_reference, 'received_at', payment.received_at) order by payment.received_at desc, payment.id desc) from public.sales_deposit_order_payments payment where payment.order_id = v_order.id), '[]'::jsonb)
  );
end $$;

create or replace function public.list_sales_deposit_orders(p_company_id uuid, p_query text default null, p_status text default null, p_page integer default 1, p_page_size integer default 25)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_query text := lower(trim(coalesce(p_query, ''))); v_page integer := greatest(coalesce(p_page, 1), 1); v_size integer := least(greatest(coalesce(p_page_size, 25), 1), 100); v_total integer; v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_sales_orders') then raise exception 'No autorizado para consultar órdenes de venta.'; end if;
  with filtered as materialized (
    select order_data.*, customer.display_name customer_name, location_data.name location_name
    from public.sales_deposit_orders order_data
    join public.customers customer on customer.id = order_data.customer_id
    join public.locations location_data on location_data.id = order_data.location_id
    where order_data.company_id = p_company_id and public.can_access_location(order_data.location_id)
      and (p_status is null or order_data.status = p_status)
      and (v_query = '' or lower(order_data.folio) like '%' || v_query || '%' or lower(customer.display_name) like '%' || v_query || '%')
  ) select count(*) into v_total from filtered;
  with filtered as materialized (
    select order_data.*, customer.display_name customer_name, location_data.name location_name
    from public.sales_deposit_orders order_data
    join public.customers customer on customer.id = order_data.customer_id
    join public.locations location_data on location_data.id = order_data.location_id
    where order_data.company_id = p_company_id and public.can_access_location(order_data.location_id)
      and (p_status is null or order_data.status = p_status)
      and (v_query = '' or lower(order_data.folio) like '%' || v_query || '%' or lower(customer.display_name) like '%' || v_query || '%')
  ) select coalesce(jsonb_agg(jsonb_build_object(
      'id', item.id, 'folio', item.folio, 'status', item.status,
      'inventory_reservation_status', item.inventory_reservation_status,
      'customer_name', item.customer_name, 'location_name', item.location_name,
      'currency_code', item.currency_code, 'total_amount', item.total_amount,
      'paid_amount', item.paid_amount, 'outstanding_amount', round(item.total_amount - item.paid_amount, 2),
      'expected_delivery_date', item.expected_delivery_date, 'updated_at', item.updated_at
    ) order by item.updated_at desc, item.id desc), '[]'::jsonb) into v_items
  from (select * from filtered order by updated_at desc, id desc limit v_size offset (v_page - 1) * v_size) item;
  return jsonb_build_object('items', v_items, 'total', coalesce(v_total, 0), 'page', v_page, 'page_size', v_size);
end $$;

create or replace function public.revalidate_sales_order_inventory(p_company_id uuid, p_order_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_order public.sales_deposit_orders%rowtype;
  v_line public.sales_deposit_order_lines%rowtype;
  v_reservation public.sales_order_inventory_reservations%rowtype;
  v_available numeric;
  v_shortages jsonb := '[]'::jsonb;
begin
  select * into v_order from public.sales_deposit_orders where id = p_order_id and company_id = p_company_id for update;
  if not found or v_order.status <> 'open' or not public.has_company_permission(p_company_id, 'manage_sales_orders') or not public.can_access_location(v_order.location_id) then raise exception 'Pedido no disponible para reservar inventario.'; end if;

  insert into public.inventory_balances(company_id, location_id, product_id, quantity_on_hand)
  select p_company_id, v_order.location_id, line.product_id, 0
  from public.sales_deposit_order_lines line
  where line.order_id = v_order.id and line.inventory_tracked
  on conflict(location_id, product_id) do nothing;

  perform 1
  from public.inventory_balances balance
  join public.sales_deposit_order_lines line on line.order_id = v_order.id and line.product_id = balance.product_id and line.inventory_tracked
  where balance.location_id = v_order.location_id
  order by balance.product_id
  for update of balance;

  for v_reservation in
    select * from public.sales_order_inventory_reservations
    where order_id = v_order.id and status = 'active'
    order by product_id for update
  loop
    update public.inventory_balances
    set quantity_reserved = quantity_reserved - v_reservation.quantity, updated_at = now()
    where location_id = v_reservation.location_id and product_id = v_reservation.product_id;
    update public.sales_order_inventory_reservations set status = 'released', resolved_at = now() where id = v_reservation.id;
  end loop;

  for v_line in
    select * from public.sales_deposit_order_lines where order_id = v_order.id and inventory_tracked order by product_id
  loop
    select quantity_on_hand - quantity_reserved into v_available
    from public.inventory_balances where location_id = v_order.location_id and product_id = v_line.product_id;
    if coalesce(v_available, 0) < v_line.quantity then
      v_shortages := v_shortages || jsonb_build_array(jsonb_build_object(
        'product_id', v_line.product_id, 'product_name', v_line.product_name,
        'required', v_line.quantity, 'available', greatest(coalesce(v_available, 0), 0),
        'missing', v_line.quantity - greatest(coalesce(v_available, 0), 0)
      ));
    end if;
  end loop;

  if jsonb_array_length(v_shortages) > 0 then
    update public.sales_deposit_orders
    set inventory_reservation_status = 'blocked', inventory_reservation_checked_at = now(),
        inventory_reservation_message = 'Falta inventario en esta sucursal.'
    where id = v_order.id;
    perform public.write_sales_audit(p_company_id, 'sales_order.inventory_blocked', 'sales_deposit_order', v_order.id, jsonb_build_object('shortages', v_shortages));
    return public.get_sales_deposit_order_detail(p_company_id, v_order.id);
  end if;

  for v_line in
    select * from public.sales_deposit_order_lines where order_id = v_order.id and inventory_tracked order by product_id
  loop
    insert into public.sales_order_inventory_reservations(company_id, order_id, location_id, product_id, quantity)
    values(p_company_id, v_order.id, v_order.location_id, v_line.product_id, v_line.quantity);
    update public.inventory_balances
    set quantity_reserved = quantity_reserved + v_line.quantity, updated_at = now()
    where location_id = v_order.location_id and product_id = v_line.product_id;
  end loop;
  update public.sales_deposit_orders
  set inventory_reservation_status = 'reserved', inventory_reservation_checked_at = now(), inventory_reservation_message = null
  where id = v_order.id;
  perform public.write_sales_audit(p_company_id, 'sales_order.inventory_reserved', 'sales_deposit_order', v_order.id, jsonb_build_object('location_id', v_order.location_id));
  return public.get_sales_deposit_order_detail(p_company_id, v_order.id);
end $$;

create or replace function public.create_sales_deposit_order(
  p_company_id uuid,
  p_location_id uuid,
  p_customer_id uuid,
  p_expected_delivery_date date default null,
  p_lines jsonb default '[]'::jsonb
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_price_list_id uuid; v_currency text; v_line jsonb; v_product public.products%rowtype; v_price numeric; v_rate numeric; v_quantity numeric; v_base numeric; v_tax numeric; v_total numeric; v_subtotal numeric := 0; v_tax_total numeric := 0; v_order_id uuid := gen_random_uuid(); v_folio text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_sales_orders') or not public.can_access_location(p_location_id) then raise exception 'No autorizado para crear pedidos.'; end if;
  if not exists(select 1 from public.locations where id = p_location_id and company_id = p_company_id and is_active) then raise exception 'Sucursal no disponible.'; end if;
  if not exists(select 1 from public.customers where id = p_customer_id and company_id = p_company_id and is_active) then raise exception 'Cliente no disponible.'; end if;
  if jsonb_typeof(coalesce(p_lines, '[]'::jsonb)) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Agrega al menos un producto.'; end if;
  if p_expected_delivery_date is not null and p_expected_delivery_date < current_date then raise exception 'La entrega no puede estar en el pasado.'; end if;
  select coalesce(customer.price_list_id, location_data.default_price_list_id, company.default_price_list_id) into v_price_list_id
  from public.companies company join public.locations location_data on location_data.id = p_location_id and location_data.company_id = company.id
  join public.customers customer on customer.id = p_customer_id where company.id = p_company_id;
  select currency_code into v_currency from public.price_lists where id = v_price_list_id and company_id = p_company_id and is_active and status = 'active';
  if v_currency is null then raise exception 'No hay una lista de precios vigente para este pedido.'; end if;

  create temporary table if not exists pg_temp.sales_order_input_lines(
    product_id uuid, product_code text, product_name text, unit_name text, tax_category_id uuid, tax_rate numeric,
    inventory_tracked boolean, quantity numeric, unit_base numeric, unit_tax numeric, unit_total numeric,
    line_base numeric, line_tax numeric, line_total numeric
  ) on commit drop;
  truncate pg_temp.sales_order_input_lines;
  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_quantity := round(coalesce((v_line ->> 'quantity')::numeric, 0), 6);
    if v_quantity <= 0 then raise exception 'Las cantidades deben ser mayores a cero.'; end if;
    select * into v_product from public.products where id = (v_line ->> 'product_id')::uuid and company_id = p_company_id and is_active and is_sellable and not commercial_review_required;
    if not found or v_product.sales_unit_id is null or v_product.tax_category_id is null then raise exception 'Producto no disponible para el pedido.'; end if;
    select amount into v_price from public.product_prices where product_id = v_product.id and price_list_id = v_price_list_id and currency_code = v_currency and valid_from <= now() and (valid_to is null or valid_to > now()) order by valid_from desc limit 1;
    select rate into v_rate from public.tax_rates where tax_category_id = v_product.tax_category_id and valid_from <= now() and (valid_to is null or valid_to > now()) order by valid_from desc limit 1;
    if v_price is null or v_rate is null then raise exception 'El producto % no tiene precio e impuesto vigentes.', v_product.name; end if;
    v_base := round(v_price * v_quantity, 2); v_tax := round(v_base * v_rate, 2); v_total := v_base + v_tax;
    insert into pg_temp.sales_order_input_lines values(v_product.id, coalesce(v_product.internal_sku, v_product.barcode), v_product.name, v_product.unit, v_product.tax_category_id, v_rate, v_product.is_inventory_tracked, v_quantity, v_price, round(v_price * v_rate, 2), round(v_price * (1 + v_rate), 2), v_base, v_tax, v_total);
    v_subtotal := v_subtotal + v_base; v_tax_total := v_tax_total + v_tax;
  end loop;
  if exists(select 1 from pg_temp.sales_order_input_lines group by product_id having count(*) > 1) then raise exception 'No repitas productos en el pedido.'; end if;
  v_folio := 'PED-' || to_char(current_date, 'YYYYMMDD') || '-' || upper(substr(v_order_id::text, 1, 6));
  insert into public.sales_deposit_orders(id, company_id, location_id, customer_id, folio, expected_delivery_date, currency_code, subtotal_amount, tax_amount, total_amount)
  values(v_order_id, p_company_id, p_location_id, p_customer_id, v_folio, p_expected_delivery_date, v_currency, round(v_subtotal,2), round(v_tax_total,2), round(v_subtotal + v_tax_total,2));
  insert into public.sales_deposit_order_lines(company_id, order_id, product_id, product_code, product_name, unit_name, price_list_id, tax_category_id, tax_rate, inventory_tracked, quantity, unit_base_amount, unit_tax_amount, unit_total_amount, line_base_amount, line_tax_amount, line_total_amount)
  select p_company_id, v_order_id, product_id, product_code, product_name, unit_name, v_price_list_id, tax_category_id, tax_rate, inventory_tracked, quantity, unit_base, unit_tax, unit_total, line_base, line_tax, line_total from pg_temp.sales_order_input_lines;
  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values(p_company_id, auth.uid(), 'sales_order.created', 'sales_deposit_order', v_order_id, jsonb_build_object('folio', v_folio, 'total_amount', round(v_subtotal + v_tax_total,2)));
  return public.revalidate_sales_order_inventory(p_company_id, v_order_id);
end $$;

create or replace function public.record_sales_deposit_order_payment(
  p_company_id uuid, p_order_id uuid, p_payment_method_id uuid, p_amount numeric,
  p_cash_session_id uuid default null, p_payment_reference text default null, p_client_request_id uuid default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_order public.sales_deposit_orders%rowtype; v_method public.payment_methods%rowtype; v_session public.cash_sessions%rowtype; v_payment_id uuid; v_amount numeric := round(coalesce(p_amount,0),2); v_request uuid := coalesce(p_client_request_id, gen_random_uuid());
begin
  if exists(select 1 from public.sales_deposit_order_payments where company_id = p_company_id and client_request_id = v_request) then return public.get_sales_deposit_order_detail(p_company_id, p_order_id); end if;
  select * into v_order from public.sales_deposit_orders where id = p_order_id and company_id = p_company_id for update;
  if not found or v_order.status <> 'open' or not public.has_company_permission(p_company_id, 'manage_sales_orders') or not public.can_access_location(v_order.location_id) then raise exception 'Pedido no disponible para recibir pagos.'; end if;
  if v_order.inventory_reservation_status <> 'reserved' then raise exception 'No se puede registrar el pago: primero asegura el inventario del pedido.'; end if;
  if v_amount <= 0 or v_amount > round(v_order.total_amount - v_order.paid_amount, 2) then raise exception 'El pago debe ser mayor a cero y no puede exceder el saldo pendiente.'; end if;
  select * into v_method from public.payment_methods where id = p_payment_method_id and company_id = p_company_id and is_active;
  if not found then raise exception 'Forma de pago no disponible.'; end if;
  if exists(select 1 from public.sales_deposit_order_payments where order_id = v_order.id and payment_method_id <> v_method.id) then raise exception 'Todos los pagos del pedido deben usar la misma forma de pago.'; end if;
  if v_method.settlement_kind = 'cash_drawer' then
    select * into v_session from public.cash_sessions where id = p_cash_session_id and company_id = p_company_id and location_id = v_order.location_id and opened_by = auth.uid() and status = 'open' for share;
    if not found then raise exception 'Abre tu caja en la sucursal del pedido para recibir efectivo.'; end if;
  elsif nullif(trim(coalesce(p_payment_reference,'')), '') is null then raise exception 'La referencia del pago externo es obligatoria.'; end if;
  insert into public.sales_deposit_order_payments(company_id, order_id, payment_kind, payment_method_id, payment_method_code, payment_method_name, settlement_kind, cash_session_id, amount, payment_reference, client_request_id, received_by)
  values(p_company_id, v_order.id, case when v_amount = round(v_order.total_amount - v_order.paid_amount, 2) then 'final' else 'deposit' end, v_method.id, v_method.code, v_method.display_name, v_method.settlement_kind, case when v_method.settlement_kind='cash_drawer' then v_session.id else null end, v_amount, nullif(trim(p_payment_reference),''), v_request, auth.uid()) returning id into v_payment_id;
  update public.sales_deposit_orders set paid_amount = paid_amount + v_amount where id = v_order.id;
  if v_method.settlement_kind = 'cash_drawer' then
    insert into public.cash_movements(company_id, cash_session_id, movement_type, amount, actor_id, reason, source_entity_type, source_entity_id)
    values(p_company_id, v_session.id, 'paid_in', v_amount, auth.uid(), 'Pago a cuenta de pedido ' || v_order.folio, 'sales_deposit_order_payment', v_payment_id);
  end if;
  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values(p_company_id, auth.uid(), 'sales_order.payment_received', 'sales_deposit_order', v_order.id, jsonb_build_object('payment_id', v_payment_id, 'amount', v_amount, 'payment_method', v_method.code, 'client_request_id', v_request, 'inventory_reserved', true));
  return public.get_sales_deposit_order_detail(p_company_id, v_order.id);
end $$;

create or replace function public.deliver_sales_deposit_order(
  p_company_id uuid,
  p_order_id uuid,
  p_cash_session_id uuid,
  p_client_request_id uuid default null
)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_order public.sales_deposit_orders%rowtype;
  v_method public.payment_methods%rowtype;
  v_session public.cash_sessions%rowtype;
  v_customer public.customers%rowtype;
  v_existing_sale public.sales%rowtype;
  v_request uuid := coalesce(p_client_request_id, gen_random_uuid());
  v_sale_id uuid;
  v_sale_item_id uuid;
  v_line public.sales_deposit_order_lines%rowtype;
  v_after_balance numeric;
  v_reserved numeric;
  v_folio_number bigint;
  v_folio text;
  v_ticket_id uuid;
  v_ticket_payload jsonb;
  v_ticket_items jsonb;
begin
  select * into v_existing_sale from public.sales where company_id = p_company_id and client_request_id = v_request;
  if found then return public.get_sales_deposit_order_detail(p_company_id, p_order_id); end if;
  select * into v_order from public.sales_deposit_orders where id = p_order_id and company_id = p_company_id for update;
  if not found or v_order.status <> 'open' or not public.has_company_permission(p_company_id, 'manage_sales_orders') or not public.can_access_location(v_order.location_id) then raise exception 'Pedido no disponible para entrega.'; end if;
  if v_order.inventory_reservation_status <> 'reserved' then raise exception 'El pedido no tiene el inventario reservado.'; end if;
  if round(v_order.total_amount - v_order.paid_amount, 2) <> 0 then raise exception 'El pedido debe estar totalmente pagado antes de confirmar la entrega.'; end if;
  select method.* into v_method
  from public.sales_deposit_order_payments payment
  join public.payment_methods method on method.id = payment.payment_method_id
  where payment.order_id = v_order.id order by payment.received_at limit 1;
  if not found then raise exception 'El pedido no tiene pagos registrados.'; end if;
  select * into v_session from public.cash_sessions where id = p_cash_session_id and company_id = p_company_id and location_id = v_order.location_id and opened_by = auth.uid() and status = 'open' for share;
  if not found then raise exception 'Abre tu caja en la sucursal del pedido para confirmar la entrega.'; end if;
  select * into v_customer from public.customers where id = v_order.customer_id and company_id = p_company_id and is_active;
  if not found then raise exception 'Cliente no disponible.'; end if;

  for v_line in select * from public.sales_deposit_order_lines where order_id = v_order.id order by product_id loop
    if not exists(select 1 from public.products product where product.id = v_line.product_id and product.company_id = p_company_id and product.is_active and product.is_sellable and not product.commercial_review_required) then raise exception 'El producto % ya no está habilitado para venta.', v_line.product_name; end if;
    if v_line.inventory_tracked then
      select reservation.quantity into v_reserved
      from public.sales_order_inventory_reservations reservation
      where reservation.order_id = v_order.id and reservation.product_id = v_line.product_id and reservation.status = 'active'
      for update;
      if coalesce(v_reserved, 0) <> v_line.quantity then raise exception 'La reserva de % ya no coincide con el pedido.', v_line.product_name; end if;
      perform 1 from public.inventory_balances
      where location_id = v_order.location_id and product_id = v_line.product_id and quantity_on_hand >= v_line.quantity and quantity_reserved >= v_line.quantity
      for update;
      if not found then raise exception 'La reserva de % no está disponible para consumo.', v_line.product_name; end if;
    end if;
  end loop;

  insert into public.sales(company_id, location_id, cash_register_id, cash_session_id, cashier_id, customer_id, sale_type, currency_code, subtotal_amount, discount_amount, tax_amount, total_amount, due_date, client_request_id)
  values(p_company_id, v_order.location_id, v_session.cash_register_id, v_session.id, auth.uid(), v_order.customer_id, 'cash', v_order.currency_code, v_order.subtotal_amount, 0, v_order.tax_amount, v_order.total_amount, null, v_request)
  returning id into v_sale_id;
  for v_line in select * from public.sales_deposit_order_lines where order_id = v_order.id order by product_id loop
    insert into public.sale_items(sale_id, product_id, product_code, product_name, unit_name, quantity, price_list_id, unit_price_amount, gross_amount, discount_percent, discount_amount, taxable_amount, tax_amount, total_amount)
    values(v_sale_id, v_line.product_id, coalesce(v_line.product_code, ''), v_line.product_name, v_line.unit_name, v_line.quantity, v_line.price_list_id, v_line.unit_base_amount, v_line.line_base_amount, 0, 0, v_line.line_base_amount, v_line.line_tax_amount, v_line.line_total_amount)
    returning id into v_sale_item_id;
    insert into public.sale_item_taxes(sale_item_id, tax_category_id, tax_category_code, rate, tax_amount)
    select v_sale_item_id, category.id, category.code, v_line.tax_rate, v_line.line_tax_amount from public.tax_categories category where category.id = v_line.tax_category_id;
    if v_line.inventory_tracked then
      update public.inventory_balances
      set quantity_on_hand = quantity_on_hand - v_line.quantity,
          quantity_reserved = quantity_reserved - v_line.quantity,
          updated_at = now()
      where location_id = v_order.location_id and product_id = v_line.product_id
      returning quantity_on_hand into v_after_balance;
      update public.sales_order_inventory_reservations
      set status = 'consumed', resolved_at = now()
      where order_id = v_order.id and product_id = v_line.product_id and status = 'active';
      insert into public.inventory_ledger(company_id, location_id, product_id, quantity_delta, balance_after, movement_type, sale_item_id, actor_id)
      values(p_company_id, v_order.location_id, v_line.product_id, -v_line.quantity, v_after_balance, 'sale', v_sale_item_id, auth.uid());
    end if;
  end loop;
  insert into public.sale_payments(sale_id, payment_method_id, payment_method_code, settlement_kind, received_amount, change_amount, applied_amount)
  values(v_sale_id, v_method.id, v_method.code, v_method.settlement_kind, v_order.total_amount, 0, v_order.total_amount);

  insert into public.ticket_sequences(company_id, location_id) values(p_company_id, v_order.location_id) on conflict do nothing;
  select next_number into v_folio_number from public.ticket_sequences where company_id = p_company_id and location_id = v_order.location_id for update;
  update public.ticket_sequences set next_number = next_number + 1 where company_id = p_company_id and location_id = v_order.location_id;
  v_folio := lpad(v_folio_number::text, 10, '0');
  select coalesce(jsonb_agg(jsonb_build_object('product_code', item.product_code, 'product_name', item.product_name, 'unit_name', item.unit_name, 'quantity', item.quantity, 'unit_price_amount', item.unit_price_amount, 'gross_amount', item.gross_amount, 'discount_percent', item.discount_percent, 'discount_amount', item.discount_amount, 'tax_amount', item.tax_amount, 'total_amount', item.total_amount) order by item.id), '[]'::jsonb)
  into v_ticket_items from public.sale_items item where item.sale_id = v_sale_id;
  v_ticket_payload := jsonb_build_object(
    'schema_version', 1, 'folio', v_folio, 'issued_at', now(), 'company_id', p_company_id, 'location_id', v_order.location_id,
    'sale', jsonb_build_object('id', v_sale_id, 'type', 'cash', 'currency_code', v_order.currency_code, 'customer', jsonb_build_object('id', v_customer.id, 'code', v_customer.code, 'display_name', v_customer.display_name), 'subtotal_amount', v_order.subtotal_amount, 'discount_amount', 0, 'tax_amount', v_order.tax_amount, 'total_amount', v_order.total_amount),
    'payment', jsonb_build_object('method_code', v_method.code, 'received_amount', v_order.total_amount, 'change_amount', 0, 'sales_order_folio', v_order.folio, 'paid_before_delivery', v_order.paid_amount),
    'items', v_ticket_items
  );
  insert into public.canonical_tickets(sale_id, company_id, location_id, folio, schema_version, payload, content_sha256)
  values(v_sale_id, p_company_id, v_order.location_id, v_folio, 1, v_ticket_payload, encode(digest(v_ticket_payload::text, 'sha256'), 'hex')) returning id into v_ticket_id;
  insert into public.ticket_print_outbox(canonical_ticket_id, payload_version, deduplication_key) values(v_ticket_id, 1, 'ticket.ready:' || v_ticket_id::text);
  update public.sales_deposit_orders
  set paid_amount = total_amount, status = 'completed', sale_id = v_sale_id, completed_at = now(),
      inventory_reservation_status = 'consumed', inventory_reservation_checked_at = now(), inventory_reservation_message = null
  where id = v_order.id;
  perform public.write_sales_audit(p_company_id, 'sales_order.delivered', 'sales_deposit_order', v_order.id, jsonb_build_object('sale_id', v_sale_id, 'ticket_id', v_ticket_id, 'folio', v_order.folio, 'client_request_id', v_request, 'inventory_reservation_consumed', true));
  return public.get_sales_deposit_order_detail(p_company_id, v_order.id);
end $$;

create or replace function public.cancel_sales_deposit_order(
  p_company_id uuid,
  p_order_id uuid,
  p_reason text
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_order public.sales_deposit_orders%rowtype;
  v_reservation public.sales_order_inventory_reservations%rowtype;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  select * into v_order from public.sales_deposit_orders where id = p_order_id and company_id = p_company_id for update;
  if not found or v_order.status <> 'open' or not public.has_company_permission(p_company_id, 'manage_sales_orders') or not public.can_access_location(v_order.location_id) then raise exception 'Pedido no disponible para cancelación.'; end if;
  if v_order.paid_amount > 0 then raise exception 'El pedido tiene pagos. Registra su devolución antes de cancelarlo.'; end if;
  if v_reason is null or char_length(v_reason) < 5 then raise exception 'Explica brevemente el motivo de cancelación.'; end if;

  perform 1
  from public.inventory_balances balance
  join public.sales_order_inventory_reservations reservation on reservation.order_id = v_order.id and reservation.status = 'active' and reservation.location_id = balance.location_id and reservation.product_id = balance.product_id
  order by balance.product_id
  for update of balance;
  for v_reservation in
    select * from public.sales_order_inventory_reservations where order_id = v_order.id and status = 'active' order by product_id for update
  loop
    update public.inventory_balances
    set quantity_reserved = quantity_reserved - v_reservation.quantity, updated_at = now()
    where location_id = v_reservation.location_id and product_id = v_reservation.product_id;
    update public.sales_order_inventory_reservations set status = 'released', resolved_at = now() where id = v_reservation.id;
  end loop;
  update public.sales_deposit_orders
  set status = 'cancelled', inventory_reservation_status = 'released', inventory_reservation_checked_at = now(),
      inventory_reservation_message = 'Reserva liberada por cancelación.', cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = v_reason
  where id = v_order.id;
  perform public.write_sales_audit(p_company_id, 'sales_order.cancelled', 'sales_deposit_order', v_order.id, jsonb_build_object('reason', v_reason, 'inventory_released', true));
  return public.get_sales_deposit_order_detail(p_company_id, v_order.id);
end $$;

grant select on public.sales_order_inventory_reservations to authenticated;
grant execute on function public.revalidate_sales_order_inventory(uuid, uuid) to authenticated;
grant execute on function public.get_sales_deposit_order_detail(uuid, uuid) to authenticated;
grant execute on function public.list_sales_deposit_orders(uuid, text, text, integer, integer) to authenticated;
grant execute on function public.record_sales_deposit_order_payment(uuid, uuid, uuid, numeric, uuid, text, uuid) to authenticated;
grant execute on function public.create_sales_deposit_order(uuid, uuid, uuid, date, jsonb) to authenticated;
grant execute on function public.deliver_sales_deposit_order(uuid, uuid, uuid, uuid) to authenticated;
grant execute on function public.cancel_sales_deposit_order(uuid, uuid, text) to authenticated;

commit;
