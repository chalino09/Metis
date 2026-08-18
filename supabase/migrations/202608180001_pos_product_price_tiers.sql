-- Precios escalonados por producto para POS.
-- Un nivel representa un precio final por unidad dentro de un rango de cantidad.
-- Conserva las listas comerciales como fuente de precio y evita acumular un
-- descuento porcentual general cuando el producto ya tiene un precio escalonado.

begin;

create table if not exists public.product_price_quantity_tiers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  price_list_id uuid not null references public.price_lists(id) on delete restrict,
  min_quantity numeric(18,6) not null check (min_quantity > 0),
  max_quantity numeric(18,6),
  is_active boolean not null default true,
  source text not null default 'manual' check (source in ('alpha', 'manual')),
  source_import_batch_id uuid references public.import_batches(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (product_id, price_list_id),
  check (max_quantity is null or max_quantity >= min_quantity)
);

create index if not exists product_price_quantity_tiers_lookup_idx
  on public.product_price_quantity_tiers(product_id, is_active, min_quantity, max_quantity);

create extension if not exists btree_gist with schema extensions;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'product_price_quantity_tiers_no_overlap') then
    alter table public.product_price_quantity_tiers
      add constraint product_price_quantity_tiers_no_overlap
      exclude using gist (
        product_id with =,
        numrange(min_quantity, coalesce(max_quantity, 'infinity'::numeric), '[]') with &&
      ) where (is_active);
  end if;
end $$;

alter table public.product_price_quantity_tiers enable row level security;

drop policy if exists product_price_quantity_tiers_select on public.product_price_quantity_tiers;
create policy product_price_quantity_tiers_select on public.product_price_quantity_tiers
for select to authenticated using (
  public.has_company_permission(company_id, 'use_pos')
  or public.has_company_permission(company_id, 'view_prices')
);

drop policy if exists product_price_quantity_tiers_write on public.product_price_quantity_tiers;
create policy product_price_quantity_tiers_write on public.product_price_quantity_tiers
for all to authenticated using (public.has_company_permission(company_id, 'manage_prices'))
with check (public.has_company_permission(company_id, 'manage_prices'));

alter table public.sale_cart_items
  add column if not exists price_tier_override_id uuid references public.product_price_quantity_tiers(id) on delete restrict,
  add column if not exists price_tier_override_reason text,
  add column if not exists price_tier_override_by uuid references auth.users(id) on delete set null,
  add column if not exists price_tier_override_at timestamptz;

create or replace function public.apply_pos_volume_discount_to_cart_item()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_company_id uuid; v_tier jsonb;
begin
  if new.discount_status <> 'none' then return new; end if;
  select company_id into v_company_id from public.sale_carts where id = new.cart_id;

  -- Los precios por escala ya son precios finales. Aplicar además la política
  -- porcentual de empresa produciría un doble descuento no autorizado.
  if exists (
    select 1
    from public.product_price_quantity_tiers tier
    where tier.company_id = v_company_id
      and tier.product_id = new.product_id
      and tier.is_active
  ) then
    new.discount_percent := 0;
    new.discount_reason := null;
    return new;
  end if;

  v_tier:=public.pos_volume_discount_for_quantity(v_company_id,new.quantity);
  new.discount_percent:=coalesce((v_tier->>'discount_percent')::numeric,0);
  new.discount_reason:=case when new.discount_percent>0 then 'volume:'||(v_tier->>'tier_number') else null end;
  return new;
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
  v_context_price_list_id uuid := nullif(current_setting('satrapy.pos_price_list_id', true), '')::uuid;
  v_cart_id uuid := nullif(current_setting('satrapy.pos_cart_id', true), '')::uuid;
  v_cart_currency text;
  v_quantity numeric;
  v_override_id uuid;
  v_has_product_tiers boolean := false;
  v_price public.product_prices%rowtype;
  v_currency_code text;
  v_tier_id uuid;
  v_tier_list_id uuid;
  v_tier_name text;
  v_tier_min numeric;
  v_tier_max numeric;
  v_tier_mode text;
  v_available_tiers jsonb := '[]'::jsonb;
