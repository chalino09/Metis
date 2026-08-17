-- Select an active commercial price list per POS cart without permitting free-form price edits.
-- The explicit choice is revision-safe, validated against every current line and audited.

alter table public.sale_carts
  add column if not exists price_list_id uuid references public.price_lists(id) on delete restrict;

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
  v_price public.product_prices%rowtype;
  v_currency_code text;
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
  where price_list.id = v_price_list_id and price_list.company_id = p_company_id and price_list.is_active and price_list.status = 'active';
  if not found then return null; end if;

  select * into v_price
  from public.product_prices price
  where price.product_id = p_product_id and price.price_list_id = v_price_list_id and price.currency_code = v_currency_code
    and price.valid_from <= p_at and (price.valid_to is null or price.valid_to > p_at)
  order by price.valid_from desc limit 1;
  if not found or v_price.amount <= 0 then return null; end if;
  return jsonb_build_object('price_list_id', v_price_list_id, 'amount', round(v_price.amount, 2), 'currency_code', v_currency_code, 'valid_from', v_price.valid_from);
end $$;

create or replace function public.list_pos_price_lists(p_cart_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_cart public.sale_carts%rowtype; v_currency text;
begin
  select * into v_cart from public.sale_carts where id = p_cart_id;
  if not found or v_cart.cashier_id <> auth.uid() or v_cart.status not in ('active','held') then raise exception 'Carrito no disponible.'; end if;
  perform public.assert_pos_access(v_cart.company_id, v_cart.location_id, 'use_pos');
  select currency_code into v_currency from public.cash_registers where id = v_cart.cash_register_id and company_id = v_cart.company_id and is_active;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', list.id, 'name', list.name, 'currency_code', list.currency_code) order by list.name, list.id)
    from public.price_lists list
    where list.company_id = v_cart.company_id and list.is_active and list.status = 'active' and list.currency_code = v_currency
  ), '[]'::jsonb);
end $$;

create or replace function public.set_sale_cart_price_list(
  p_cart_id uuid,
  p_price_list_id uuid default null,
  p_expected_revision integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cart public.sale_carts%rowtype;
  v_effective_list_id uuid;
  v_currency text;
  v_missing_product text;
  v_new_revision integer;
begin
  select * into v_cart from public.sale_carts where id = p_cart_id for update;
  if not found or v_cart.cashier_id <> auth.uid() or v_cart.status <> 'active' then raise exception 'Carrito no disponible.'; end if;
  perform public.assert_pos_access(v_cart.company_id, v_cart.location_id, 'use_pos');
  if p_expected_revision is not null and v_cart.revision <> p_expected_revision then raise exception 'El carrito cambió en otra operación; actualiza la vista.'; end if;

  select register.currency_code into v_currency from public.cash_registers register where register.id = v_cart.cash_register_id and register.company_id = v_cart.company_id and register.is_active;
  if p_price_list_id is not null and not exists (
    select 1 from public.price_lists list where list.id = p_price_list_id and list.company_id = v_cart.company_id and list.is_active and list.status = 'active' and list.currency_code = v_currency
  ) then raise exception 'La lista de precios no está disponible para esta caja.'; end if;

  select coalesce(p_price_list_id, customer.price_list_id, location.default_price_list_id, company.default_price_list_id)
  into v_effective_list_id
  from public.companies company
  join public.locations location on location.id = v_cart.location_id and location.company_id = company.id
  left join public.customers customer on customer.id = v_cart.customer_id and customer.company_id = company.id
  where company.id = v_cart.company_id;
  if v_effective_list_id is null then raise exception 'No hay una lista de precios efectiva para la venta.'; end if;

  select product.name into v_missing_product
  from public.sale_cart_items item
  join public.products product on product.id = item.product_id
  where item.cart_id = v_cart.id and not exists (
    select 1 from public.product_prices price
    where price.product_id = item.product_id and price.price_list_id = v_effective_list_id and price.currency_code = v_currency
      and price.amount > 0 and price.valid_from <= now() and (price.valid_to is null or price.valid_to > now())
  )
  order by product.name limit 1;
  if v_missing_product is not null then raise exception 'La lista seleccionada no tiene precio vigente para %.', v_missing_product; end if;

  update public.sale_carts set price_list_id = p_price_list_id, revision = revision + 1 where id = v_cart.id returning revision into v_new_revision;
  perform public.write_sales_audit(v_cart.company_id, 'sale_cart.price_list_changed', 'sale_carts', v_cart.id, jsonb_build_object(
    'previous_price_list_id', v_cart.price_list_id, 'selected_price_list_id', p_price_list_id, 'effective_price_list_id', v_effective_list_id, 'revision', v_new_revision
  ));
  return jsonb_build_object('cart_id', v_cart.id, 'revision', v_new_revision, 'price_list_id', p_price_list_id, 'effective_price_list_id', v_effective_list_id);
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
declare v_cart public.sale_carts%rowtype; v_new_revision integer;
begin
  select * into v_cart from public.sale_carts where id = p_cart_id for update;
  if not found or v_cart.cashier_id <> auth.uid() or v_cart.status <> 'active' then raise exception 'Carrito no disponible.'; end if;
  perform public.assert_pos_access(v_cart.company_id, v_cart.location_id, 'use_pos');
  if p_expected_revision is not null and v_cart.revision <> p_expected_revision then raise exception 'El carrito cambió en otra operación; actualiza la vista.'; end if;
  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id and company_id = v_cart.company_id and is_active) then raise exception 'Cliente no encontrado o inactivo.'; end if;
  update public.sale_carts set customer_id = p_customer_id, price_list_id = null, revision = revision + 1 where id = p_cart_id returning revision into v_new_revision;
  if v_cart.price_list_id is not null then
    perform public.write_sales_audit(v_cart.company_id, 'sale_cart.price_list_reset_for_customer', 'sale_carts', v_cart.id, jsonb_build_object(
      'previous_price_list_id', v_cart.price_list_id, 'customer_id', p_customer_id, 'revision', v_new_revision
    ));
  end if;
  return jsonb_build_object('cart_id', p_cart_id, 'revision', v_new_revision, 'customer_id', p_customer_id, 'price_list_id', null);
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
    if v_price is null then raise exception 'El producto % no tiene precio vigente en la lista efectiva.', v_item.name; end if;
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
  v_result := public.complete_sale(p_cart_id, p_expected_revision, p_sale_type, p_payment_method_id, p_received_amount, p_client_request_id);
  select ticket.payload into v_ticket_payload from public.canonical_tickets ticket where ticket.id = (v_result ->> 'ticket_id')::uuid;
  if v_ticket_payload is not null then v_result := jsonb_set(v_result, '{ticket}', v_ticket_payload, true); end if;
  return v_result;
