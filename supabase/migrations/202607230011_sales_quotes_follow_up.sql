-- Satrapy · Fase 2: cotizaciones y seguimiento comercial.
-- Las cotizaciones no reservan inventario, no alteran precios vigentes y no generan ventas.

begin;

insert into public.permissions(code, description) values
  ('view_sales_quotes', 'Consultar cotizaciones comerciales de la empresa.'),
  ('manage_sales_quotes', 'Crear cotizaciones y registrar su seguimiento comercial.')
on conflict(code) do update set description = excluded.description;

insert into public.role_permissions(role_id, permission_id)
select role_data.id, permission_data.id
from public.roles role_data
join public.permissions permission_data on permission_data.code in ('view_sales_quotes', 'manage_sales_quotes')
where role_data.code in ('super_admin', 'direccion_admin', 'sucursal', 'punto_venta')
on conflict do nothing;

create table if not exists public.sales_quotes (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete restrict,
  customer_id uuid not null references public.customers(id) on delete restrict,
  folio text not null unique,
  status text not null default 'draft' check (status in ('draft', 'sent', 'accepted', 'not_converted')),
  currency_code text not null check (char_length(trim(currency_code)) = 3),
  valid_until date,
  subtotal_amount numeric(18,2) not null default 0 check (subtotal_amount >= 0),
  tax_amount numeric(18,2) not null default 0 check (tax_amount >= 0),
  total_amount numeric(18,2) not null default 0 check (total_amount >= 0),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_at timestamptz not null default now()
);
create index if not exists sales_quotes_company_status_idx on public.sales_quotes(company_id, status, updated_at desc, id desc);
create index if not exists sales_quotes_customer_idx on public.sales_quotes(company_id, customer_id, updated_at desc);
drop trigger if exists sales_quotes_updated_at on public.sales_quotes;
create trigger sales_quotes_updated_at before update on public.sales_quotes for each row execute function public.set_updated_at();

create table if not exists public.sales_quote_lines (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  quote_id uuid not null references public.sales_quotes(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  product_code text,
  product_name text not null,
  unit_name text,
  price_list_id uuid references public.price_lists(id) on delete restrict,
  quantity numeric(18,6) not null check (quantity > 0),
  unit_base_amount numeric(18,2) not null check (unit_base_amount >= 0),
  unit_tax_amount numeric(18,2) not null check (unit_tax_amount >= 0),
  unit_total_amount numeric(18,2) not null check (unit_total_amount >= 0),
  line_base_amount numeric(18,2) not null check (line_base_amount >= 0),
  line_tax_amount numeric(18,2) not null check (line_tax_amount >= 0),
  line_total_amount numeric(18,2) not null check (line_total_amount >= 0),
  created_at timestamptz not null default now(),
  unique(quote_id, product_id)
);
create index if not exists sales_quote_lines_quote_idx on public.sales_quote_lines(quote_id);

create table if not exists public.sales_quote_follow_ups (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  quote_id uuid not null references public.sales_quotes(id) on delete cascade,
  event_type text not null check (event_type in ('created', 'sent', 'accepted', 'not_converted', 'note')),
  reason_code text check (reason_code is null or reason_code in ('rejected_by_customer', 'cancelled_by_customer', 'lost_to_competition', 'no_follow_up_response', 'other')),
  note text,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  check ((event_type <> 'not_converted') or reason_code is not null)
);
create index if not exists sales_quote_follow_ups_quote_idx on public.sales_quote_follow_ups(quote_id, created_at desc, id desc);

alter table public.sales_quotes enable row level security;
alter table public.sales_quote_lines enable row level security;
alter table public.sales_quote_follow_ups enable row level security;

drop policy if exists sales_quotes_read on public.sales_quotes;
create policy sales_quotes_read on public.sales_quotes for select to authenticated using (
  public.has_company_permission(company_id, 'view_sales_quotes') and public.can_access_location(location_id)
);
drop policy if exists sales_quote_lines_read on public.sales_quote_lines;
create policy sales_quote_lines_read on public.sales_quote_lines for select to authenticated using (
  exists (select 1 from public.sales_quotes quote_data where quote_data.id = quote_id and public.has_company_permission(quote_data.company_id, 'view_sales_quotes') and public.can_access_location(quote_data.location_id))
);
drop policy if exists sales_quote_follow_ups_read on public.sales_quote_follow_ups;
create policy sales_quote_follow_ups_read on public.sales_quote_follow_ups for select to authenticated using (
  exists (select 1 from public.sales_quotes quote_data where quote_data.id = quote_id and public.has_company_permission(quote_data.company_id, 'view_sales_quotes') and public.can_access_location(quote_data.location_id))
);

create or replace function public.get_sales_quote_context(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_sales_quotes') then raise exception 'No autorizado para consultar cotizaciones.'; end if;
  return jsonb_build_object('locations', coalesce((
    select jsonb_agg(jsonb_build_object('id', location_data.id, 'name', location_data.name, 'code', location_data.external_code) order by location_data.name)
    from public.locations location_data where location_data.company_id = p_company_id and location_data.is_active and public.can_access_location(location_data.id)
  ), '[]'::jsonb));
end $$;

create or replace function public.search_sales_quote_customers(p_company_id uuid, p_query text default null, p_limit integer default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_query text := lower(trim(coalesce(p_query, ''))); v_limit integer := least(greatest(coalesce(p_limit, 30), 1), 50);
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_sales_quotes') then raise exception 'No autorizado para cotizar.'; end if;
  return jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_build_object('id', customer_data.id, 'code', customer_data.code, 'display_name', customer_data.display_name) order by customer_data.display_name)
    from (select * from public.customers where company_id = p_company_id and is_active and (v_query = '' or lower(code) like '%' || v_query || '%' or lower(display_name) like '%' || v_query || '%' or lower(coalesce(tax_id, '')) like '%' || v_query || '%') order by display_name limit v_limit) customer_data
  ), '[]'::jsonb));