begin
  if p_product_id is null then raise exception 'Producto requerido.'; end if;
  if not exists (select 1 from public.products where id = p_product_id and company_id = p_company_id) then raise exception 'Producto no encontrado.'; end if;
  if not exists (select 1 from public.locations where id = p_location_id and company_id = p_company_id) then raise exception 'Ubicación no encontrada.'; end if;
  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id and company_id = p_company_id and is_active) then raise exception 'Cliente no encontrado o inactivo.'; end if;

  select coalesce(v_context_price_list_id, customer_data.price_list_id, location_data.default_price_list_id, company_data.default_price_list_id)
  into v_price_list_id
  from public.companies company_data
  join public.locations location_data on location_data.id = p_location_id and location_data.company_id = company_data.id
  left join public.customers customer_data on customer_data.id = p_customer_id and customer_data.company_id = company_data.id
  where company_data.id = p_company_id;

  if v_price_list_id is null then return null; end if;
  select price_list.currency_code into v_currency_code
  from public.price_lists price_list
  where price_list.id = v_price_list_id
    and price_list.company_id = p_company_id
    and price_list.is_active
    and price_list.status = 'active';
  if not found then return null; end if;

  if v_cart_id is not null then
    select item.quantity, item.price_tier_override_id, register.currency_code
    into v_quantity, v_override_id, v_cart_currency
    from public.sale_cart_items item
    join public.sale_carts cart on cart.id = item.cart_id
    join public.cash_registers register on register.id = cart.cash_register_id
    where item.cart_id = v_cart_id
      and item.product_id = p_product_id
      and cart.company_id = p_company_id
      and cart.location_id = p_location_id;

    if found then
      v_has_product_tiers := exists (
        select 1
        from public.product_price_quantity_tiers tier
        where tier.company_id = p_company_id
          and tier.product_id = p_product_id
          and tier.is_active
      );

      select coalesce(jsonb_agg(jsonb_build_object(
        'id', tier.id,
        'name', list.name,
        'min_quantity', tier.min_quantity,
        'max_quantity', tier.max_quantity,
        'amount', round(price.amount, 2),
        'price_list_id', list.id
      ) order by tier.min_quantity, tier.max_quantity nulls last, list.name), '[]'::jsonb)
      into v_available_tiers
      from public.product_price_quantity_tiers tier
      join public.price_lists list on list.id = tier.price_list_id
      join lateral (
        select product_price.amount
        from public.product_prices product_price
        where product_price.product_id = tier.product_id
          and product_price.price_list_id = tier.price_list_id
          and product_price.currency_code = v_cart_currency
          and product_price.amount > 0
          and product_price.valid_from <= p_at
          and (product_price.valid_to is null or product_price.valid_to > p_at)
        order by product_price.valid_from desc
        limit 1
      ) price on true
      where tier.company_id = p_company_id
        and tier.product_id = p_product_id
        and tier.is_active
        and list.is_active
        and list.status = 'active'
        and list.currency_code = v_cart_currency;

      if v_override_id is not null then
        select tier.id, tier.price_list_id, list.name, tier.min_quantity, tier.max_quantity, 'manual'
        into v_tier_id, v_tier_list_id, v_tier_name, v_tier_min, v_tier_max, v_tier_mode
        from public.product_price_quantity_tiers tier
        join public.price_lists list on list.id = tier.price_list_id
        where tier.id = v_override_id
          and tier.company_id = p_company_id
          and tier.product_id = p_product_id
          and tier.is_active
          and list.is_active
          and list.status = 'active'
          and list.currency_code = v_cart_currency;
      elsif v_has_product_tiers then
        select tier.id, tier.price_list_id, list.name, tier.min_quantity, tier.max_quantity, 'automatic'
        into v_tier_id, v_tier_list_id, v_tier_name, v_tier_min, v_tier_max, v_tier_mode
        from public.product_price_quantity_tiers tier
        join public.price_lists list on list.id = tier.price_list_id
        where tier.company_id = p_company_id
          and tier.product_id = p_product_id
          and tier.is_active
          and v_quantity >= tier.min_quantity
          and (tier.max_quantity is null or v_quantity <= tier.max_quantity)
          and list.is_active
          and list.status = 'active'
          and list.currency_code = v_cart_currency
        order by tier.min_quantity desc, tier.id
        limit 1;
      end if;

      if v_tier_id is not null then
        select * into v_price
        from public.product_prices price
        where price.product_id = p_product_id
          and price.price_list_id = v_tier_list_id
          and price.currency_code = v_cart_currency
          and price.amount > 0
          and price.valid_from <= p_at
          and (price.valid_to is null or price.valid_to > p_at)
        order by price.valid_from desc
        limit 1;
        if not found then return null; end if;
        return jsonb_build_object(
          'price_list_id', v_tier_list_id,
          'amount', round(v_price.amount, 2),
          'currency_code', v_cart_currency,
          'valid_from', v_price.valid_from,
          'price_tier_id', v_tier_id,
          'price_tier_name', v_tier_name,
          'price_tier_min_quantity', v_tier_min,
          'price_tier_max_quantity', v_tier_max,
          'price_tier_mode', v_tier_mode,
          'available_price_tiers', v_available_tiers
        );
      end if;

      -- Si el producto tiene escalas configuradas, un hueco o una lista sin
      -- precio debe bloquear el cobro. Nunca se adivina un precio de respaldo.
      if v_has_product_tiers then return null; end if;
    end if;
  end if;

  select * into v_price
  from public.product_prices price
  where price.product_id = p_product_id and price.price_list_id = v_price_list_id and price.currency_code = v_currency_code
    and price.valid_from <= p_at and (price.valid_to is null or price.valid_to > p_at)
  order by price.valid_from desc limit 1;
  if not found or v_price.amount <= 0 then return null; end if;
  return jsonb_build_object(
    'price_list_id', v_price_list_id,
    'amount', round(v_price.amount, 2),
    'currency_code', v_currency_code,
    'valid_from', v_price.valid_from,
    'price_tier_mode', 'automatic',
    'available_price_tiers', '[]'::jsonb
  );