end $$;

create or replace function public.search_pos_cart_products(
  p_cart_id uuid,
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 50,
  p_at timestamptz default now()
)
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare
  v_cart public.sale_carts%rowtype; v_page integer:=greatest(coalesce(p_page,1),1); v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);
  v_query text:=lower(trim(regexp_replace(coalesce(p_query,''),'\s+',' ','g'))); v_total integer; v_items jsonb; v_price_list_id uuid; v_currency_code text;
begin
  select * into v_cart from public.sale_carts where id=p_cart_id;
  if not found or v_cart.cashier_id<>auth.uid() or v_cart.status<>'active' then raise exception 'Carrito no disponible.';end if;
  perform public.assert_pos_access(v_cart.company_id,v_cart.location_id,'use_pos');
  select coalesce(v_cart.price_list_id,customer.price_list_id,location.default_price_list_id,company.default_price_list_id)
  into v_price_list_id from public.companies company join public.locations location on location.id=v_cart.location_id and location.company_id=company.id
  left join public.customers customer on customer.id=v_cart.customer_id and customer.company_id=company.id where company.id=v_cart.company_id;
  select list.currency_code into v_currency_code from public.price_lists list where list.id=v_price_list_id and list.company_id=v_cart.company_id and list.is_active and list.status='active';
  if v_currency_code is null then return jsonb_build_object('items','[]'::jsonb,'total',0,'page',v_page,'page_size',v_size,'price_list_id',v_price_list_id);end if;
  with candidate_ids as materialized (
    select distinct item.product_id from public.location_sales_assortments assignment
    join public.sales_assortments assortment on assortment.id=assignment.assortment_id
    join public.sales_assortment_items item on item.assortment_id=assortment.id
    where assignment.location_id=v_cart.location_id and assignment.valid_from<=p_at and (assignment.valid_to is null or assignment.valid_to>p_at)
      and assortment.company_id=v_cart.company_id and assortment.status='active' and (assortment.valid_from is null or assortment.valid_from<=p_at) and (assortment.valid_to is null or assortment.valid_to>p_at)
  ), matched as materialized (
    select product.*,case when v_query='' then 9 when lower(coalesce(product.barcode,''))=v_query then 1 when lower(coalesce(product.internal_sku,''))=v_query then 2
      when lower(coalesce(product.internal_sku,'')) like v_query||'%' then 3 when exists(select 1 from public.product_external_references reference where reference.product_id=product.id and lower(reference.external_code)=v_query) then 4 else 5 end rank
    from candidate_ids candidate join public.products product on product.id=candidate.product_id
    where product.company_id=v_cart.company_id and (v_query='' or not exists(select 1 from regexp_split_to_table(v_query,'\s+') token where token<>'' and not (
      lower(product.name) like '%'||token||'%' or lower(coalesce(product.internal_sku,'')) like '%'||token||'%' or lower(coalesce(product.barcode,''))=token
      or exists(select 1 from public.product_aliases alias where alias.product_id=product.id and alias.normalized_value like '%'||token||'%')
      or exists(select 1 from public.product_external_references reference where reference.product_id=product.id and lower(reference.external_code) like '%'||token||'%')
    )))
  ), eligible as materialized (
    select product.id,product.name,product.internal_sku,product.barcode,product.unit,product.is_inventory_tracked,coalesce(balance.quantity_on_hand,0) quantity_on_hand,
      price.amount base_price_amount,tax.rate tax_rate,round(price.amount*tax.rate,2) tax_amount,round(price.amount*(1+tax.rate),2) price_amount,product.rank
    from matched product left join public.inventory_balances balance on balance.location_id=v_cart.location_id and balance.product_id=product.id
    left join lateral (select product_price.amount from public.product_prices product_price where product_price.product_id=product.id and product_price.price_list_id=v_price_list_id
      and product_price.currency_code=v_currency_code and product_price.valid_from<=p_at and (product_price.valid_to is null or product_price.valid_to>p_at) order by product_price.valid_from desc limit 1) price on true
    left join lateral (select tax_rate.rate from public.tax_rates tax_rate where tax_rate.tax_category_id=product.tax_category_id and tax_rate.valid_from<=p_at
      and (tax_rate.valid_to is null or tax_rate.valid_to>p_at) order by tax_rate.valid_from desc limit 1) tax on true
    where product.is_active and product.is_sellable and not product.commercial_review_required and product.inventory_policy<>'unclassified'
      and product.sales_unit_id is not null and product.tax_category_id is not null and tax.rate is not null and coalesce(price.amount,0)>0
      and (not product.is_inventory_tracked or coalesce(balance.quantity_on_hand,0)>0)
  ), paged as (select * from eligible order by rank,name limit v_size offset (v_page-1)*v_size)
  select (select count(*) from eligible),coalesce((select jsonb_agg(jsonb_build_object(
    'product_id',product.id,'code',coalesce(product.internal_sku,product.barcode),'name',product.name,'unit',product.unit,'inventory_tracked',product.is_inventory_tracked,
    'quantity_on_hand',product.quantity_on_hand,'price_list_id',v_price_list_id,'base_price_amount',round(product.base_price_amount,2),'tax_rate',product.tax_rate,
    'tax_amount',product.tax_amount,'price_amount',product.price_amount,'currency_code',v_currency_code
  ) order by product.rank,product.name) from paged product),'[]'::jsonb) into v_total,v_items;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size,'price_list_id',v_price_list_id);