end $$;

create or replace function public.search_sales_quote_products(p_company_id uuid, p_location_id uuid, p_customer_id uuid, p_query text default null, p_limit integer default 30)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_query text := lower(trim(regexp_replace(coalesce(p_query, ''), '\s+', ' ', 'g'))); v_limit integer := least(greatest(coalesce(p_limit, 30), 1), 50); v_price_list_id uuid; v_currency text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_sales_quotes') or not public.can_access_location(p_location_id) then raise exception 'No autorizado para cotizar en esta sucursal.'; end if;
  if not exists(select 1 from public.customers where id = p_customer_id and company_id = p_company_id and is_active) then raise exception 'Cliente no disponible.'; end if;
  select coalesce(customer_data.price_list_id, location_data.default_price_list_id, company_data.default_price_list_id) into v_price_list_id
  from public.companies company_data join public.locations location_data on location_data.id = p_location_id and location_data.company_id = company_data.id
  join public.customers customer_data on customer_data.id = p_customer_id where company_data.id = p_company_id;
  select currency_code into v_currency from public.price_lists where id = v_price_list_id and company_id = p_company_id and is_active and status = 'active';
  if v_currency is null then return jsonb_build_object('items', '[]'::jsonb); end if;
  return jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_build_object('product_id', item.id, 'code', coalesce(item.internal_sku, item.barcode), 'name', item.name, 'unit', item.unit, 'price_list_id', v_price_list_id, 'base_price_amount', item.amount, 'tax_amount', item.tax_amount, 'price_amount', item.total_amount, 'currency_code', v_currency) order by item.name)
    from (
      select product.id, product.name, product.internal_sku, product.barcode, product.unit, price.amount, round(price.amount * tax.rate, 2) tax_amount, round(price.amount * (1 + tax.rate), 2) total_amount
      from public.products product
      join public.product_prices price on price.product_id = product.id and price.price_list_id = v_price_list_id and price.currency_code = v_currency and price.valid_from <= now() and (price.valid_to is null or price.valid_to > now())
      join lateral (select rate from public.tax_rates where tax_category_id = product.tax_category_id and valid_from <= now() and (valid_to is null or valid_to > now()) order by valid_from desc limit 1) tax on true
      where product.company_id = p_company_id and product.is_active and product.is_sellable and not product.commercial_review_required and product.sales_unit_id is not null
        and (v_query = '' or not exists(select 1 from regexp_split_to_table(v_query, '\s+') token where token <> '' and not (lower(product.name) like '%' || token || '%' or lower(coalesce(product.internal_sku, '')) like '%' || token || '%' or lower(coalesce(product.barcode, '')) like '%' || token || '%' or exists(select 1 from public.product_aliases alias_data where alias_data.product_id = product.id and alias_data.normalized_value like '%' || token || '%'))))
      order by product.name limit v_limit
    ) item
  ), '[]'::jsonb));
