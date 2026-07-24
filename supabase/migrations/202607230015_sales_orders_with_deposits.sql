-- Satrapy · Fase 2: órdenes de venta con pagos a cuenta.
-- La orden fija el precio comercial, pero no descuenta ni reserva inventario.
-- La salida de inventario y la venta canónica ocurren juntas al liquidar y entregar.

begin;

insert into public.permissions(code, description) values
  ('view_sales_orders', 'Consultar órdenes de venta.'),
  ('manage_sales_orders', 'Crear órdenes, recibir pagos a cuenta y confirmar su entrega.')
on conflict(code) do update set description = excluded.description;

insert into public.role_permissions(role_id, permission_id)
select role_data.id, permission_data.id
from public.roles role_data
join public.permissions permission_data on permission_data.code in ('view_sales_orders', 'manage_sales_orders')
where role_data.code in ('super_admin', 'direccion_admin', 'sucursal', 'punto_venta')
on conflict do nothing;

create table if not exists public.sales_deposit_orders (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete restrict,
  customer_id uuid not null references public.customers(id) on delete restrict,
  folio text not null,
  status text not null default 'open' check (status in ('open', 'completed')),
  expected_delivery_date date,
  currency_code text not null check (char_length(trim(currency_code)) = 3),
  subtotal_amount numeric(18,2) not null check (subtotal_amount >= 0),
  tax_amount numeric(18,2) not null check (tax_amount >= 0),
  total_amount numeric(18,2) not null check (total_amount > 0),
  paid_amount numeric(18,2) not null default 0 check (paid_amount >= 0 and paid_amount <= total_amount),
  source_cart_id uuid unique references public.sale_carts(id) on delete restrict,
  source_quote_id uuid unique references public.sales_quotes(id) on delete restrict,
  sale_id uuid unique references public.sales(id) on delete restrict,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  unique(company_id, folio),
  check ((status = 'open' and sale_id is null and completed_at is null) or (status = 'completed' and sale_id is not null and completed_at is not null and paid_amount = total_amount))
);
create index if not exists sales_deposit_orders_company_status_idx on public.sales_deposit_orders(company_id, status, updated_at desc, id desc);
create index if not exists sales_deposit_orders_customer_idx on public.sales_deposit_orders(company_id, customer_id, updated_at desc);
drop trigger if exists sales_deposit_orders_updated_at on public.sales_deposit_orders;
create trigger sales_deposit_orders_updated_at before update on public.sales_deposit_orders for each row execute function public.set_updated_at();

create table if not exists public.sales_deposit_order_lines (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  order_id uuid not null references public.sales_deposit_orders(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  product_code text,
  product_name text not null,
  unit_name text,
  price_list_id uuid references public.price_lists(id) on delete restrict,
  tax_category_id uuid references public.tax_categories(id) on delete restrict,
  tax_rate numeric(9,6) not null check (tax_rate >= 0 and tax_rate <= 1),
  inventory_tracked boolean not null,
  quantity numeric(18,6) not null check (quantity > 0),
  unit_base_amount numeric(18,2) not null check (unit_base_amount >= 0),
  unit_tax_amount numeric(18,2) not null check (unit_tax_amount >= 0),
  unit_total_amount numeric(18,2) not null check (unit_total_amount >= 0),
  line_base_amount numeric(18,2) not null check (line_base_amount >= 0),
  line_tax_amount numeric(18,2) not null check (line_tax_amount >= 0),
  line_total_amount numeric(18,2) not null check (line_total_amount >= 0),
  created_at timestamptz not null default now(),
  unique(order_id, product_id)
);
create index if not exists sales_deposit_order_lines_order_idx on public.sales_deposit_order_lines(order_id);

create table if not exists public.sales_deposit_order_payments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  order_id uuid not null references public.sales_deposit_orders(id) on delete restrict,
  payment_kind text not null check (payment_kind in ('deposit', 'final')),
  payment_method_id uuid not null references public.payment_methods(id) on delete restrict,
  payment_method_code text not null,
  payment_method_name text not null,
  settlement_kind text not null check (settlement_kind in ('cash_drawer', 'external')),
  cash_session_id uuid references public.cash_sessions(id) on delete restrict,
  amount numeric(18,2) not null check (amount > 0),
  payment_reference text,
  client_request_id uuid not null,
  received_by uuid not null references auth.users(id) on delete restrict,
  received_at timestamptz not null default now(),
  unique(company_id, client_request_id),
  check ((settlement_kind = 'cash_drawer' and cash_session_id is not null) or (settlement_kind = 'external' and cash_session_id is null))
);
create index if not exists sales_deposit_order_payments_order_idx on public.sales_deposit_order_payments(order_id, received_at, id);

