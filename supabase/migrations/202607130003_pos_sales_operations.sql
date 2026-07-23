-- Satrapy · Module 2 operational RPCs.
-- The browser can read permitted projections but all commercial mutations are
-- performed here so a sale succeeds completely or has no effect at all.

create or replace function public.write_sales_audit(
  p_company_id uuid,
  p_action text,
  p_entity_type text,
  p_entity_id uuid,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values (p_company_id, auth.uid(), p_action, p_entity_type, p_entity_id, coalesce(p_metadata, '{}'::jsonb));
end $$;

create or replace function public.assert_pos_access(
  p_company_id uuid,
  p_location_id uuid,
  p_permission text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null
    or not public.has_company_permission(p_company_id, p_permission)
    or not public.can_access_location(p_location_id)
    or not exists (select 1 from public.locations where id = p_location_id and company_id = p_company_id and is_active) then
    raise exception 'No autorizado para operar esta ubicación.';
  end if;
end $$;

create or replace function public.resolve_pos_sale_price(
  p_company_id uuid,
  p_location_id uuid,
  p_customer_id uuid default null,
  p_product_id uuid default null,
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_price_list_id uuid;
  v_price public.product_prices%rowtype;
  v_currency_code text;
begin
  if p_product_id is null then raise exception 'Producto requerido.'; end if;
  if not exists (select 1 from public.products where id = p_product_id and company_id = p_company_id) then
    raise exception 'Producto no encontrado.';
  end if;
  if not exists (select 1 from public.locations where id = p_location_id and company_id = p_company_id) then
    raise exception 'Ubicación no encontrada.';
  end if;
  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id and company_id = p_company_id and is_active) then
    raise exception 'Cliente no encontrado o inactivo.';
  end if;

  select coalesce(customer_data.price_list_id, location_data.default_price_list_id, company_data.default_price_list_id)
  into v_price_list_id
  from public.companies company_data
  join public.locations location_data on location_data.id = p_location_id
  left join public.customers customer_data on customer_data.id = p_customer_id
  where company_data.id = p_company_id;

  if v_price_list_id is null then return null; end if;

  select price_list.currency_code into v_currency_code
  from public.price_lists price_list
  where price_list.id = v_price_list_id
    and price_list.company_id = p_company_id
    and price_list.is_active
    and price_list.status = 'active';
  if not found then return null; end if;

  select * into v_price
  from public.product_prices price
  where price.product_id = p_product_id
    and price.price_list_id = v_price_list_id
    and price.currency_code = v_currency_code
    and price.valid_from <= p_at
    and (price.valid_to is null or price.valid_to > p_at)
  order by price.valid_from desc
  limit 1;
  if not found or v_price.amount <= 0 then return null; end if;

  return jsonb_build_object(
    'price_list_id', v_price_list_id,
    'amount', round(v_price.amount, 2),
    'currency_code', v_currency_code,
    'valid_from', v_price.valid_from
  );
end $$;

create or replace function public.search_pos_sale_products(
  p_company_id uuid,
  p_location_id uuid,
  p_customer_id uuid default null,
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 50,
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 50), 1), 100);
  v_query text := lower(trim(coalesce(p_query, '')));
  v_total integer;
  v_items jsonb;
begin
  perform public.assert_pos_access(p_company_id, p_location_id, 'use_pos');

  with eligible as materialized (
    select distinct
      product.id, product.name, product.internal_sku, product.barcode, product.unit,
      product.is_inventory_tracked,
      coalesce(balance.quantity_on_hand, 0) as quantity_on_hand,
      price_resolution.price,
      case
        when v_query = '' then 9
        when lower(coalesce(product.barcode, '')) = v_query then 1
        when lower(coalesce(product.internal_sku, '')) = v_query then 2
        when lower(coalesce(product.internal_sku, '')) like v_query || '%' then 3
        when exists (select 1 from public.product_external_references ref where ref.product_id = product.id and lower(ref.external_code) = v_query) then 4
        else 5
      end as rank
    from public.sales_assortment_items assortment_item
    join public.sales_assortments assortment on assortment.id = assortment_item.assortment_id
    join public.location_sales_assortments assignment on assignment.assortment_id = assortment.id
    join public.products product on product.id = assortment_item.product_id
    left join public.inventory_balances balance on balance.location_id = p_location_id and balance.product_id = product.id
    cross join lateral (select public.resolve_pos_sale_price(p_company_id, p_location_id, p_customer_id, product.id, p_at) as price) price_resolution
    cross join lateral public.product_pos_readiness_detail(p_company_id, product.id, null, p_at) readiness
    where assignment.location_id = p_location_id
      and assignment.valid_from <= p_at and (assignment.valid_to is null or assignment.valid_to > p_at)
      and assortment.status = 'active'
      and (assortment.valid_from is null or assortment.valid_from <= p_at)
      and (assortment.valid_to is null or assortment.valid_to > p_at)
      and product.company_id = p_company_id
      and coalesce((readiness ->> 'pos_ready')::boolean, false)
      and price_resolution.price is not null
      and (not product.is_inventory_tracked or coalesce(balance.quantity_on_hand, 0) > 0)
      and (
        v_query = ''
        or lower(product.name) like '%' || v_query || '%'
        or lower(coalesce(product.internal_sku, '')) like '%' || v_query || '%'
        or lower(coalesce(product.barcode, '')) = v_query
        or exists (select 1 from public.product_aliases alias_data where alias_data.product_id = product.id and lower(alias_data.normalized_value) like '%' || v_query || '%')
        or exists (select 1 from public.product_external_references ref where ref.product_id = product.id and lower(ref.external_code) like '%' || v_query || '%')
      )
  )
  select count(*) into v_total from eligible;

  with eligible as materialized (
    select distinct
      product.id, product.name, product.internal_sku, product.barcode, product.unit,
      product.is_inventory_tracked,
      coalesce(balance.quantity_on_hand, 0) as quantity_on_hand,
      price_resolution.price,
      case
        when v_query = '' then 9
        when lower(coalesce(product.barcode, '')) = v_query then 1
        when lower(coalesce(product.internal_sku, '')) = v_query then 2
        when lower(coalesce(product.internal_sku, '')) like v_query || '%' then 3
        when exists (select 1 from public.product_external_references ref where ref.product_id = product.id and lower(ref.external_code) = v_query) then 4
        else 5
      end as rank
    from public.sales_assortment_items assortment_item
    join public.sales_assortments assortment on assortment.id = assortment_item.assortment_id
    join public.location_sales_assortments assignment on assignment.assortment_id = assortment.id
    join public.products product on product.id = assortment_item.product_id
    left join public.inventory_balances balance on balance.location_id = p_location_id and balance.product_id = product.id
    cross join lateral (select public.resolve_pos_sale_price(p_company_id, p_location_id, p_customer_id, product.id, p_at) as price) price_resolution
    cross join lateral public.product_pos_readiness_detail(p_company_id, product.id, null, p_at) readiness
    where assignment.location_id = p_location_id
      and assignment.valid_from <= p_at and (assignment.valid_to is null or assignment.valid_to > p_at)
      and assortment.status = 'active'
      and (assortment.valid_from is null or assortment.valid_from <= p_at)
      and (assortment.valid_to is null or assortment.valid_to > p_at)
      and product.company_id = p_company_id
      and coalesce((readiness ->> 'pos_ready')::boolean, false)
      and price_resolution.price is not null
      and (not product.is_inventory_tracked or coalesce(balance.quantity_on_hand, 0) > 0)
      and (
        v_query = ''
        or lower(product.name) like '%' || v_query || '%'
        or lower(coalesce(product.internal_sku, '')) like '%' || v_query || '%'
        or lower(coalesce(product.barcode, '')) = v_query
        or exists (select 1 from public.product_aliases alias_data where alias_data.product_id = product.id and lower(alias_data.normalized_value) like '%' || v_query || '%')
        or exists (select 1 from public.product_external_references ref where ref.product_id = product.id and lower(ref.external_code) like '%' || v_query || '%')
      )
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'product_id', paged.id,
    'code', coalesce(paged.internal_sku, paged.barcode),
    'name', paged.name,
    'unit', paged.unit,
    'inventory_tracked', paged.is_inventory_tracked,
    'quantity_on_hand', paged.quantity_on_hand,
    'price_list_id', paged.price -> 'price_list_id',
    'price_amount', paged.price -> 'amount',
    'currency_code', paged.price -> 'currency_code'
  ) order by paged.rank, paged.name), '[]'::jsonb)
  into v_items
  from (
    select * from eligible order by rank, name limit v_size offset (v_page - 1) * v_size
  ) paged;

  return jsonb_build_object('items', v_items, 'total', coalesce(v_total, 0), 'page', v_page, 'page_size', v_size);