end $$;

create or replace function public.list_sales_quotes(p_company_id uuid, p_query text default null, p_status text default null, p_page integer default 1, p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_query text := lower(trim(coalesce(p_query, ''))); v_page integer := greatest(coalesce(p_page, 1), 1); v_size integer := least(greatest(coalesce(p_page_size, 50), 1), 100); v_total integer; v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_sales_quotes') then raise exception 'No autorizado para consultar cotizaciones.'; end if;
  with filtered as materialized (
    select quote_data.*, customer_data.display_name customer_name, location_data.name location_name from public.sales_quotes quote_data join public.customers customer_data on customer_data.id = quote_data.customer_id join public.locations location_data on location_data.id = quote_data.location_id
    where quote_data.company_id = p_company_id and public.can_access_location(quote_data.location_id) and (p_status is null or quote_data.status = p_status) and (v_query = '' or lower(quote_data.folio) like '%' || v_query || '%' or lower(customer_data.display_name) like '%' || v_query || '%')
  ) select count(*) into v_total from filtered;
  with filtered as materialized (
    select quote_data.*, customer_data.display_name customer_name, location_data.name location_name from public.sales_quotes quote_data join public.customers customer_data on customer_data.id = quote_data.customer_id join public.locations location_data on location_data.id = quote_data.location_id
    where quote_data.company_id = p_company_id and public.can_access_location(quote_data.location_id) and (p_status is null or quote_data.status = p_status) and (v_query = '' or lower(quote_data.folio) like '%' || v_query || '%' or lower(customer_data.display_name) like '%' || v_query || '%')
  ) select coalesce(jsonb_agg(jsonb_build_object('id', item.id, 'folio', item.folio, 'status', item.status, 'customer_name', item.customer_name, 'location_name', item.location_name, 'currency_code', item.currency_code, 'total_amount', item.total_amount, 'valid_until', item.valid_until, 'updated_at', item.updated_at) order by item.updated_at desc), '[]'::jsonb) into v_items from (select * from filtered order by updated_at desc, id desc limit v_size offset (v_page - 1) * v_size) item;
  return jsonb_build_object('items', v_items, 'total', coalesce(v_total, 0), 'page', v_page, 'page_size', v_size);
end $$;

create or replace function public.get_sales_quote_detail(p_company_id uuid, p_quote_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_quote public.sales_quotes%rowtype;
begin
  select * into v_quote from public.sales_quotes where id = p_quote_id and company_id = p_company_id;
  if not found or not public.has_company_permission(p_company_id, 'view_sales_quotes') or not public.can_access_location(v_quote.location_id) then raise exception 'Cotización no disponible.'; end if;
  return jsonb_build_object(
    'id', v_quote.id, 'folio', v_quote.folio, 'status', v_quote.status, 'currency_code', v_quote.currency_code, 'valid_until', v_quote.valid_until, 'subtotal_amount', v_quote.subtotal_amount, 'tax_amount', v_quote.tax_amount, 'total_amount', v_quote.total_amount, 'updated_at', v_quote.updated_at,
    'customer', (select jsonb_build_object('id', customer_data.id, 'code', customer_data.code, 'display_name', customer_data.display_name) from public.customers customer_data where customer_data.id = v_quote.customer_id),
    'location', (select jsonb_build_object('id', location_data.id, 'name', location_data.name, 'code', location_data.external_code) from public.locations location_data where location_data.id = v_quote.location_id),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('id', line_data.id, 'product_id', line_data.product_id, 'product_code', line_data.product_code, 'product_name', line_data.product_name, 'unit_name', line_data.unit_name, 'quantity', line_data.quantity, 'unit_total_amount', line_data.unit_total_amount, 'line_total_amount', line_data.line_total_amount) order by line_data.created_at, line_data.id) from public.sales_quote_lines line_data where line_data.quote_id = v_quote.id), '[]'::jsonb),
    'follow_ups', coalesce((select jsonb_agg(jsonb_build_object('id', follow_up.id, 'event_type', follow_up.event_type, 'reason_code', follow_up.reason_code, 'note', follow_up.note, 'created_at', follow_up.created_at, 'actor_name', profile_data.full_name) order by follow_up.created_at desc, follow_up.id desc) from public.sales_quote_follow_ups follow_up left join public.profiles profile_data on profile_data.id = follow_up.created_by where follow_up.quote_id = v_quote.id), '[]'::jsonb)
  );