alter table public.sales_deposit_orders enable row level security;
alter table public.sales_deposit_order_lines enable row level security;
alter table public.sales_deposit_order_payments enable row level security;

drop policy if exists sales_deposit_orders_read on public.sales_deposit_orders;
create policy sales_deposit_orders_read on public.sales_deposit_orders for select to authenticated using (
  public.has_company_permission(company_id, 'view_sales_orders') and public.can_access_location(location_id)
);
drop policy if exists sales_deposit_order_lines_read on public.sales_deposit_order_lines;
create policy sales_deposit_order_lines_read on public.sales_deposit_order_lines for select to authenticated using (
  exists(select 1 from public.sales_deposit_orders order_data where order_data.id = order_id and public.has_company_permission(order_data.company_id, 'view_sales_orders') and public.can_access_location(order_data.location_id))
);
drop policy if exists sales_deposit_order_payments_read on public.sales_deposit_order_payments;
create policy sales_deposit_order_payments_read on public.sales_deposit_order_payments for select to authenticated using (
  exists(select 1 from public.sales_deposit_orders order_data where order_data.id = order_id and public.has_company_permission(order_data.company_id, 'view_sales_orders') and public.can_access_location(order_data.location_id))
);

create or replace function public.get_sales_deposit_order_context(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_sales_orders') then raise exception 'No autorizado para consultar órdenes de venta.'; end if;
  return jsonb_build_object(
    'locations', coalesce((
      select jsonb_agg(jsonb_build_object('id', location_data.id, 'name', location_data.name, 'code', location_data.external_code) order by location_data.name)
      from public.locations location_data
      where location_data.company_id = p_company_id and location_data.is_active and public.can_access_location(location_data.id)
    ), '[]'::jsonb),
    'payment_methods', coalesce((
      select jsonb_agg(jsonb_build_object('id', method.id, 'code', method.code, 'name', method.display_name, 'settlement_kind', method.settlement_kind) order by method.display_name)
      from public.payment_methods method where method.company_id = p_company_id and method.is_active
    ), '[]'::jsonb),
    'own_open_session', (
      select jsonb_build_object('id', session.id, 'location_id', session.location_id, 'cash_register_id', session.cash_register_id)
      from public.cash_sessions session where session.company_id = p_company_id and session.opened_by = auth.uid() and session.status = 'open'
      order by session.opened_at desc limit 1
    )
  );
end $$;

create or replace function public.get_sales_deposit_order_detail(p_company_id uuid, p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_order public.sales_deposit_orders%rowtype;
begin
  select * into v_order from public.sales_deposit_orders where id = p_order_id and company_id = p_company_id;
  if not found or not public.has_company_permission(p_company_id, 'view_sales_orders') or not public.can_access_location(v_order.location_id) then raise exception 'Orden de venta no disponible.'; end if;
  return jsonb_build_object(
    'id', v_order.id, 'folio', v_order.folio, 'status', v_order.status,
    'expected_delivery_date', v_order.expected_delivery_date, 'currency_code', v_order.currency_code,
    'subtotal_amount', v_order.subtotal_amount, 'tax_amount', v_order.tax_amount, 'total_amount', v_order.total_amount,
    'paid_amount', v_order.paid_amount, 'outstanding_amount', round(v_order.total_amount - v_order.paid_amount, 2),
    'sale_id', v_order.sale_id, 'created_at', v_order.created_at, 'completed_at', v_order.completed_at,
    'customer', (select jsonb_build_object('id', customer.id, 'code', customer.code, 'display_name', customer.display_name) from public.customers customer where customer.id = v_order.customer_id),
    'location', (select jsonb_build_object('id', location_data.id, 'name', location_data.name, 'code', location_data.external_code) from public.locations location_data where location_data.id = v_order.location_id),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('id', line.id, 'product_id', line.product_id, 'product_code', line.product_code, 'product_name', line.product_name, 'unit_name', line.unit_name, 'quantity', line.quantity, 'unit_total_amount', line.unit_total_amount, 'line_total_amount', line.line_total_amount) order by line.created_at, line.id) from public.sales_deposit_order_lines line where line.order_id = v_order.id), '[]'::jsonb),
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
      'id', item.id, 'folio', item.folio, 'status', item.status, 'customer_name', item.customer_name,
      'location_name', item.location_name, 'currency_code', item.currency_code, 'total_amount', item.total_amount,
      'paid_amount', item.paid_amount, 'outstanding_amount', round(item.total_amount - item.paid_amount, 2),
      'expected_delivery_date', item.expected_delivery_date, 'updated_at', item.updated_at
    ) order by item.updated_at desc, item.id desc), '[]'::jsonb) into v_items
  from (select * from filtered order by updated_at desc, id desc limit v_size offset (v_page - 1) * v_size) item;
  return jsonb_build_object('items', v_items, 'total', coalesce(v_total, 0), 'page', v_page, 'page_size', v_size);
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
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_sales_orders') or not public.can_access_location(p_location_id) then raise exception 'No autorizado para crear órdenes de venta.'; end if;
  if not exists(select 1 from public.locations where id = p_location_id and company_id = p_company_id and is_active) then raise exception 'Sucursal no disponible.'; end if;
  if not exists(select 1 from public.customers where id = p_customer_id and company_id = p_company_id and is_active) then raise exception 'Cliente no disponible.'; end if;
  if jsonb_typeof(coalesce(p_lines, '[]'::jsonb)) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Agrega al menos un producto.'; end if;
  if p_expected_delivery_date is not null and p_expected_delivery_date < current_date then raise exception 'La entrega no puede estar en el pasado.'; end if;
  select coalesce(customer.price_list_id, location_data.default_price_list_id, company.default_price_list_id) into v_price_list_id
  from public.companies company join public.locations location_data on location_data.id = p_location_id and location_data.company_id = company.id
  join public.customers customer on customer.id = p_customer_id where company.id = p_company_id;
  select currency_code into v_currency from public.price_lists where id = v_price_list_id and company_id = p_company_id and is_active and status = 'active';
  if v_currency is null then raise exception 'No hay una lista de precios vigente para esta orden.'; end if;

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
    if not found or v_product.sales_unit_id is null or v_product.tax_category_id is null then raise exception 'Producto no disponible para la orden.'; end if;
    select amount into v_price from public.product_prices where product_id = v_product.id and price_list_id = v_price_list_id and currency_code = v_currency and valid_from <= now() and (valid_to is null or valid_to > now()) order by valid_from desc limit 1;
    select rate into v_rate from public.tax_rates where tax_category_id = v_product.tax_category_id and valid_from <= now() and (valid_to is null or valid_to > now()) order by valid_from desc limit 1;
    if v_price is null or v_rate is null then raise exception 'El producto % no tiene precio e impuesto vigentes.', v_product.name; end if;
    v_base := round(v_price * v_quantity, 2); v_tax := round(v_base * v_rate, 2); v_total := v_base + v_tax;
    insert into pg_temp.sales_order_input_lines values(v_product.id, coalesce(v_product.internal_sku, v_product.barcode), v_product.name, v_product.unit, v_product.tax_category_id, v_rate, v_product.is_inventory_tracked, v_quantity, v_price, round(v_price * v_rate, 2), round(v_price * (1 + v_rate), 2), v_base, v_tax, v_total);
    v_subtotal := v_subtotal + v_base; v_tax_total := v_tax_total + v_tax;
  end loop;
  if exists(select 1 from pg_temp.sales_order_input_lines group by product_id having count(*) > 1) then raise exception 'No repitas productos en la orden.'; end if;
  v_folio := 'PED-' || to_char(current_date, 'YYYYMMDD') || '-' || upper(substr(v_order_id::text, 1, 6));
  insert into public.sales_deposit_orders(id, company_id, location_id, customer_id, folio, expected_delivery_date, currency_code, subtotal_amount, tax_amount, total_amount)
  values(v_order_id, p_company_id, p_location_id, p_customer_id, v_folio, p_expected_delivery_date, v_currency, round(v_subtotal,2), round(v_tax_total,2), round(v_subtotal + v_tax_total,2));
  insert into public.sales_deposit_order_lines(company_id, order_id, product_id, product_code, product_name, unit_name, price_list_id, tax_category_id, tax_rate, inventory_tracked, quantity, unit_base_amount, unit_tax_amount, unit_total_amount, line_base_amount, line_tax_amount, line_total_amount)
  select p_company_id, v_order_id, product_id, product_code, product_name, unit_name, v_price_list_id, tax_category_id, tax_rate, inventory_tracked, quantity, unit_base, unit_tax, unit_total, line_base, line_tax, line_total from pg_temp.sales_order_input_lines;
  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values(p_company_id, auth.uid(), 'sales_order.created', 'sales_deposit_order', v_order_id, jsonb_build_object('folio', v_folio, 'total_amount', round(v_subtotal + v_tax_total,2), 'inventory_reserved', false));
  return public.get_sales_deposit_order_detail(p_company_id, v_order_id);