end $$;

create or replace function public.search_pos_cart_blocked_products(
  p_cart_id uuid,
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 30,
  p_at timestamptz default now()
)
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare
  v_cart public.sale_carts%rowtype; v_page integer:=greatest(coalesce(p_page,1),1); v_size integer:=least(greatest(coalesce(p_page_size,30),1),100);
  v_query text:=lower(trim(regexp_replace(coalesce(p_query,''),'\s+',' ','g'))); v_total integer; v_items jsonb; v_price_list_id uuid; v_currency_code text;
  v_can_view_inventory boolean;
begin
  select * into v_cart from public.sale_carts where id=p_cart_id;
  if not found or v_cart.cashier_id<>auth.uid() or v_cart.status<>'active' then raise exception 'Carrito no disponible.';end if;
  perform public.assert_pos_access(v_cart.company_id,v_cart.location_id,'use_pos');
  if v_query='' then return jsonb_build_object('items','[]'::jsonb,'total',0,'page',1,'page_size',v_size);end if;
  v_can_view_inventory:=public.has_company_permission(v_cart.company_id,'view_inventory');
  select coalesce(v_cart.price_list_id,customer.price_list_id,location.default_price_list_id,company.default_price_list_id)
  into v_price_list_id from public.companies company join public.locations location on location.id=v_cart.location_id and location.company_id=company.id
  left join public.customers customer on customer.id=v_cart.customer_id and customer.company_id=company.id where company.id=v_cart.company_id;
  select list.currency_code into v_currency_code from public.price_lists list where list.id=v_price_list_id and list.company_id=v_cart.company_id and list.is_active and list.status='active';
  with matching as materialized (
    select product.* from public.products product where product.company_id=v_cart.company_id and not exists(select 1 from regexp_split_to_table(v_query,'\s+') token where token<>'' and not (
      lower(product.name) like '%'||token||'%' or lower(coalesce(product.internal_sku,'')) like '%'||token||'%' or lower(coalesce(product.barcode,''))=token
      or exists(select 1 from public.product_aliases alias where alias.product_id=product.id and alias.normalized_value like '%'||token||'%')
      or exists(select 1 from public.product_external_references reference where reference.product_id=product.id and lower(reference.external_code) like '%'||token||'%')
    ))
  ), detailed as materialized (
    select product.id,product.name,product.internal_sku,product.barcode,product.unit,product.is_inventory_tracked,coalesce(balance.quantity_on_hand,0) quantity_on_hand,
      price.amount price_amount,coalesce(remote_stock.location_count,0) other_location_stock_count,coalesce(remote_stock.quantity_on_hand,0) other_location_stock_quantity,
      array_remove(array[
        case when not exists(select 1 from public.location_sales_assortments assignment join public.sales_assortments assortment on assortment.id=assignment.assortment_id
          join public.sales_assortment_items item on item.assortment_id=assortment.id and item.product_id=product.id where assignment.location_id=v_cart.location_id
          and assignment.valid_from<=p_at and (assignment.valid_to is null or assignment.valid_to>p_at) and assortment.company_id=v_cart.company_id and assortment.status='active'
          and (assortment.valid_from is null or assortment.valid_from<=p_at) and (assortment.valid_to is null or assortment.valid_to>p_at)) then 'outside_assortment' end,
        case when not product.is_active then 'inactive' end,case when not product.is_sellable then 'not_sellable' end,
        case when product.commercial_review_required then 'commercial_review_required' end,case when product.inventory_policy='unclassified' then 'inventory_setup_required' end,
        case when product.sales_unit_id is null then 'missing_sales_unit' end,case when product.tax_category_id is null then 'missing_tax_category' end,
        case when product.tax_category_id is not null and not exists(select 1 from public.tax_rates tax_rate where tax_rate.tax_category_id=product.tax_category_id
          and tax_rate.valid_from<=p_at and (tax_rate.valid_to is null or tax_rate.valid_to>p_at)) then 'missing_current_tax_rate' end,
        case when coalesce(price.amount,0)<=0 then 'missing_or_zero_price' end,case when product.is_inventory_tracked and coalesce(balance.quantity_on_hand,0)<=0 then 'out_of_stock' end
      ]::text[],null) blockers
    from matching product left join public.inventory_balances balance on balance.location_id=v_cart.location_id and balance.product_id=product.id
    left join lateral (select product_price.amount from public.product_prices product_price where product_price.product_id=product.id and product_price.price_list_id=v_price_list_id
      and product_price.currency_code=v_currency_code and product_price.valid_from<=p_at and (product_price.valid_to is null or product_price.valid_to>p_at) order by product_price.valid_from desc limit 1) price on true
    left join lateral (select count(*)::integer location_count,coalesce(sum(remote_balance.quantity_on_hand),0) quantity_on_hand from public.inventory_balances remote_balance
      join public.locations remote_location on remote_location.id=remote_balance.location_id where v_can_view_inventory and remote_balance.company_id=v_cart.company_id
      and remote_balance.product_id=product.id and remote_balance.location_id<>v_cart.location_id and remote_balance.quantity_on_hand>0 and remote_location.is_active
      and public.can_access_location(remote_location.id)) remote_stock on true
  ), blocked as materialized (select * from detailed where cardinality(blockers)>0), paged as (select * from blocked order by name,id limit v_size offset (v_page-1)*v_size)
  select (select count(*) from blocked),coalesce((select jsonb_agg(jsonb_build_object(
    'product_id',product.id,'code',coalesce(product.internal_sku,product.barcode),'name',product.name,'unit',product.unit,'inventory_tracked',product.is_inventory_tracked,
    'quantity_on_hand',product.quantity_on_hand,'price_amount',product.price_amount,'currency_code',v_currency_code,'other_location_stock_count',product.other_location_stock_count,
    'other_location_stock_quantity',product.other_location_stock_quantity,'blockers',to_jsonb(product.blockers)
  ) order by product.name,product.id) from paged product),'[]'::jsonb) into v_total,v_items;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size,'price_list_id',v_price_list_id);
end $$;

revoke all on function public.list_pos_price_lists(uuid) from public;
revoke all on function public.set_sale_cart_price_list(uuid,uuid,integer) from public;
revoke all on function public.search_pos_cart_products(uuid,text,integer,integer,timestamptz) from public;
revoke all on function public.search_pos_cart_blocked_products(uuid,text,integer,integer,timestamptz) from public;
grant execute on function public.list_pos_price_lists(uuid) to authenticated;
grant execute on function public.set_sale_cart_price_list(uuid,uuid,integer) to authenticated;
grant execute on function public.search_pos_cart_products(uuid,text,integer,integer,timestamptz) to authenticated;
grant execute on function public.search_pos_cart_blocked_products(uuid,text,integer,integer,timestamptz) to authenticated;