end $$;

create or replace function public.save_sales_quote(p_company_id uuid, p_quote_id uuid default null, p_location_id uuid default null, p_customer_id uuid default null, p_valid_until date default null, p_lines jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_quote public.sales_quotes%rowtype; v_price_list_id uuid; v_currency text; v_line jsonb; v_product public.products%rowtype; v_price numeric; v_rate numeric; v_quantity numeric; v_subtotal numeric := 0; v_tax numeric := 0; v_id uuid := coalesce(p_quote_id, gen_random_uuid()); v_folio text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_sales_quotes') or p_location_id is null or not public.can_access_location(p_location_id) then raise exception 'No autorizado para guardar esta cotización.'; end if;
  if not exists(select 1 from public.locations where id = p_location_id and company_id = p_company_id and is_active) then raise exception 'Sucursal no disponible.'; end if;
  if not exists(select 1 from public.customers where id = p_customer_id and company_id = p_company_id and is_active) then raise exception 'Cliente no disponible.'; end if;
  if jsonb_typeof(coalesce(p_lines, '[]'::jsonb)) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Agrega al menos un producto a la cotización.'; end if;
  if p_valid_until is not null and p_valid_until < current_date then raise exception 'La vigencia no puede estar en el pasado.'; end if;
  if p_quote_id is not null then select * into v_quote from public.sales_quotes where id = p_quote_id and company_id = p_company_id for update; if not found or v_quote.status <> 'draft' then raise exception 'Solo se pueden editar cotizaciones en borrador.'; end if; end if;
  select coalesce(customer_data.price_list_id, location_data.default_price_list_id, company_data.default_price_list_id) into v_price_list_id from public.companies company_data join public.locations location_data on location_data.id = p_location_id join public.customers customer_data on customer_data.id = p_customer_id where company_data.id = p_company_id;
  select currency_code into v_currency from public.price_lists where id = v_price_list_id and company_id = p_company_id and is_active and status = 'active';
  if v_currency is null then raise exception 'No hay una lista de precios vigente para esta cotización.'; end if;
  create temporary table quote_line_input(product_id uuid, quantity numeric) on commit drop;
  insert into quote_line_input(product_id, quantity) select input.product_id, input.quantity from jsonb_to_recordset(p_lines) as input(product_id uuid, quantity numeric);
  if exists(select 1 from quote_line_input where product_id is null or quantity is null or quantity <= 0) or (select count(*) from quote_line_input) <> (select count(distinct product_id) from quote_line_input) then raise exception 'Las partidas de la cotización no son válidas.'; end if;
  if p_quote_id is null then v_folio := 'COT-' || to_char(now(), 'YYMMDD') || '-' || upper(left(replace(v_id::text, '-', ''), 6)); insert into public.sales_quotes(id, company_id, location_id, customer_id, folio, currency_code, valid_until, created_by, updated_by) values(v_id, p_company_id, p_location_id, p_customer_id, v_folio, v_currency, p_valid_until, auth.uid(), auth.uid()); insert into public.sales_quote_follow_ups(company_id, quote_id, event_type, note) values(p_company_id, v_id, 'created', 'Borrador creado.'); else delete from public.sales_quote_lines where quote_id = v_id; end if;
  for v_line in select jsonb_build_object('product_id', product_id, 'quantity', quantity) from quote_line_input loop
    select * into v_product from public.products where id = (v_line ->> 'product_id')::uuid and company_id = p_company_id and is_active and is_sellable and not commercial_review_required and sales_unit_id is not null;
    if not found then raise exception 'Uno de los productos ya no está disponible para cotizar.'; end if;
    select amount into v_price from public.product_prices where product_id = v_product.id and price_list_id = v_price_list_id and currency_code = v_currency and valid_from <= now() and (valid_to is null or valid_to > now()) order by valid_from desc limit 1;
    select rate into v_rate from public.tax_rates where tax_category_id = v_product.tax_category_id and valid_from <= now() and (valid_to is null or valid_to > now()) order by valid_from desc limit 1;
    if coalesce(v_price, 0) <= 0 or v_rate is null then raise exception 'Uno de los productos no tiene precio total vigente.'; end if;
    v_quantity := (v_line ->> 'quantity')::numeric;
    insert into public.sales_quote_lines(company_id, quote_id, product_id, product_code, product_name, unit_name, price_list_id, quantity, unit_base_amount, unit_tax_amount, unit_total_amount, line_base_amount, line_tax_amount, line_total_amount)
    values(p_company_id, v_id, v_product.id, coalesce(v_product.internal_sku, v_product.barcode), v_product.name, v_product.unit, v_price_list_id, v_quantity, round(v_price, 2), round(v_price * v_rate, 2), round(v_price * (1 + v_rate), 2), round(v_price * v_quantity, 2), round(v_price * v_rate * v_quantity, 2), round(v_price * (1 + v_rate) * v_quantity, 2));
    v_subtotal := v_subtotal + round(v_price * v_quantity, 2); v_tax := v_tax + round(v_price * v_rate * v_quantity, 2);
  end loop;
  update public.sales_quotes set location_id = p_location_id, customer_id = p_customer_id, currency_code = v_currency, valid_until = p_valid_until, subtotal_amount = round(v_subtotal, 2), tax_amount = round(v_tax, 2), total_amount = round(v_subtotal + v_tax, 2), updated_by = auth.uid() where id = v_id;
  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata) values(p_company_id, auth.uid(), case when p_quote_id is null then 'sales_quote.created' else 'sales_quote.updated' end, 'sales_quote', v_id, jsonb_build_object('location_id', p_location_id, 'customer_id', p_customer_id, 'line_count', jsonb_array_length(p_lines), 'total_amount', round(v_subtotal + v_tax, 2)));
  return public.get_sales_quote_detail(p_company_id, v_id);