end $$;

create or replace function public.record_sales_deposit_order_payment(
  p_company_id uuid,
  p_order_id uuid,
  p_payment_method_id uuid,
  p_amount numeric,
  p_cash_session_id uuid default null,
  p_payment_reference text default null,
  p_client_request_id uuid default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_order public.sales_deposit_orders%rowtype; v_method public.payment_methods%rowtype; v_session public.cash_sessions%rowtype; v_payment_id uuid; v_amount numeric := round(coalesce(p_amount,0),2); v_request uuid := coalesce(p_client_request_id, gen_random_uuid());
begin
  if exists(select 1 from public.sales_deposit_order_payments where company_id = p_company_id and client_request_id = v_request) then return public.get_sales_deposit_order_detail(p_company_id, p_order_id); end if;
  select * into v_order from public.sales_deposit_orders where id = p_order_id and company_id = p_company_id for update;
  if not found or v_order.status <> 'open' or not public.has_company_permission(p_company_id, 'manage_sales_orders') or not public.can_access_location(v_order.location_id) then raise exception 'Orden no disponible para recibir pagos.'; end if;
  if v_amount <= 0 or v_amount > round(v_order.total_amount - v_order.paid_amount, 2) then raise exception 'El pago debe ser mayor a cero y no puede exceder el saldo pendiente.'; end if;
  select * into v_method from public.payment_methods where id = p_payment_method_id and company_id = p_company_id and is_active;
  if not found then raise exception 'Forma de pago no disponible.'; end if;
  if exists(select 1 from public.sales_deposit_order_payments where order_id = v_order.id and payment_method_id <> v_method.id) then raise exception 'Todos los pagos de la orden deben usar la misma forma de pago.'; end if;
  if v_method.settlement_kind = 'cash_drawer' then
    select * into v_session from public.cash_sessions where id = p_cash_session_id and company_id = p_company_id and location_id = v_order.location_id and opened_by = auth.uid() and status = 'open' for share;
    if not found then raise exception 'Abre tu caja en la sucursal de la orden para recibir efectivo.'; end if;
  elsif nullif(trim(coalesce(p_payment_reference,'')), '') is null then raise exception 'La referencia del pago externo es obligatoria.'; end if;
  insert into public.sales_deposit_order_payments(company_id, order_id, payment_kind, payment_method_id, payment_method_code, payment_method_name, settlement_kind, cash_session_id, amount, payment_reference, client_request_id, received_by)
  values(p_company_id, v_order.id, case when v_amount = round(v_order.total_amount - v_order.paid_amount, 2) then 'final' else 'deposit' end, v_method.id, v_method.code, v_method.display_name, v_method.settlement_kind, case when v_method.settlement_kind='cash_drawer' then v_session.id else null end, v_amount, nullif(trim(p_payment_reference),''), v_request, auth.uid()) returning id into v_payment_id;
  update public.sales_deposit_orders set paid_amount = paid_amount + v_amount where id = v_order.id;
  if v_method.settlement_kind = 'cash_drawer' then
    insert into public.cash_movements(company_id, cash_session_id, movement_type, amount, actor_id, reason, source_entity_type, source_entity_id)
    values(p_company_id, v_session.id, 'paid_in', v_amount, auth.uid(), 'Pago a cuenta de orden ' || v_order.folio, 'sales_deposit_order_payment', v_payment_id);
  end if;
  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values(p_company_id, auth.uid(), 'sales_order.payment_received', 'sales_deposit_order', v_order.id, jsonb_build_object('payment_id', v_payment_id, 'amount', v_amount, 'payment_method', v_method.code, 'client_request_id', v_request));
  return public.get_sales_deposit_order_detail(p_company_id, v_order.id);
end $$;

create or replace function public.create_sales_order_from_cart(
  p_company_id uuid,
  p_cart_id uuid,
  p_expected_revision integer,
  p_expected_delivery_date date default null,
  p_initial_payment_method_id uuid default null,
  p_initial_amount numeric default 0,
  p_payment_reference text default null,
  p_client_request_id uuid default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cart public.sale_carts%rowtype; v_result jsonb; v_order_id uuid; v_lines jsonb; v_amount numeric := round(coalesce(p_initial_amount,0),2); v_request uuid := coalesce(p_client_request_id, gen_random_uuid());
begin
  select id into v_order_id from public.sales_deposit_orders where source_cart_id = p_cart_id and company_id = p_company_id;
  if found then return public.get_sales_deposit_order_detail(p_company_id, v_order_id); end if;
  select * into v_cart from public.sale_carts where id = p_cart_id and company_id = p_company_id for update;
  if not found or v_cart.status <> 'active' or v_cart.cashier_id <> auth.uid() or v_cart.revision <> p_expected_revision then raise exception 'El carrito cambió o ya no está disponible.'; end if;
  if v_cart.customer_id is null then raise exception 'Selecciona un cliente para crear una orden de venta.'; end if;
  if not exists(select 1 from public.cash_sessions where id = v_cart.cash_session_id and status = 'open' and opened_by = auth.uid()) then raise exception 'La sesión de caja ya no está abierta.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('product_id', item.product_id, 'quantity', item.quantity) order by item.product_id), '[]'::jsonb)
  into v_lines from public.sale_cart_items item where item.cart_id = v_cart.id;
  v_result := public.create_sales_deposit_order(p_company_id, v_cart.location_id, v_cart.customer_id, p_expected_delivery_date, v_lines);
  v_order_id := (v_result ->> 'id')::uuid;
  update public.sales_deposit_orders set source_cart_id = v_cart.id where id = v_order_id;
  if v_amount > 0 then
    if p_initial_payment_method_id is null then raise exception 'Selecciona una forma de pago para el pago inicial.'; end if;
    v_result := public.record_sales_deposit_order_payment(p_company_id, v_order_id, p_initial_payment_method_id, v_amount, v_cart.cash_session_id, p_payment_reference, v_request);
  end if;
  update public.sale_carts set status = 'converted', revision = revision + 1 where id = v_cart.id;
  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values(p_company_id, auth.uid(), 'sales_order.created_from_pos', 'sales_deposit_order', v_order_id, jsonb_build_object('cart_id', v_cart.id, 'initial_amount', v_amount));
  return public.get_sales_deposit_order_detail(p_company_id, v_order_id);
end $$;

create or replace function public.create_sales_order_from_quote(
  p_company_id uuid,
  p_quote_id uuid,
  p_expected_delivery_date date default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_quote public.sales_quotes%rowtype; v_result jsonb; v_order_id uuid; v_lines jsonb;
begin
  select id into v_order_id from public.sales_deposit_orders where source_quote_id = p_quote_id and company_id = p_company_id;
  if found then return public.get_sales_deposit_order_detail(p_company_id, v_order_id); end if;
  select * into v_quote from public.sales_quotes where id = p_quote_id and company_id = p_company_id for update;
  if not found or v_quote.status <> 'accepted' or not public.can_access_location(v_quote.location_id) or not public.has_company_permission(p_company_id, 'manage_sales_orders') then raise exception 'Solo una cotización aceptada puede convertirse en orden de venta.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('product_id', line.product_id, 'quantity', line.quantity) order by line.product_id), '[]'::jsonb)
  into v_lines from public.sales_quote_lines line where line.quote_id = v_quote.id;
  v_result := public.create_sales_deposit_order(p_company_id, v_quote.location_id, v_quote.customer_id, p_expected_delivery_date, v_lines);
  v_order_id := (v_result ->> 'id')::uuid;
  update public.sales_deposit_orders set source_quote_id = v_quote.id where id = v_order_id;
  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values(p_company_id, auth.uid(), 'sales_order.created_from_quote', 'sales_deposit_order', v_order_id, jsonb_build_object('quote_id', v_quote.id, 'quote_folio', v_quote.folio));
  return public.get_sales_deposit_order_detail(p_company_id, v_order_id);
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
  v_balance numeric;
  v_after_balance numeric;
  v_folio_number bigint;
  v_folio text;
  v_ticket_id uuid;
  v_ticket_payload jsonb;
  v_ticket_items jsonb;
begin
  select * into v_existing_sale from public.sales where company_id = p_company_id and client_request_id = v_request;
  if found then return public.get_sales_deposit_order_detail(p_company_id, p_order_id); end if;
  select * into v_order from public.sales_deposit_orders where id = p_order_id and company_id = p_company_id for update;
  if not found or v_order.status <> 'open' or not public.has_company_permission(p_company_id, 'manage_sales_orders') or not public.can_access_location(v_order.location_id) then raise exception 'Orden no disponible para entrega.'; end if;
  if round(v_order.total_amount - v_order.paid_amount, 2) <> 0 then raise exception 'La orden debe estar totalmente pagada antes de confirmar la entrega.'; end if;
  select method.* into v_method
  from public.sales_deposit_order_payments payment
  join public.payment_methods method on method.id = payment.payment_method_id
  where payment.order_id = v_order.id order by payment.received_at limit 1;
  if not found then raise exception 'La orden no tiene pagos registrados.'; end if;
  select * into v_session from public.cash_sessions where id = p_cash_session_id and company_id = p_company_id and location_id = v_order.location_id and opened_by = auth.uid() and status = 'open' for share;
  if not found then raise exception 'Abre tu caja en la sucursal de la orden para confirmar la entrega.'; end if;
  select * into v_customer from public.customers where id = v_order.customer_id and company_id = p_company_id and is_active;
  if not found then raise exception 'Cliente no disponible.'; end if;

  for v_line in select * from public.sales_deposit_order_lines where order_id = v_order.id order by product_id loop
    if not exists(select 1 from public.products product where product.id = v_line.product_id and product.company_id = p_company_id and product.is_active and product.is_sellable and not product.commercial_review_required) then raise exception 'El producto % ya no está habilitado para venta.', v_line.product_name; end if;
    if v_line.inventory_tracked then
      select quantity_on_hand into v_balance from public.inventory_balances where location_id = v_order.location_id and product_id = v_line.product_id for update;
      if coalesce(v_balance, 0) < v_line.quantity then raise exception 'Existencia insuficiente para %.', v_line.product_name; end if;
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
      update public.inventory_balances set quantity_on_hand = quantity_on_hand - v_line.quantity, updated_at = now()
      where location_id = v_order.location_id and product_id = v_line.product_id returning quantity_on_hand into v_after_balance;
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
  update public.sales_deposit_orders set paid_amount = total_amount, status = 'completed', sale_id = v_sale_id, completed_at = now() where id = v_order.id;
  perform public.write_sales_audit(p_company_id, 'sales_order.delivered', 'sales_deposit_order', v_order.id, jsonb_build_object('sale_id', v_sale_id, 'ticket_id', v_ticket_id, 'folio', v_order.folio, 'client_request_id', v_request));
  return public.get_sales_deposit_order_detail(p_company_id, v_order.id);
end $$;

grant select on public.sales_deposit_orders, public.sales_deposit_order_lines, public.sales_deposit_order_payments to authenticated;
grant execute on function public.get_sales_deposit_order_context(uuid) to authenticated;
grant execute on function public.get_sales_deposit_order_detail(uuid, uuid) to authenticated;
grant execute on function public.list_sales_deposit_orders(uuid, text, text, integer, integer) to authenticated;
grant execute on function public.create_sales_deposit_order(uuid, uuid, uuid, date, jsonb) to authenticated;
grant execute on function public.record_sales_deposit_order_payment(uuid, uuid, uuid, numeric, uuid, text, uuid) to authenticated;
grant execute on function public.create_sales_order_from_cart(uuid, uuid, integer, date, uuid, numeric, text, uuid) to authenticated;
grant execute on function public.create_sales_order_from_quote(uuid, uuid, date) to authenticated;
grant execute on function public.deliver_sales_deposit_order(uuid, uuid, uuid, uuid) to authenticated;

commit;