end $$;

create or replace function public.search_sale_customers(
  p_company_id uuid,
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 30
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 30), 1), 100);
  v_query text := lower(trim(coalesce(p_query, '')));
  v_total integer;
  v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'use_pos') then raise exception 'No autorizado.'; end if;
  with filtered as (
    select customer_data.*, coalesce((select sum(receivable.outstanding_amount) from public.customer_receivables receivable where receivable.customer_id = customer_data.id), 0) as outstanding_amount
    from public.customers customer_data
    where customer_data.company_id = p_company_id and customer_data.is_active
      and (v_query = '' or lower(customer_data.code) like '%' || v_query || '%' or lower(customer_data.display_name) like '%' || v_query || '%' or lower(coalesce(customer_data.tax_id, '')) like '%' || v_query || '%' or lower(coalesce(customer_data.phone, '')) like '%' || v_query || '%')
  ) select count(*) into v_total from filtered;
  with filtered as (
    select customer_data.*, coalesce((select sum(receivable.outstanding_amount) from public.customer_receivables receivable where receivable.customer_id = customer_data.id), 0) as outstanding_amount
    from public.customers customer_data
    where customer_data.company_id = p_company_id and customer_data.is_active
      and (v_query = '' or lower(customer_data.code) like '%' || v_query || '%' or lower(customer_data.display_name) like '%' || v_query || '%' or lower(coalesce(customer_data.tax_id, '')) like '%' || v_query || '%' or lower(coalesce(customer_data.phone, '')) like '%' || v_query || '%')
  ) select coalesce(jsonb_agg(jsonb_build_object(
    'id', paged.id, 'code', paged.code, 'display_name', paged.display_name,
    'credit_enabled', paged.credit_enabled, 'credit_limit', paged.credit_limit,
    'credit_term_days', paged.credit_term_days, 'outstanding_amount', paged.outstanding_amount,
    'available_credit', greatest(paged.credit_limit - paged.outstanding_amount, 0)
  ) order by paged.display_name), '[]'::jsonb) into v_items
  from (select * from filtered order by display_name limit v_size offset (v_page - 1) * v_size) paged;
  return jsonb_build_object('items', v_items, 'total', coalesce(v_total, 0), 'page', v_page, 'page_size', v_size);
end $$;