end $$;

create or replace function public.record_sales_quote_follow_up(p_company_id uuid, p_quote_id uuid, p_event_type text, p_reason_code text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_quote public.sales_quotes%rowtype; v_event text := trim(coalesce(p_event_type, '')); v_reason text := nullif(trim(coalesce(p_reason_code, '')), ''); v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  select * into v_quote from public.sales_quotes where id = p_quote_id and company_id = p_company_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_sales_quotes') or not public.can_access_location(v_quote.location_id) then raise exception 'Cotización no disponible.'; end if;
  if v_event not in ('sent', 'accepted', 'not_converted', 'note') then raise exception 'Seguimiento no válido.'; end if;
  if v_event = 'not_converted' and v_reason not in ('rejected_by_customer', 'cancelled_by_customer', 'lost_to_competition', 'no_follow_up_response', 'other') then raise exception 'Selecciona el motivo por el que no se concretó.'; end if;
  if v_event = 'not_converted' and v_reason = 'other' and v_note is null then raise exception 'Describe el motivo de cierre.'; end if;
  if v_quote.status in ('accepted', 'not_converted') then raise exception 'La cotización ya tiene un cierre registrado.'; end if;
  update public.sales_quotes set status = case v_event when 'sent' then 'sent' when 'accepted' then 'accepted' when 'not_converted' then 'not_converted' else status end, updated_by = auth.uid() where id = p_quote_id;
  insert into public.sales_quote_follow_ups(company_id, quote_id, event_type, reason_code, note) values(p_company_id, p_quote_id, v_event, case when v_event = 'not_converted' then v_reason else null end, v_note);
  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata) values(p_company_id, auth.uid(), 'sales_quote.follow_up_recorded', 'sales_quote', p_quote_id, jsonb_build_object('event_type', v_event, 'reason_code', v_reason, 'note', v_note));
  return public.get_sales_quote_detail(p_company_id, p_quote_id);
end $$;

grant execute on function public.get_sales_quote_context(uuid) to authenticated;
grant execute on function public.search_sales_quote_customers(uuid, text, integer) to authenticated;
grant execute on function public.search_sales_quote_products(uuid, uuid, uuid, text, integer) to authenticated;
grant execute on function public.list_sales_quotes(uuid, text, text, integer, integer) to authenticated;
grant execute on function public.get_sales_quote_detail(uuid, uuid) to authenticated;
grant execute on function public.save_sales_quote(uuid, uuid, uuid, uuid, date, jsonb) to authenticated;
grant execute on function public.record_sales_quote_follow_up(uuid, uuid, text, text, text) to authenticated;

commit;