end $$;

create or replace function public.set_sale_cart_item_price_tier(
  p_cart_id uuid,
  p_cart_item_id uuid,
  p_price_tier_id uuid default null,
  p_expected_revision integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cart public.sale_carts%rowtype;
  v_item public.sale_cart_items%rowtype;
  v_register_currency text;
  v_tier public.product_price_quantity_tiers%rowtype;
  v_new_revision integer;
begin
  select * into v_cart from public.sale_carts where id = p_cart_id for update;
  if not found or v_cart.cashier_id <> auth.uid() or v_cart.status <> 'active' then raise exception 'Carrito no disponible.'; end if;
  perform public.assert_pos_access(v_cart.company_id, v_cart.location_id, 'apply_discount');
  if p_expected_revision is not null and v_cart.revision <> p_expected_revision then raise exception 'El carrito cambió en otra operación; actualiza la vista.'; end if;

  select * into v_item from public.sale_cart_items where id = p_cart_item_id and cart_id = v_cart.id for update;
  if not found then raise exception 'Partida no disponible.'; end if;
  select currency_code into v_register_currency from public.cash_registers where id = v_cart.cash_register_id and company_id = v_cart.company_id and is_active;
  if v_register_currency is null then raise exception 'La caja no tiene moneda disponible.'; end if;

  if p_price_tier_id is not null then
    select * into v_tier
    from public.product_price_quantity_tiers tier
    where tier.id = p_price_tier_id
      and tier.company_id = v_cart.company_id
      and tier.product_id = v_item.product_id
      and tier.is_active;
    if not found then raise exception 'El nivel de precio no corresponde a esta partida.'; end if;
    if not exists (
      select 1
      from public.price_lists list
      join public.product_prices price on price.price_list_id = list.id and price.product_id = v_item.product_id
      where list.id = v_tier.price_list_id
        and list.company_id = v_cart.company_id
        and list.is_active
        and list.status = 'active'
        and list.currency_code = v_register_currency
        and price.amount > 0
        and price.currency_code = v_register_currency
        and price.valid_from <= now()
        and (price.valid_to is null or price.valid_to > now())
    ) then raise exception 'El nivel seleccionado no tiene precio vigente para esta caja.'; end if;
  end if;

  update public.sale_cart_items
  set price_tier_override_id = p_price_tier_id,
      price_tier_override_reason = case when p_price_tier_id is null then null else 'Selección manual de nivel de precio' end,
      price_tier_override_by = case when p_price_tier_id is null then null else auth.uid() end,
      price_tier_override_at = case when p_price_tier_id is null then null else now() end,
      updated_at = now()
  where id = v_item.id;

  update public.sale_carts set revision = revision + 1, updated_at = now() where id = v_cart.id returning revision into v_new_revision;
  perform public.write_sales_audit(
    v_cart.company_id,
    case when p_price_tier_id is null then 'sale_cart_item.price_tier_restored' else 'sale_cart_item.price_tier_selected' end,
    'sale_cart_items',
    v_item.id,
    jsonb_build_object('cart_id', v_cart.id, 'product_id', v_item.product_id, 'price_tier_id', p_price_tier_id, 'revision', v_new_revision)
  );
  return jsonb_build_object('cart_id', v_cart.id, 'cart_item_id', v_item.id, 'price_tier_id', p_price_tier_id, 'revision', v_new_revision);
end $$;

create or replace function public.quote_sale_cart(p_cart_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_cart public.sale_carts%rowtype; v_item record; v_price jsonb; v_currency text := null; v_rate numeric; v_gross numeric; v_discount numeric;
  v_taxable numeric; v_tax numeric; v_total numeric; v_effective_discount numeric; v_items jsonb := '[]'::jsonb; v_subtotal numeric := 0;
  v_discount_total numeric := 0; v_tax_total numeric := 0; v_grand_total numeric := 0; v_pending boolean := false;
  v_effective_price_list_id uuid; v_price_list_name text;
begin
  select * into v_cart from public.sale_carts where id = p_cart_id;
  if not found or (v_cart.cashier_id <> auth.uid() and not public.has_company_permission(v_cart.company_id, 'view_sales')) then raise exception 'Carrito no disponible.'; end if;
  perform public.assert_pos_access(v_cart.company_id, v_cart.location_id, 'use_pos');
  perform set_config('satrapy.pos_cart_id', v_cart.id::text, true);
  select coalesce(v_cart.price_list_id, customer.price_list_id, location.default_price_list_id, company.default_price_list_id)
  into v_effective_price_list_id from public.companies company
  join public.locations location on location.id = v_cart.location_id and location.company_id = company.id
  left join public.customers customer on customer.id = v_cart.customer_id and customer.company_id = company.id
  where company.id = v_cart.company_id;
  select name, currency_code into v_price_list_name, v_currency from public.price_lists
  where id = v_effective_price_list_id and company_id = v_cart.company_id and is_active and status = 'active';

  for v_item in
    select item.*, product.name, product.internal_sku, product.unit, product.tax_category_id, product.is_inventory_tracked, coalesce(balance.quantity_on_hand, 0) as quantity_on_hand
    from public.sale_cart_items item join public.products product on product.id = item.product_id
    left join public.inventory_balances balance on balance.location_id = v_cart.location_id and balance.product_id = item.product_id
    where item.cart_id = v_cart.id order by item.product_id
  loop
    if v_item.discount_status = 'pending' or v_cart.sale_discount_status = 'pending' then v_pending := true; end if;
    perform set_config('satrapy.pos_price_list_id', coalesce(v_effective_price_list_id::text, ''), true);
    v_price := public.resolve_pos_sale_price(v_cart.company_id, v_cart.location_id, v_cart.customer_id, v_item.product_id, now());
    if v_price is null then raise exception 'El producto % no tiene un precio escalonado vigente para esta cantidad.', v_item.name; end if;
    if v_currency is null then v_currency := v_price ->> 'currency_code'; elsif v_currency <> v_price ->> 'currency_code' then raise exception 'No se permite mezclar monedas en una venta.'; end if;
    select rate into v_rate from public.tax_rates where tax_category_id = v_item.tax_category_id and valid_from <= now() and (valid_to is null or valid_to > now()) order by valid_from desc limit 1;
    if not found then raise exception 'El producto no tiene una tasa de impuesto vigente.'; end if;
    v_gross := round((v_price ->> 'amount')::numeric * v_item.quantity, 2);
    v_effective_discount := 100 - ((100 - v_item.discount_percent) * (100 - v_cart.sale_discount_percent) / 100);
    v_discount := round(v_gross * v_effective_discount / 100, 2); v_taxable := v_gross - v_discount; v_tax := round(v_taxable * v_rate, 2); v_total := v_taxable + v_tax;
    v_subtotal := v_subtotal + v_gross; v_discount_total := v_discount_total + v_discount; v_tax_total := v_tax_total + v_tax; v_grand_total := v_grand_total + v_total;
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'cart_item_id', v_item.id, 'product_id', v_item.product_id, 'code', v_item.internal_sku, 'name', v_item.name, 'unit', v_item.unit,
      'quantity', v_item.quantity, 'inventory_tracked', v_item.is_inventory_tracked, 'quantity_on_hand', v_item.quantity_on_hand,
      'price_list_id', v_price -> 'price_list_id', 'unit_price_amount', v_price -> 'amount', 'currency_code', v_currency,
      'price_tier_id', v_price -> 'price_tier_id', 'price_tier_name', v_price -> 'price_tier_name',
      'price_tier_min_quantity', v_price -> 'price_tier_min_quantity', 'price_tier_max_quantity', v_price -> 'price_tier_max_quantity',
      'price_tier_mode', v_price -> 'price_tier_mode', 'available_price_tiers', coalesce(v_price -> 'available_price_tiers', '[]'::jsonb),
      'discount_percent', round(v_effective_discount, 2), 'gross_amount', v_gross, 'discount_amount', v_discount,
      'taxable_amount', v_taxable, 'tax_rate', v_rate, 'tax_amount', v_tax, 'total_amount', v_total
    ));
  end loop;
  return jsonb_build_object(
    'cart_id', v_cart.id, 'revision', v_cart.revision, 'customer_id', v_cart.customer_id, 'currency_code', v_currency, 'items', v_items,
    'price_list_id', v_effective_price_list_id, 'price_list_name', v_price_list_name, 'price_list_override_id', v_cart.price_list_id,
    'price_list_overridden', v_cart.price_list_id is not null,
    'subtotal_amount', round(v_subtotal, 2), 'discount_amount', round(v_discount_total, 2), 'tax_amount', round(v_tax_total, 2),
    'total_amount', round(v_grand_total, 2), 'can_checkout', jsonb_array_length(v_items) > 0 and not v_pending, 'pending_discount_approval', v_pending
  );