create or replace function public.upsert_sale_customer(
  p_company_id uuid,
  p_customer_id uuid default null,
  p_code text default null,
  p_display_name text default null,
  p_tax_id text default null,
  p_email text default null,
  p_phone text default null,
  p_price_list_id uuid default null,
  p_credit_enabled boolean default false,
  p_credit_limit numeric default 0,
  p_credit_term_days integer default 0
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_customers') then raise exception 'No autorizado para administrar clientes.'; end if;
  if nullif(trim(coalesce(p_display_name, '')), '') is null then raise exception 'El nombre del cliente es obligatorio.'; end if;
  if p_credit_enabled and (coalesce(p_credit_limit, 0) <= 0 or coalesce(p_credit_term_days, 0) <= 0) then raise exception 'El crédito requiere límite y plazo mayores a cero.'; end if;
  if p_customer_id is null then
    insert into public.customers(company_id, code, display_name, tax_id, email, phone, price_list_id, credit_enabled, credit_limit, credit_term_days, created_by)
    values (p_company_id, coalesce(nullif(trim(p_code), ''), 'CLI-' || upper(substr(gen_random_uuid()::text, 1, 8))), trim(p_display_name), nullif(trim(p_tax_id), ''), nullif(trim(p_email), ''), nullif(trim(p_phone), ''), p_price_list_id, coalesce(p_credit_enabled, false), coalesce(p_credit_limit, 0), coalesce(p_credit_term_days, 0), auth.uid())
    returning id into v_customer_id;
    perform public.write_sales_audit(p_company_id, 'customer.created', 'customers', v_customer_id, jsonb_build_object('credit_enabled', coalesce(p_credit_enabled, false)));
  else
    update public.customers set code = coalesce(nullif(trim(p_code), ''), code), display_name = trim(p_display_name), tax_id = nullif(trim(p_tax_id), ''), email = nullif(trim(p_email), ''), phone = nullif(trim(p_phone), ''), price_list_id = p_price_list_id, credit_enabled = coalesce(p_credit_enabled, false), credit_limit = coalesce(p_credit_limit, 0), credit_term_days = coalesce(p_credit_term_days, 0)
    where id = p_customer_id and company_id = p_company_id
    returning id into v_customer_id;
    if v_customer_id is null then raise exception 'Cliente no encontrado.'; end if;
    perform public.write_sales_audit(p_company_id, 'customer.updated', 'customers', v_customer_id, jsonb_build_object('credit_enabled', coalesce(p_credit_enabled, false)));
  end if;
  return v_customer_id;
end $$;

create or replace function public.get_pos_context(p_company_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'use_pos') then raise exception 'No autorizado.'; end if;
  return jsonb_build_object(
    'locations', coalesce((select jsonb_agg(jsonb_build_object('id', location_data.id, 'name', location_data.name, 'code', location_data.external_code) order by location_data.name) from public.locations location_data where location_data.company_id = p_company_id and location_data.is_active and public.can_access_location(location_data.id)), '[]'::jsonb),
    'registers', coalesce((select jsonb_agg(jsonb_build_object('id', register_data.id, 'location_id', register_data.location_id, 'name', register_data.display_name, 'code', register_data.code, 'currency_code', register_data.currency_code) order by register_data.display_name) from public.cash_registers register_data where register_data.company_id = p_company_id and register_data.is_active and public.can_access_location(register_data.location_id)), '[]'::jsonb),
    'payment_methods', coalesce((select jsonb_agg(jsonb_build_object('id', payment_method.id, 'code', payment_method.code, 'name', payment_method.display_name, 'settlement_kind', payment_method.settlement_kind) order by payment_method.display_name) from public.payment_methods payment_method where payment_method.company_id = p_company_id and payment_method.is_active), '[]'::jsonb),
    'sessions', coalesce((select jsonb_agg(jsonb_build_object('id', session_data.id, 'cash_register_id', session_data.cash_register_id, 'location_id', session_data.location_id, 'status', session_data.status, 'opening_amount', session_data.opening_amount) order by session_data.opened_at desc) from public.cash_sessions session_data where session_data.company_id = p_company_id and session_data.opened_by = auth.uid() and session_data.status = 'open'), '[]'::jsonb)
  );
end $$;

create or replace function public.cash_count_total(
  p_company_id uuid,
  p_currency_code text,
  p_count_lines jsonb
)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_count integer;
  v_distinct_count integer;
  v_total numeric;
begin
  if jsonb_typeof(coalesce(p_count_lines, '[]'::jsonb)) <> 'array' then raise exception 'El conteo debe ser una lista de denominaciones.'; end if;
  select count(*), count(distinct input.denomination_id)
  into v_count, v_distinct_count
  from jsonb_to_recordset(coalesce(p_count_lines, '[]'::jsonb)) as input(denomination_id uuid, quantity integer);
  if v_count <> v_distinct_count then raise exception 'Una denominación solo puede contarse una vez.'; end if;
  if exists (
    select 1 from jsonb_to_recordset(coalesce(p_count_lines, '[]'::jsonb)) as input(denomination_id uuid, quantity integer)
    left join public.cash_denominations denomination on denomination.id = input.denomination_id
    where input.denomination_id is null or input.quantity is null or input.quantity < 0
      or denomination.id is null or denomination.company_id <> p_company_id or denomination.currency_code <> p_currency_code or not denomination.is_active
  ) then raise exception 'El conteo contiene denominaciones no válidas.'; end if;
  select coalesce(sum(denomination.value * input.quantity), 0)
  into v_total
  from jsonb_to_recordset(coalesce(p_count_lines, '[]'::jsonb)) as input(denomination_id uuid, quantity integer)
  join public.cash_denominations denomination on denomination.id = input.denomination_id;
  return round(v_total, 2);
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
  select * into v_register from public.cash_registers where id = p_cash_register_id and company_id = p_company_id and is_active;
  if not found then raise exception 'Caja no encontrada o inactiva.'; end if;
  perform public.assert_pos_access(p_company_id, v_register.location_id, 'open_cash_session');
  select * into v_existing from public.cash_sessions where company_id = p_company_id and open_request_id = v_request_id;
  if found then return jsonb_build_object('cash_session_id', v_existing.id, 'status', v_existing.status, 'opening_amount', v_existing.opening_amount, 'idempotent', true); end if;
  v_total := public.cash_count_total(p_company_id, v_register.currency_code, p_count_lines);
  insert into public.cash_sessions(company_id, cash_register_id, location_id, opened_by, opening_amount, open_request_id)
  values (p_company_id, p_cash_register_id, v_register.location_id, auth.uid(), v_total, v_request_id)
  returning id into v_session_id;
  insert into public.cash_counts(cash_session_id, count_type, total_amount, counted_by) values (v_session_id, 'opening', v_total, auth.uid()) returning id into v_count_id;
  insert into public.cash_count_lines(cash_count_id, denomination_id, denomination_value, quantity)
  select v_count_id, denomination.id, denomination.value, input.quantity
  from jsonb_to_recordset(coalesce(p_count_lines, '[]'::jsonb)) as input(denomination_id uuid, quantity integer)
  join public.cash_denominations denomination on denomination.id = input.denomination_id;
  if v_total <> 0 then
    insert into public.cash_movements(company_id, cash_session_id, movement_type, amount, actor_id, reason, source_entity_type, source_entity_id)
    values (p_company_id, v_session_id, 'opening', v_total, auth.uid(), 'Apertura de caja', 'cash_counts', v_count_id);
  end if;
  perform public.write_sales_audit(p_company_id, 'cash_session.opened', 'cash_sessions', v_session_id, jsonb_build_object('cash_register_id', p_cash_register_id, 'opening_amount', v_total));
  return jsonb_build_object('cash_session_id', v_session_id, 'status', 'open', 'opening_amount', v_total, 'idempotent', false);
exception when unique_violation then
  select * into v_existing from public.cash_sessions where cash_register_id = p_cash_register_id and status in ('open','pending_variance_approval');
  if found then return jsonb_build_object('cash_session_id', v_existing.id, 'status', v_existing.status, 'opening_amount', v_existing.opening_amount, 'idempotent', true); end if;
  raise;
end $$;

create or replace function public.get_or_create_sale_cart(
  p_company_id uuid,
  p_cash_register_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.cash_sessions%rowtype;
  v_cart public.sale_carts%rowtype;
begin
  select session_data.* into v_session
  from public.cash_sessions session_data
  join public.cash_registers register_data on register_data.id = session_data.cash_register_id
  where session_data.cash_register_id = p_cash_register_id
    and session_data.company_id = p_company_id
    and session_data.opened_by = auth.uid()
    and session_data.status = 'open'
    and register_data.is_active
  for share;
  if not found then raise exception 'Abre tu caja antes de iniciar una venta.'; end if;
  perform public.assert_pos_access(p_company_id, v_session.location_id, 'use_pos');
  select * into v_cart from public.sale_carts where cash_session_id = v_session.id and cashier_id = auth.uid() and status = 'active';
  if not found then
    insert into public.sale_carts(company_id, location_id, cash_register_id, cash_session_id, cashier_id)
    values (p_company_id, v_session.location_id, p_cash_register_id, v_session.id, auth.uid()) returning * into v_cart;
  end if;
  return jsonb_build_object('cart_id', v_cart.id, 'revision', v_cart.revision, 'location_id', v_cart.location_id, 'cash_session_id', v_cart.cash_session_id, 'customer_id', v_cart.customer_id);
end $$;

create or replace function public.change_sale_cart_item(
  p_cart_id uuid,
  p_product_id uuid,
  p_quantity_delta numeric,
  p_expected_revision integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cart public.sale_carts%rowtype;
  v_quantity numeric;
  v_new_revision integer;
  v_product public.products%rowtype;
  v_balance numeric;
begin
  if coalesce(p_quantity_delta, 0) = 0 then raise exception 'El cambio de cantidad no puede ser cero.'; end if;
  select * into v_cart from public.sale_carts where id = p_cart_id for update;
  if not found or v_cart.cashier_id <> auth.uid() or v_cart.status <> 'active' then raise exception 'Carrito no disponible.'; end if;
  perform public.assert_pos_access(v_cart.company_id, v_cart.location_id, 'use_pos');
  if v_cart.revision <> p_expected_revision then raise exception 'El carrito cambió en otra operación; actualiza la vista.'; end if;
  select * into v_product from public.products where id = p_product_id and company_id = v_cart.company_id;
  if not found then raise exception 'Producto no encontrado.'; end if;
  if not coalesce((public.validate_pos_product_for_location(v_cart.company_id, v_cart.location_id, p_product_id) ->> 'allowed')::boolean, false) then raise exception 'El producto ya no está disponible para POS.'; end if;
  select quantity into v_quantity from public.sale_cart_items where cart_id = p_cart_id and product_id = p_product_id;
  v_quantity := coalesce(v_quantity, 0) + p_quantity_delta;
  if v_quantity < 0 then raise exception 'La cantidad no puede ser negativa.'; end if;
  if v_product.is_inventory_tracked then
    select quantity_on_hand into v_balance from public.inventory_balances where location_id = v_cart.location_id and product_id = p_product_id;
    if coalesce(v_balance, 0) < v_quantity then raise exception 'No hay existencia disponible para esa cantidad.'; end if;
  end if;
  if v_quantity = 0 then
    delete from public.sale_cart_items where cart_id = p_cart_id and product_id = p_product_id;
  elsif exists (select 1 from public.sale_cart_items where cart_id = p_cart_id and product_id = p_product_id) then
    update public.sale_cart_items set quantity = v_quantity where cart_id = p_cart_id and product_id = p_product_id;
  else
    insert into public.sale_cart_items(cart_id, product_id, quantity) values (p_cart_id, p_product_id, v_quantity);
  end if;
  update public.sale_carts set revision = revision + 1 where id = p_cart_id returning revision into v_new_revision;
  return jsonb_build_object('cart_id', p_cart_id, 'revision', v_new_revision);
end $$;

create or replace function public.set_sale_cart_customer(
  p_cart_id uuid,
  p_customer_id uuid default null,
  p_expected_revision integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cart public.sale_carts%rowtype;
  v_new_revision integer;
begin
  select * into v_cart from public.sale_carts where id = p_cart_id for update;
  if not found or v_cart.cashier_id <> auth.uid() or v_cart.status <> 'active' then raise exception 'Carrito no disponible.'; end if;
  perform public.assert_pos_access(v_cart.company_id, v_cart.location_id, 'use_pos');
  if p_expected_revision is not null and v_cart.revision <> p_expected_revision then raise exception 'El carrito cambió en otra operación; actualiza la vista.'; end if;
  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id and company_id = v_cart.company_id and is_active) then raise exception 'Cliente no encontrado o inactivo.'; end if;
  update public.sale_carts set customer_id = p_customer_id, revision = revision + 1 where id = p_cart_id returning revision into v_new_revision;
  return jsonb_build_object('cart_id', p_cart_id, 'revision', v_new_revision, 'customer_id', p_customer_id);
end $$;

create or replace function public.quote_sale_cart(p_cart_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_cart public.sale_carts%rowtype;
  v_item record;
  v_price jsonb;
  v_currency text := null;
  v_rate numeric;
  v_gross numeric;
  v_discount numeric;
  v_taxable numeric;
  v_tax numeric;
  v_total numeric;
  v_effective_discount numeric;
  v_items jsonb := '[]'::jsonb;
  v_subtotal numeric := 0;
  v_discount_total numeric := 0;
  v_tax_total numeric := 0;
  v_grand_total numeric := 0;
  v_pending boolean := false;
begin
  select * into v_cart from public.sale_carts where id = p_cart_id;
  if not found or (v_cart.cashier_id <> auth.uid() and not public.has_company_permission(v_cart.company_id, 'view_sales')) then raise exception 'Carrito no disponible.'; end if;
  perform public.assert_pos_access(v_cart.company_id, v_cart.location_id, 'use_pos');
  for v_item in
    select item.*, product.name, product.internal_sku, product.unit, product.tax_category_id, product.is_inventory_tracked,
      coalesce(balance.quantity_on_hand, 0) as quantity_on_hand
    from public.sale_cart_items item
    join public.products product on product.id = item.product_id
    left join public.inventory_balances balance on balance.location_id = v_cart.location_id and balance.product_id = item.product_id
    where item.cart_id = v_cart.id order by item.product_id
  loop
    if v_item.discount_status = 'pending' or v_cart.sale_discount_status = 'pending' then v_pending := true; end if;
    v_price := public.resolve_pos_sale_price(v_cart.company_id, v_cart.location_id, v_cart.customer_id, v_item.product_id, now());
    if v_price is null then raise exception 'El producto % no tiene precio vigente en la lista efectiva.', v_item.name; end if;
    if v_currency is null then v_currency := v_price ->> 'currency_code'; elsif v_currency <> v_price ->> 'currency_code' then raise exception 'No se permite mezclar monedas en una venta.'; end if;
    select rate into v_rate from public.tax_rates where tax_category_id = v_item.tax_category_id and valid_from <= now() and (valid_to is null or valid_to > now()) order by valid_from desc limit 1;
    if not found then raise exception 'El producto no tiene una tasa de impuesto vigente.'; end if;
    v_gross := round((v_price ->> 'amount')::numeric * v_item.quantity, 2);
    v_effective_discount := 100 - ((100 - v_item.discount_percent) * (100 - v_cart.sale_discount_percent) / 100);
    v_discount := round(v_gross * v_effective_discount / 100, 2);
    v_taxable := v_gross - v_discount;
    v_tax := round(v_taxable * v_rate, 2);
    v_total := v_taxable + v_tax;
    v_subtotal := v_subtotal + v_gross; v_discount_total := v_discount_total + v_discount; v_tax_total := v_tax_total + v_tax; v_grand_total := v_grand_total + v_total;
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'cart_item_id', v_item.id, 'product_id', v_item.product_id, 'code', v_item.internal_sku, 'name', v_item.name, 'unit', v_item.unit,
      'quantity', v_item.quantity, 'inventory_tracked', v_item.is_inventory_tracked, 'quantity_on_hand', v_item.quantity_on_hand,
      'price_list_id', v_price -> 'price_list_id', 'unit_price_amount', v_price -> 'amount', 'currency_code', v_currency,
      'discount_percent', round(v_effective_discount, 2), 'gross_amount', v_gross, 'discount_amount', v_discount,
      'taxable_amount', v_taxable, 'tax_rate', v_rate, 'tax_amount', v_tax, 'total_amount', v_total
    ));
  end loop;
  return jsonb_build_object('cart_id', v_cart.id, 'revision', v_cart.revision, 'customer_id', v_cart.customer_id, 'currency_code', v_currency, 'items', v_items, 'subtotal_amount', round(v_subtotal, 2), 'discount_amount', round(v_discount_total, 2), 'tax_amount', round(v_tax_total, 2), 'total_amount', round(v_grand_total, 2), 'can_checkout', jsonb_array_length(v_items) > 0 and not v_pending, 'pending_discount_approval', v_pending);
end $$;

create or replace function public.request_cart_discount(
  p_cart_id uuid,
  p_scope text,
  p_cart_item_id uuid default null,
  p_percent numeric default null,
  p_reason text default null,
  p_expected_revision integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cart public.sale_carts%rowtype;
  v_limit numeric := 0;
  v_approval_id uuid;
  v_status text;
  v_revision integer;
begin
  if p_scope not in ('line','sale') or coalesce(p_percent, 0) <= 0 or p_percent > 100 or nullif(trim(coalesce(p_reason, '')), '') is null then raise exception 'Solicitud de descuento inválida.'; end if;
  select * into v_cart from public.sale_carts where id = p_cart_id for update;
  if not found or v_cart.cashier_id <> auth.uid() or v_cart.status <> 'active' then raise exception 'Carrito no disponible.'; end if;
  perform public.assert_pos_access(v_cart.company_id, v_cart.location_id, 'apply_discount');
  if p_expected_revision is not null and v_cart.revision <> p_expected_revision then raise exception 'El carrito cambió en otra operación; actualiza la vista.'; end if;
  if (p_scope = 'sale' and p_cart_item_id is not null) or (p_scope = 'line' and not exists (select 1 from public.sale_cart_items where id = p_cart_item_id and cart_id = p_cart_id)) then raise exception 'El alcance del descuento no coincide con el carrito.'; end if;
  select coalesce(max(limit_data.max_percent), 0) into v_limit
  from public.discount_role_limits limit_data
  join public.user_roles role_data on role_data.role_id = limit_data.role_id and role_data.user_id = auth.uid() and role_data.company_id = v_cart.company_id
  where limit_data.company_id = v_cart.company_id and limit_data.scope = p_scope and limit_data.valid_from <= now() and (limit_data.valid_to is null or limit_data.valid_to > now());
  if p_percent <= v_limit then
    if p_scope = 'sale' then
      update public.sale_carts set sale_discount_percent = p_percent, sale_discount_reason = trim(p_reason), sale_discount_status = 'approved', sale_discount_approved_by = auth.uid(), sale_discount_approved_at = now(), revision = revision + 1 where id = p_cart_id returning revision into v_revision;
    else
      update public.sale_cart_items set discount_percent = p_percent, discount_reason = trim(p_reason), discount_status = 'approved', discount_approved_by = auth.uid(), discount_approved_at = now() where id = p_cart_item_id;
      update public.sale_carts set revision = revision + 1 where id = p_cart_id returning revision into v_revision;
    end if;
    v_status := 'approved';
  else
    insert into public.discount_approvals(company_id, cart_id, cart_item_id, scope, requested_percent, requester_id, requested_reason)
    values (v_cart.company_id, p_cart_id, p_cart_item_id, p_scope, p_percent, auth.uid(), trim(p_reason)) returning id into v_approval_id;
    if p_scope = 'sale' then
      update public.sale_carts set sale_discount_percent = p_percent, sale_discount_reason = trim(p_reason), sale_discount_status = 'pending', sale_discount_approved_by = null, sale_discount_approved_at = null, revision = revision + 1 where id = p_cart_id returning revision into v_revision;
    else
      update public.sale_cart_items set discount_percent = p_percent, discount_reason = trim(p_reason), discount_status = 'pending', discount_approved_by = null, discount_approved_at = null where id = p_cart_item_id;
      update public.sale_carts set revision = revision + 1 where id = p_cart_id returning revision into v_revision;
    end if;
    v_status := 'pending';
  end if;
  perform public.write_sales_audit(v_cart.company_id, 'discount.' || v_status, 'sale_carts', v_cart.id, jsonb_build_object('scope', p_scope, 'percent', p_percent, 'approval_id', v_approval_id));
  return jsonb_build_object('status', v_status, 'approval_id', v_approval_id, 'revision', v_revision, 'limit_percent', v_limit);
end $$;

create or replace function public.decide_cart_discount(
  p_discount_approval_id uuid,
  p_approve boolean,
  p_decision_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_approval public.discount_approvals%rowtype;
  v_revision integer;
begin
  select * into v_approval from public.discount_approvals where id = p_discount_approval_id for update;
  if not found or v_approval.status <> 'pending' then raise exception 'Solicitud de descuento no disponible.'; end if;
  if auth.uid() = v_approval.requester_id or not public.has_company_permission(v_approval.company_id, 'approve_discount') then raise exception 'No autorizado para aprobar esta solicitud.'; end if;
  update public.discount_approvals set status = case when p_approve then 'approved' else 'rejected' end, decided_by = auth.uid(), decided_at = now(), decision_reason = nullif(trim(p_decision_reason), '') where id = v_approval.id;
  if v_approval.scope = 'sale' then
    update public.sale_carts set sale_discount_status = case when p_approve then 'approved' else 'none' end, sale_discount_percent = case when p_approve then sale_discount_percent else 0 end, sale_discount_approved_by = case when p_approve then auth.uid() else null end, sale_discount_approved_at = case when p_approve then now() else null end, revision = revision + 1 where id = v_approval.cart_id returning revision into v_revision;
  else
    update public.sale_cart_items set discount_status = case when p_approve then 'approved' else 'none' end, discount_percent = case when p_approve then discount_percent else 0 end, discount_approved_by = case when p_approve then auth.uid() else null end, discount_approved_at = case when p_approve then now() else null end where id = v_approval.cart_item_id;
    update public.sale_carts set revision = revision + 1 where id = v_approval.cart_id returning revision into v_revision;
  end if;
  perform public.write_sales_audit(v_approval.company_id, 'discount.' || case when p_approve then 'approved' else 'rejected' end, 'discount_approvals', v_approval.id, jsonb_build_object('cart_id', v_approval.cart_id));
  return jsonb_build_object('approval_id', v_approval.id, 'status', case when p_approve then 'approved' else 'rejected' end, 'revision', v_revision);
end $$;

create or replace function public.complete_sale(
  p_cart_id uuid,
  p_expected_revision integer,
  p_sale_type text,
  p_payment_method_id uuid default null,
  p_received_amount numeric default null,
  p_client_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cart public.sale_carts%rowtype;
  v_session public.cash_sessions%rowtype;
  v_existing_sale public.sales%rowtype;
  v_customer public.customers%rowtype;
  v_payment_method public.payment_methods%rowtype;
  v_item record;
  v_price jsonb;
  v_currency text := null;
  v_tax_rate numeric;
  v_gross numeric;
  v_discount numeric;
  v_taxable numeric;
  v_tax numeric;
  v_total_line numeric;
  v_discount_percent numeric;
  v_subtotal numeric := 0;
  v_discount_total numeric := 0;
  v_tax_total numeric := 0;
  v_total numeric := 0;
  v_lines jsonb := '[]'::jsonb;
  v_line jsonb;
  v_sale_id uuid;
  v_sale_item_id uuid;
  v_balance numeric;
  v_after_balance numeric;
  v_outstanding numeric;
  v_due_date date;
  v_request_id uuid := coalesce(p_client_request_id, gen_random_uuid());
  v_folio_number bigint;
  v_folio text;
  v_ticket_id uuid;
  v_ticket_payload jsonb;
  v_ticket_items jsonb;
  v_change_amount numeric := 0;
begin
  if p_sale_type not in ('cash','credit') then raise exception 'Tipo de venta inválido.'; end if;
  select * into v_cart from public.sale_carts where id = p_cart_id for update;
  if not found or v_cart.cashier_id <> auth.uid() then raise exception 'Carrito no disponible.'; end if;
  select * into v_existing_sale from public.sales where company_id = v_cart.company_id and client_request_id = v_request_id;
  if found then
    select id, folio, payload into v_ticket_id, v_folio, v_ticket_payload from public.canonical_tickets where sale_id = v_existing_sale.id;
    return jsonb_build_object('sale_id', v_existing_sale.id, 'ticket_id', v_ticket_id, 'folio', v_folio, 'ticket', v_ticket_payload, 'idempotent', true);
  end if;
  if v_cart.status <> 'active' then raise exception 'Carrito no disponible.'; end if;
  perform public.assert_pos_access(v_cart.company_id, v_cart.location_id, case when p_sale_type = 'cash' then 'sell_cash' else 'sell_credit' end);
  if v_cart.revision <> p_expected_revision then raise exception 'El carrito cambió en otra operación; actualiza la vista.'; end if;
  select * into v_session from public.cash_sessions where id = v_cart.cash_session_id and status = 'open' and opened_by = auth.uid() for share;
  if not found then raise exception 'La sesión de caja ya no está abierta.'; end if;
  if not exists (select 1 from public.sale_cart_items where cart_id = v_cart.id) then raise exception 'El carrito está vacío.'; end if;
  if v_cart.sale_discount_status = 'pending' or exists (select 1 from public.sale_cart_items where cart_id = v_cart.id and discount_status = 'pending') then raise exception 'Hay descuentos pendientes de aprobación.'; end if;
  if v_cart.customer_id is not null then
    select * into v_customer from public.customers where id = v_cart.customer_id and company_id = v_cart.company_id;
    if not found or not v_customer.is_active then raise exception 'Cliente no encontrado o inactivo.'; end if;
  end if;

  for v_item in
    select item.*, product.name, product.internal_sku, product.alpha_sku, product.unit, product.tax_category_id, product.is_inventory_tracked
    from public.sale_cart_items item join public.products product on product.id = item.product_id
    where item.cart_id = v_cart.id order by item.product_id
  loop
    if not coalesce((public.validate_pos_product_for_location(v_cart.company_id, v_cart.location_id, v_item.product_id) ->> 'allowed')::boolean, false) then raise exception 'El producto % ya no está listo para venderse.', v_item.name; end if;
    v_price := public.resolve_pos_sale_price(v_cart.company_id, v_cart.location_id, v_cart.customer_id, v_item.product_id, now());
    if v_price is null then raise exception 'El producto % no tiene precio vigente en la lista efectiva.', v_item.name; end if;
    if v_currency is null then v_currency := v_price ->> 'currency_code'; elsif v_currency <> v_price ->> 'currency_code' then raise exception 'No se permite mezclar monedas en una venta.'; end if;
    select rate into v_tax_rate from public.tax_rates where tax_category_id = v_item.tax_category_id and valid_from <= now() and (valid_to is null or valid_to > now()) order by valid_from desc limit 1;
    if not found then raise exception 'El producto % no tiene una tasa de impuesto vigente.', v_item.name; end if;
    v_gross := round((v_price ->> 'amount')::numeric * v_item.quantity, 2);
    v_discount_percent := round(100 - ((100 - v_item.discount_percent) * (100 - v_cart.sale_discount_percent) / 100), 2);
    v_discount := round(v_gross * v_discount_percent / 100, 2);
    v_taxable := v_gross - v_discount;
    v_tax := round(v_taxable * v_tax_rate, 2);
    v_total_line := v_taxable + v_tax;
    v_subtotal := v_subtotal + v_gross; v_discount_total := v_discount_total + v_discount; v_tax_total := v_tax_total + v_tax; v_total := v_total + v_total_line;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'product_id', v_item.product_id, 'product_code', coalesce(v_item.internal_sku, v_item.alpha_sku), 'product_name', v_item.name, 'unit_name', v_item.unit,
      'quantity', v_item.quantity, 'inventory_tracked', v_item.is_inventory_tracked, 'price_list_id', v_price -> 'price_list_id', 'unit_price_amount', v_price -> 'amount',
      'gross_amount', v_gross, 'discount_percent', v_discount_percent, 'discount_amount', v_discount, 'taxable_amount', v_taxable, 'tax_rate', v_tax_rate,
      'tax_category_id', v_item.tax_category_id, 'tax_amount', v_tax, 'total_amount', v_total_line
    ));
  end loop;
  v_subtotal := round(v_subtotal, 2); v_discount_total := round(v_discount_total, 2); v_tax_total := round(v_tax_total, 2); v_total := round(v_total, 2);

  if p_sale_type = 'cash' then
    if p_payment_method_id is null then raise exception 'Selecciona una forma de pago.'; end if;
    select * into v_payment_method from public.payment_methods where id = p_payment_method_id and company_id = v_cart.company_id and is_active;
    if not found then raise exception 'Forma de pago no disponible.'; end if;
    if v_payment_method.settlement_kind = 'cash_drawer' then
      if coalesce(p_received_amount, 0) < v_total then raise exception 'El efectivo recibido es menor al total.'; end if;
      v_change_amount := round(coalesce(p_received_amount, 0) - v_total, 2);
    elsif round(coalesce(p_received_amount, v_total), 2) <> v_total then
      raise exception 'Una forma de pago externa debe liquidar exactamente el total.';
    end if;
  else
    if v_cart.customer_id is null then raise exception 'La venta a crédito requiere un cliente.'; end if;
    select * into v_customer from public.customers where id = v_cart.customer_id and company_id = v_cart.company_id for update;
    if not found or not v_customer.is_active or not v_customer.credit_enabled then raise exception 'El cliente no está habilitado para crédito.'; end if;
    select coalesce(sum(outstanding_amount), 0) into v_outstanding from public.customer_receivables where customer_id = v_customer.id;
    if v_outstanding + v_total > v_customer.credit_limit then raise exception 'La venta excede el límite de crédito disponible.'; end if;
    v_due_date := current_date + v_customer.credit_term_days;
  end if;

  insert into public.sales(company_id, location_id, cash_register_id, cash_session_id, cashier_id, customer_id, sale_type, currency_code, subtotal_amount, discount_amount, tax_amount, total_amount, due_date, client_request_id)
  values (v_cart.company_id, v_cart.location_id, v_cart.cash_register_id, v_cart.cash_session_id, auth.uid(), v_cart.customer_id, p_sale_type, v_currency, v_subtotal, v_discount_total, v_tax_total, v_total, v_due_date, v_request_id)
  returning id into v_sale_id;

  for v_line in select value from jsonb_array_elements(v_lines) order by value ->> 'product_id'
  loop
    insert into public.sale_items(sale_id, product_id, product_code, product_name, unit_name, quantity, price_list_id, unit_price_amount, gross_amount, discount_percent, discount_amount, taxable_amount, tax_amount, total_amount)
    values (v_sale_id, (v_line ->> 'product_id')::uuid, v_line ->> 'product_code', v_line ->> 'product_name', nullif(v_line ->> 'unit_name', ''), (v_line ->> 'quantity')::numeric, (v_line ->> 'price_list_id')::uuid, (v_line ->> 'unit_price_amount')::numeric, (v_line ->> 'gross_amount')::numeric, (v_line ->> 'discount_percent')::numeric, (v_line ->> 'discount_amount')::numeric, (v_line ->> 'taxable_amount')::numeric, (v_line ->> 'tax_amount')::numeric, (v_line ->> 'total_amount')::numeric)
    returning id into v_sale_item_id;
    insert into public.sale_item_taxes(sale_item_id, tax_category_id, tax_category_code, rate, tax_amount)
    select v_sale_item_id, tax_category.id, tax_category.code, (v_line ->> 'tax_rate')::numeric, (v_line ->> 'tax_amount')::numeric from public.tax_categories tax_category where tax_category.id = (v_line ->> 'tax_category_id')::uuid;
    if coalesce((v_line ->> 'inventory_tracked')::boolean, false) then
      select quantity_on_hand into v_balance from public.inventory_balances where location_id = v_cart.location_id and product_id = (v_line ->> 'product_id')::uuid for update;
      if coalesce(v_balance, 0) < (v_line ->> 'quantity')::numeric then raise exception 'Existencia insuficiente para %.', v_line ->> 'product_name'; end if;
      update public.inventory_balances set quantity_on_hand = quantity_on_hand - (v_line ->> 'quantity')::numeric, updated_at = now() where location_id = v_cart.location_id and product_id = (v_line ->> 'product_id')::uuid returning quantity_on_hand into v_after_balance;
      insert into public.inventory_ledger(company_id, location_id, product_id, quantity_delta, balance_after, movement_type, sale_item_id, actor_id)
      values (v_cart.company_id, v_cart.location_id, (v_line ->> 'product_id')::uuid, -(v_line ->> 'quantity')::numeric, v_after_balance, 'sale', v_sale_item_id, auth.uid());
    end if;
  end loop;

  if p_sale_type = 'cash' then
    insert into public.sale_payments(sale_id, payment_method_id, payment_method_code, settlement_kind, received_amount, change_amount, applied_amount)
    values (v_sale_id, v_payment_method.id, v_payment_method.code, v_payment_method.settlement_kind, case when v_payment_method.settlement_kind = 'cash_drawer' then coalesce(p_received_amount, v_total) else v_total end, v_change_amount, v_total);
    if v_payment_method.settlement_kind = 'cash_drawer' then
      insert into public.cash_movements(company_id, cash_session_id, movement_type, amount, actor_id, source_entity_type, source_entity_id)
      values (v_cart.company_id, v_cart.cash_session_id, 'cash_sale', v_total, auth.uid(), 'sales', v_sale_id);
    end if;
  else
    insert into public.customer_receivables(company_id, customer_id, sale_id, due_date, original_amount, outstanding_amount)
    values (v_cart.company_id, v_customer.id, v_sale_id, v_due_date, v_total, v_total);
  end if;

  insert into public.ticket_sequences(company_id, location_id) values (v_cart.company_id, v_cart.location_id) on conflict do nothing;
  select next_number into v_folio_number from public.ticket_sequences where company_id = v_cart.company_id and location_id = v_cart.location_id for update;
  update public.ticket_sequences set next_number = next_number + 1 where company_id = v_cart.company_id and location_id = v_cart.location_id;
  v_folio := lpad(v_folio_number::text, 10, '0');
  select coalesce(jsonb_agg(jsonb_build_object('product_code', item.product_code, 'product_name', item.product_name, 'unit_name', item.unit_name, 'quantity', item.quantity, 'unit_price_amount', item.unit_price_amount, 'gross_amount', item.gross_amount, 'discount_percent', item.discount_percent, 'discount_amount', item.discount_amount, 'tax_amount', item.tax_amount, 'total_amount', item.total_amount) order by item.id), '[]'::jsonb) into v_ticket_items from public.sale_items item where item.sale_id = v_sale_id;
  v_ticket_payload := jsonb_build_object(
    'schema_version', 1,
    'folio', v_folio,
    'issued_at', now(),
    'company_id', v_cart.company_id,
    'location_id', v_cart.location_id,
    'sale', jsonb_build_object('id', v_sale_id, 'type', p_sale_type, 'currency_code', v_currency, 'customer', case when v_customer.id is null then null else jsonb_build_object('id', v_customer.id, 'code', v_customer.code, 'display_name', v_customer.display_name) end, 'subtotal_amount', v_subtotal, 'discount_amount', v_discount_total, 'tax_amount', v_tax_total, 'total_amount', v_total),
    'payment', case when p_sale_type = 'cash' then jsonb_build_object('method_code', v_payment_method.code, 'received_amount', case when v_payment_method.settlement_kind = 'cash_drawer' then coalesce(p_received_amount, v_total) else v_total end, 'change_amount', v_change_amount) else jsonb_build_object('type', 'credit', 'due_date', v_due_date) end,
    'items', v_ticket_items
  );
  insert into public.canonical_tickets(sale_id, company_id, location_id, folio, schema_version, payload, content_sha256)
  values (v_sale_id, v_cart.company_id, v_cart.location_id, v_folio, 1, v_ticket_payload, encode(digest(v_ticket_payload::text, 'sha256'), 'hex')) returning id into v_ticket_id;
  insert into public.ticket_print_outbox(canonical_ticket_id, payload_version, deduplication_key) values (v_ticket_id, 1, 'ticket.ready:' || v_ticket_id::text);
  update public.sale_carts set status = 'converted', revision = revision + 1 where id = v_cart.id;
  perform public.write_sales_audit(v_cart.company_id, 'sale.completed', 'sales', v_sale_id, jsonb_build_object('folio', v_folio, 'sale_type', p_sale_type, 'total_amount', v_total, 'client_request_id', v_request_id));
  return jsonb_build_object('sale_id', v_sale_id, 'ticket_id', v_ticket_id, 'folio', v_folio, 'ticket', v_ticket_payload, 'idempotent', false);
exception when unique_violation then
  select * into v_existing_sale from public.sales where company_id = v_cart.company_id and client_request_id = v_request_id;
  if found then
    select id, folio, payload into v_ticket_id, v_folio, v_ticket_payload from public.canonical_tickets where sale_id = v_existing_sale.id;
    return jsonb_build_object('sale_id', v_existing_sale.id, 'ticket_id', v_ticket_id, 'folio', v_folio, 'ticket', v_ticket_payload, 'idempotent', true);
  end if;
  raise;
end $$;

create or replace function public.close_cash_session(
  p_cash_session_id uuid,
  p_count_lines jsonb default '[]'::jsonb,
  p_variance_reason text default null,
  p_client_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.cash_sessions%rowtype;
  v_register public.cash_registers%rowtype;
  v_counted numeric;
  v_expected numeric;
  v_variance numeric;
  v_count_id uuid;
  v_request_id uuid := coalesce(p_client_request_id, gen_random_uuid());
begin
  select * into v_session from public.cash_sessions where id = p_cash_session_id for update;
  if not found then raise exception 'Sesión de caja no encontrada.'; end if;
  if v_session.close_request_id = v_request_id then return jsonb_build_object('cash_session_id', v_session.id, 'status', v_session.status, 'variance_amount', v_session.variance_amount, 'idempotent', true); end if;
  if v_session.status <> 'open' or v_session.opened_by <> auth.uid() then raise exception 'Solo el responsable puede cerrar una sesión de caja abierta.'; end if;
  perform public.assert_pos_access(v_session.company_id, v_session.location_id, 'close_own_cash_session');
  select * into v_register from public.cash_registers where id = v_session.cash_register_id;
  v_counted := public.cash_count_total(v_session.company_id, v_register.currency_code, p_count_lines);
  select coalesce(sum(amount), 0) into v_expected from public.cash_movements where cash_session_id = v_session.id;
  v_expected := round(v_expected, 2); v_variance := round(v_counted - v_expected, 2);
  if v_variance <> 0 and nullif(trim(coalesce(p_variance_reason, '')), '') is null then raise exception 'Toda diferencia de caja requiere un motivo.'; end if;
  insert into public.cash_counts(cash_session_id, count_type, total_amount, counted_by) values (v_session.id, 'closing', v_counted, auth.uid()) returning id into v_count_id;
  insert into public.cash_count_lines(cash_count_id, denomination_id, denomination_value, quantity)
  select v_count_id, denomination.id, denomination.value, input.quantity from jsonb_to_recordset(coalesce(p_count_lines, '[]'::jsonb)) as input(denomination_id uuid, quantity integer) join public.cash_denominations denomination on denomination.id = input.denomination_id;
  update public.cash_sessions set expected_closing_amount = v_expected, counted_closing_amount = v_counted, variance_amount = v_variance, close_requested_by = auth.uid(), variance_reason = nullif(trim(p_variance_reason), ''), close_request_id = v_request_id, status = case when v_variance = 0 then 'closed' else 'pending_variance_approval' end, closed_at = case when v_variance = 0 then now() else null end where id = v_session.id;
  perform public.write_sales_audit(v_session.company_id, case when v_variance = 0 then 'cash_session.closed' else 'cash_session.variance_pending' end, 'cash_sessions', v_session.id, jsonb_build_object('expected_amount', v_expected, 'counted_amount', v_counted, 'variance_amount', v_variance));
  return jsonb_build_object('cash_session_id', v_session.id, 'status', case when v_variance = 0 then 'closed' else 'pending_variance_approval' end, 'expected_amount', v_expected, 'counted_amount', v_counted, 'variance_amount', v_variance);
end $$;

create or replace function public.approve_cash_variance(
  p_cash_session_id uuid,
  p_approval_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.cash_sessions%rowtype;
begin
  select * into v_session from public.cash_sessions where id = p_cash_session_id for update;
  if not found or v_session.status <> 'pending_variance_approval' then raise exception 'No hay una diferencia de caja pendiente.'; end if;
  if auth.uid() = v_session.close_requested_by or not public.has_company_permission(v_session.company_id, 'approve_cash_variance') then raise exception 'Se requiere un aprobador autorizado distinto al responsable del cierre.'; end if;
  update public.cash_sessions set status = 'closed', closed_at = now(), variance_approved_by = auth.uid(), variance_approved_at = now(), variance_reason = coalesce(variance_reason, nullif(trim(p_approval_reason), '')) where id = v_session.id;
  perform public.write_sales_audit(v_session.company_id, 'cash_session.variance_approved', 'cash_sessions', v_session.id, jsonb_build_object('variance_amount', v_session.variance_amount));
  return jsonb_build_object('cash_session_id', v_session.id, 'status', 'closed', 'variance_amount', v_session.variance_amount);
end $$;

create or replace function public.record_receivable_payment(
  p_company_id uuid,
  p_customer_id uuid,
  p_payment_method_id uuid,
  p_amount numeric,
  p_cash_session_id uuid default null,
  p_client_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer public.customers%rowtype;
  v_method public.payment_methods%rowtype;
  v_session public.cash_sessions%rowtype;
  v_existing public.receivable_payments%rowtype;
  v_payment_id uuid;
  v_remaining numeric := round(coalesce(p_amount, 0), 2);
  v_total_open numeric;
  v_receivable record;
  v_applied numeric;
  v_request_id uuid := coalesce(p_client_request_id, gen_random_uuid());
begin
  if v_remaining <= 0 then raise exception 'El abono debe ser mayor a cero.'; end if;
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'record_receivable_payment') then raise exception 'No autorizado para registrar abonos.'; end if;
  select * into v_existing from public.receivable_payments where company_id = p_company_id and client_request_id = v_request_id;
  if found then return jsonb_build_object('payment_id', v_existing.id, 'amount', v_existing.amount, 'idempotent', true); end if;
  select * into v_customer from public.customers where id = p_customer_id and company_id = p_company_id for update;
  if not found then raise exception 'Cliente no encontrado.'; end if;
  select * into v_method from public.payment_methods where id = p_payment_method_id and company_id = p_company_id and is_active;
  if not found then raise exception 'Forma de pago no disponible.'; end if;
  if v_method.settlement_kind = 'cash_drawer' then
    select * into v_session from public.cash_sessions where id = p_cash_session_id and company_id = p_company_id and opened_by = auth.uid() and status = 'open' for share;
    if not found then raise exception 'El abono en efectivo requiere una sesión de caja abierta propia.'; end if;
    perform public.assert_pos_access(p_company_id, v_session.location_id, 'record_receivable_payment');
  elsif p_cash_session_id is not null then raise exception 'Una forma de pago externa no debe afectar una caja.'; end if;
  select coalesce(sum(outstanding_amount), 0) into v_total_open from public.customer_receivables where customer_id = p_customer_id;
  if v_remaining > v_total_open then raise exception 'El abono excede el saldo abierto del cliente.'; end if;
  insert into public.receivable_payments(company_id, customer_id, payment_method_id, payment_method_code, settlement_kind, cash_session_id, amount, client_request_id, received_by)
  values (p_company_id, p_customer_id, v_method.id, v_method.code, v_method.settlement_kind, case when v_method.settlement_kind = 'cash_drawer' then v_session.id else null end, v_remaining, v_request_id, auth.uid()) returning id into v_payment_id;
  for v_receivable in select * from public.customer_receivables where customer_id = p_customer_id and outstanding_amount > 0 order by due_date, issued_at, id for update loop
    exit when v_remaining = 0;
    v_applied := least(v_remaining, v_receivable.outstanding_amount);
    update public.customer_receivables set outstanding_amount = outstanding_amount - v_applied where id = v_receivable.id;
    insert into public.receivable_payment_applications(receivable_payment_id, receivable_id, amount) values (v_payment_id, v_receivable.id, v_applied);
    v_remaining := v_remaining - v_applied;
  end loop;
  if v_method.settlement_kind = 'cash_drawer' then insert into public.cash_movements(company_id, cash_session_id, movement_type, amount, actor_id, source_entity_type, source_entity_id) values (p_company_id, v_session.id, 'receivable_payment', p_amount, auth.uid(), 'receivable_payments', v_payment_id); end if;
  perform public.write_sales_audit(p_company_id, 'receivable_payment.recorded', 'receivable_payments', v_payment_id, jsonb_build_object('customer_id', p_customer_id, 'amount', p_amount));
  return jsonb_build_object('payment_id', v_payment_id, 'amount', p_amount, 'idempotent', false);
exception when unique_violation then
  select * into v_existing from public.receivable_payments where company_id = p_company_id and client_request_id = v_request_id;
  if found then return jsonb_build_object('payment_id', v_existing.id, 'amount', v_existing.amount, 'idempotent', true); end if;
  raise;
end $$;

create or replace function public.backfill_inventory_opening_balances(
  p_company_id uuid,
  p_after_snapshot_item_id uuid default null,
  p_page_size integer default 1000
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_size integer := least(greatest(coalesce(p_page_size, 1000), 1), 5000);
  v_processed integer := 0;
  v_next_cursor uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_locations') then raise exception 'No autorizado para inicializar inventario operativo.'; end if;
  with latest_snapshot_per_location as (
    select distinct on (item.location_id) item.location_id, snapshot.id as snapshot_id
    from public.inventory_snapshot_items item
    join public.inventory_snapshots snapshot on snapshot.id = item.snapshot_id
    where snapshot.company_id = p_company_id and snapshot.status = 'completed'
    order by item.location_id, snapshot.snapshot_date desc nulls last, snapshot.created_at desc
  ), paged as materialized (
    select item.id, item.location_id, item.product_id, coalesce(item.available_quantity, item.quantity) as quantity
    from public.inventory_snapshot_items item
    join latest_snapshot_per_location latest on latest.snapshot_id = item.snapshot_id
    where (p_after_snapshot_item_id is null or item.id > p_after_snapshot_item_id)
    order by item.id limit v_size
  ), inserted as (
    insert into public.inventory_ledger(company_id, location_id, product_id, quantity_delta, balance_after, movement_type, source_snapshot_item_id, actor_id)
    select p_company_id, paged.location_id, paged.product_id, paged.quantity, paged.quantity, 'opening_snapshot', paged.id, auth.uid()
    from paged where paged.quantity > 0
    on conflict (source_snapshot_item_id) where source_snapshot_item_id is not null do nothing
    returning location_id, product_id, quantity_delta
  ), applied as (
    insert into public.inventory_balances(company_id, location_id, product_id, quantity_on_hand)
    select p_company_id, location_id, product_id, quantity_delta from inserted
    on conflict (location_id, product_id) do update set quantity_on_hand = public.inventory_balances.quantity_on_hand + excluded.quantity_on_hand, updated_at = now()
    returning 1
  ) select (select count(*) from paged), (select max(id) from paged) into v_processed, v_next_cursor;
  perform public.write_sales_audit(p_company_id, 'inventory.opening_backfilled', 'inventory_ledger', null, jsonb_build_object('processed', v_processed, 'next_cursor', v_next_cursor));
  return jsonb_build_object('processed', coalesce(v_processed, 0), 'next_snapshot_item_id', v_next_cursor, 'complete', v_processed < v_size);
end $$;

create or replace function public.get_canonical_ticket(p_sale_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ticket public.canonical_tickets%rowtype;
begin
  select ticket.* into v_ticket from public.canonical_tickets ticket join public.sales sale_data on sale_data.id = ticket.sale_id where ticket.sale_id = p_sale_id;
  if not found or not public.has_company_permission(v_ticket.company_id, 'view_sales') or not public.can_access_location(v_ticket.location_id) then raise exception 'No autorizado para consultar este ticket.'; end if;
  return jsonb_build_object('ticket_id', v_ticket.id, 'folio', v_ticket.folio, 'schema_version', v_ticket.schema_version, 'content_sha256', v_ticket.content_sha256, 'issued_at', v_ticket.issued_at, 'payload', v_ticket.payload);
end $$;

create or replace function public.list_sales(
  p_company_id uuid,
  p_location_id uuid default null,
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 50), 1), 100);
  v_query text := lower(trim(coalesce(p_query, '')));
  v_total integer;
  v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_sales') then raise exception 'No autorizado.'; end if;
  if p_location_id is not null and not public.can_access_location(p_location_id) then raise exception 'No autorizado para esta ubicación.'; end if;
  with filtered as (
    select sale_data.id, sale_data.location_id, sale_data.sale_type, sale_data.currency_code, sale_data.total_amount, sale_data.completed_at, customer_data.display_name as customer_name, ticket.folio
    from public.sales sale_data
    join public.canonical_tickets ticket on ticket.sale_id = sale_data.id
    left join public.customers customer_data on customer_data.id = sale_data.customer_id
    where sale_data.company_id = p_company_id
      and public.can_access_location(sale_data.location_id)
      and (p_location_id is null or sale_data.location_id = p_location_id)
      and (v_query = '' or lower(ticket.folio) like '%' || v_query || '%' or lower(coalesce(customer_data.display_name, '')) like '%' || v_query || '%')
  ) select count(*) into v_total from filtered;
  with filtered as (
    select sale_data.id, sale_data.location_id, sale_data.sale_type, sale_data.currency_code, sale_data.total_amount, sale_data.completed_at, customer_data.display_name as customer_name, ticket.folio
    from public.sales sale_data join public.canonical_tickets ticket on ticket.sale_id = sale_data.id left join public.customers customer_data on customer_data.id = sale_data.customer_id
    where sale_data.company_id = p_company_id and public.can_access_location(sale_data.location_id) and (p_location_id is null or sale_data.location_id = p_location_id)
      and (v_query = '' or lower(ticket.folio) like '%' || v_query || '%' or lower(coalesce(customer_data.display_name, '')) like '%' || v_query || '%')
  ) select coalesce(jsonb_agg(jsonb_build_object('sale_id', paged.id, 'folio', paged.folio, 'location_id', paged.location_id, 'sale_type', paged.sale_type, 'customer_name', paged.customer_name, 'currency_code', paged.currency_code, 'total_amount', paged.total_amount, 'completed_at', paged.completed_at) order by paged.completed_at desc), '[]'::jsonb) into v_items from (select * from filtered order by completed_at desc limit v_size offset (v_page - 1) * v_size) paged;
  return jsonb_build_object('items', v_items, 'total', coalesce(v_total, 0), 'page', v_page, 'page_size', v_size);
end $$;

revoke all on function public.write_sales_audit(uuid, text, text, uuid, jsonb) from public;
revoke all on function public.assert_pos_access(uuid, uuid, text) from public;
revoke all on function public.resolve_pos_sale_price(uuid, uuid, uuid, uuid, timestamptz) from public;
revoke all on function public.cash_count_total(uuid, text, jsonb) from public;
grant execute on function public.search_pos_sale_products(uuid, uuid, uuid, text, integer, integer, timestamptz) to authenticated;
grant execute on function public.search_sale_customers(uuid, text, integer, integer) to authenticated;
grant execute on function public.upsert_sale_customer(uuid, uuid, text, text, text, text, text, uuid, boolean, numeric, integer) to authenticated;
grant execute on function public.get_pos_context(uuid) to authenticated;
grant execute on function public.open_cash_session(uuid, uuid, jsonb, uuid) to authenticated;
grant execute on function public.get_or_create_sale_cart(uuid, uuid) to authenticated;
grant execute on function public.change_sale_cart_item(uuid, uuid, numeric, integer) to authenticated;
grant execute on function public.set_sale_cart_customer(uuid, uuid, integer) to authenticated;
grant execute on function public.quote_sale_cart(uuid) to authenticated;
grant execute on function public.request_cart_discount(uuid, text, uuid, numeric, text, integer) to authenticated;
grant execute on function public.decide_cart_discount(uuid, boolean, text) to authenticated;
grant execute on function public.complete_sale(uuid, integer, text, uuid, numeric, uuid) to authenticated;
grant execute on function public.close_cash_session(uuid, jsonb, text, uuid) to authenticated;
grant execute on function public.approve_cash_variance(uuid, text) to authenticated;
grant execute on function public.record_receivable_payment(uuid, uuid, uuid, numeric, uuid, uuid) to authenticated;
grant execute on function public.backfill_inventory_opening_balances(uuid, uuid, integer) to authenticated;
grant execute on function public.get_canonical_ticket(uuid) to authenticated;
grant execute on function public.list_sales(uuid, uuid, text, integer, integer) to authenticated;