end $$;

create or replace function public.complete_pos_sale(
  p_cart_id uuid,
  p_expected_revision integer,
  p_sale_type text,
  p_payment_method_id uuid default null,
  p_received_amount numeric default null,
  p_client_request_id uuid default null,
  p_payment_reference text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cart public.sale_carts%rowtype; v_method public.payment_methods%rowtype; v_reference text := nullif(trim(coalesce(p_payment_reference, '')), '');
  v_result jsonb; v_ticket_payload jsonb;
begin
  select * into v_cart from public.sale_carts where id = p_cart_id and cashier_id = auth.uid();
  if not found then raise exception 'Carrito no disponible.'; end if;
  if p_sale_type = 'cash' then
    select * into v_method from public.payment_methods where id = p_payment_method_id and company_id = v_cart.company_id and is_active;
    if not found then raise exception 'Forma de pago no disponible.'; end if;
    if v_method.settlement_kind = 'external' and v_reference is null then raise exception 'Captura la autorización o referencia del cobro externo.'; end if;
  else v_reference := null;
  end if;
  perform set_config('satrapy.pos_payment_reference', coalesce(v_reference, ''), true);
  perform set_config('satrapy.pos_price_list_id', coalesce(v_cart.price_list_id::text, ''), true);
  perform set_config('satrapy.pos_cart_id', v_cart.id::text, true);
  v_result := public.complete_sale(p_cart_id, p_expected_revision, p_sale_type, p_payment_method_id, p_received_amount, p_client_request_id);
  select ticket.payload into v_ticket_payload from public.canonical_tickets ticket where ticket.id = (v_result ->> 'ticket_id')::uuid;
  if v_ticket_payload is not null then v_result := jsonb_set(v_result, '{ticket}', v_ticket_payload, true); end if;
  return v_result;
end $$;

revoke all on function public.set_sale_cart_item_price_tier(uuid, uuid, uuid, integer) from public;
grant execute on function public.set_sale_cart_item_price_tier(uuid, uuid, uuid, integer) to authenticated;

-- Los rangos vienen del catálogo de productos Alpha (precN, desdN, hastN).
-- El reporte rprecprd sigue siendo la fuente de vigencia e importe; aquí solo
-- se conserva la escala, de manera que una actualización de precio no borra
-- los límites de cantidad.
create or replace function public.sync_alpha_product_price_tiers_from_batch(p_import_batch_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch public.import_batches%rowtype;
  v_synced integer := 0;
begin
  select * into v_batch
  from public.import_batches
  where id = p_import_batch_id;
  if not found or v_batch.import_type <> 'products' then return 0; end if;

  insert into public.product_price_quantity_tiers(
    company_id, product_id, price_list_id, min_quantity, max_quantity,
    is_active, source, source_import_batch_id, created_by, updated_by, updated_at
  )
  select
    v_batch.company_id,
    product.id,
    list.id,
    tier."minQuantity",
    nullif(tier."maxQuantity", 0),
    true,
    'alpha',
    v_batch.id,
    auth.uid(),
    auth.uid(),
    now()
  from public.import_staging_rows staged
  join public.products product
    on product.company_id = v_batch.company_id
   and product.alpha_sku = staged.normalized_data ->> 'alphaSku'
  cross join lateral jsonb_to_recordset(coalesce(staged.normalized_data -> 'priceTiers', '[]'::jsonb))
    as tier("listNumber" integer, "minQuantity" numeric, "maxQuantity" numeric)
  join public.price_lists list
    on list.company_id = v_batch.company_id
   and list.external_code = 'ALPHA_LIST_' || tier."listNumber"::text
   and list.is_active
   and list.status = 'active'
  where staged.import_batch_id = v_batch.id
    and staged.detected_type = 'products'
    and coalesce((staged.normalized_data ->> 'rejected')::boolean, false) = false
    and tier."minQuantity" > 0
    and (tier."maxQuantity" is null or tier."maxQuantity" = 0 or tier."maxQuantity" >= tier."minQuantity")
    and exists (
      select 1
      from public.product_prices price
      where price.product_id = product.id
        and price.price_list_id = list.id
        and price.amount > 0
        and price.valid_from <= now()
        and (price.valid_to is null or price.valid_to > now())
    )
  on conflict (product_id, price_list_id) do update
    set min_quantity = excluded.min_quantity,
        max_quantity = excluded.max_quantity,
        is_active = true,
        source = 'alpha',
        source_import_batch_id = excluded.source_import_batch_id,
        updated_by = auth.uid(),
        updated_at = now();
  get diagnostics v_synced = row_count;
  return v_synced;
end $$;

alter function public.confirm_staged_import(uuid) rename to confirm_staged_import_before_price_tiers;

create function public.confirm_staged_import(p_import_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_batch public.import_batches%rowtype;
  v_synced integer := 0;
begin
  v_result := public.confirm_staged_import_before_price_tiers(p_import_batch_id);
  if coalesce(v_result ->> 'status', '') <> 'completed' then return v_result; end if;
  select * into v_batch from public.import_batches where id = p_import_batch_id;
  if v_batch.import_type <> 'products' then return v_result; end if;
  v_synced := public.sync_alpha_product_price_tiers_from_batch(v_batch.id);
  if v_synced > 0 then
    perform public.write_sales_audit(
      v_batch.company_id,
      'product_price_tiers.alpha_imported',
      'import_batches',
      v_batch.id,
      jsonb_build_object('tiers_synced', v_synced, 'source', 'alpha')
    );
  end if;
  return v_result || jsonb_build_object('price_tiers_synced', v_synced);
end $$;

alter function public.confirm_commercial_import(uuid) rename to confirm_commercial_import_before_price_tiers;

create function public.confirm_commercial_import(p_import_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_batch public.import_batches%rowtype;
  v_catalog_batch_id uuid;
  v_synced integer := 0;
begin
  v_result := public.confirm_commercial_import_before_price_tiers(p_import_batch_id);
  if coalesce(v_result ->> 'status', '') <> 'completed' then return v_result; end if;
  select * into v_batch from public.import_batches where id = p_import_batch_id;
  if v_batch.import_type <> 'prices' then return v_result; end if;
  select batch.id into v_catalog_batch_id
  from public.import_batches batch
  where batch.company_id = v_batch.company_id
    and batch.import_type = 'products'
    and batch.status = 'completed'
  order by batch.completed_at desc nulls last, batch.created_at desc
  limit 1;
  if v_catalog_batch_id is not null then
    v_synced := public.sync_alpha_product_price_tiers_from_batch(v_catalog_batch_id);
  end if;
  if v_synced > 0 then
    perform public.write_sales_audit(
      v_batch.company_id,
      'product_price_tiers.alpha_imported',
      'import_batches',
      v_batch.id,
      jsonb_build_object('tiers_synced', v_synced, 'catalog_batch_id', v_catalog_batch_id, 'source', 'alpha')
    );
  end if;
  return v_result || jsonb_build_object('price_tiers_synced', v_synced);
end $$;

revoke all on function public.sync_alpha_product_price_tiers_from_batch(uuid) from public;
revoke all on function public.confirm_staged_import(uuid) from public;
revoke all on function public.confirm_commercial_import(uuid) from public;
grant execute on function public.confirm_staged_import(uuid), public.confirm_commercial_import(uuid) to authenticated;

notify pgrst, 'reload schema';

commit;
