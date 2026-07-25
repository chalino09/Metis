-- POS: muestra disponibilidad remota junto con productos agotados localmente.
-- Es una consulta de sólo lectura: el carrito continúa validando únicamente la
-- existencia de la sucursal activa.

create or replace function public.search_pos_blocked_products(
  p_company_id uuid,
  p_location_id uuid,
  p_customer_id uuid default null,
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 30,
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
  v_size integer := least(greatest(coalesce(p_page_size, 30), 1), 100);
  v_query text := lower(trim(regexp_replace(coalesce(p_query, ''), '\s+', ' ', 'g')));
  v_total integer;
  v_items jsonb;
  v_price_list_id uuid;
  v_currency_code text;
  v_can_view_inventory boolean := public.has_company_permission(p_company_id, 'view_inventory');
begin
  perform public.assert_pos_access(p_company_id, p_location_id, 'use_pos');
  if v_query = '' then
    return jsonb_build_object('items', '[]'::jsonb, 'total', 0, 'page', 1, 'page_size', v_size);
  end if;
  if p_customer_id is not null and not exists (
    select 1 from public.customers customer
    where customer.id = p_customer_id and customer.company_id = p_company_id and customer.is_active
  ) then raise exception 'Cliente no encontrado o inactivo.'; end if;

  select coalesce(customer.price_list_id, location.default_price_list_id, company.default_price_list_id)
  into v_price_list_id
  from public.companies company
  join public.locations location on location.id = p_location_id and location.company_id = company.id
  left join public.customers customer on customer.id = p_customer_id
  where company.id = p_company_id;

  select price_list.currency_code into v_currency_code
  from public.price_lists price_list
  where price_list.id = v_price_list_id and price_list.company_id = p_company_id and price_list.is_active and price_list.status = 'active';

  with matching as materialized (
    select product.* from public.products product
    where product.company_id = p_company_id
      and not exists (
        select 1 from regexp_split_to_table(v_query, '\s+') token
        where token <> '' and not (
          lower(product.name) like '%' || token || '%'
          or lower(coalesce(product.internal_sku, '')) like '%' || token || '%'
          or lower(coalesce(product.barcode, '')) = token
          or exists (select 1 from public.product_aliases alias where alias.product_id = product.id and alias.normalized_value like '%' || token || '%')
          or exists (select 1 from public.product_external_references reference where reference.product_id = product.id and lower(reference.external_code) like '%' || token || '%')
        )
      )
  ), detailed as materialized (
    select product.id, product.name, product.internal_sku, product.barcode, product.unit, product.is_inventory_tracked,
      coalesce(balance.quantity_on_hand, 0) as quantity_on_hand, price.amount as price_amount,
      coalesce(remote_stock.location_count, 0) as other_location_stock_count,
      coalesce(remote_stock.quantity_on_hand, 0) as other_location_stock_quantity,
      array_remove(array[
        case when not exists (
          select 1 from public.location_sales_assortments assignment
          join public.sales_assortments assortment on assortment.id = assignment.assortment_id
          join public.sales_assortment_items item on item.assortment_id = assortment.id and item.product_id = product.id
          where assignment.location_id = p_location_id and assignment.valid_from <= p_at and (assignment.valid_to is null or assignment.valid_to > p_at)
            and assortment.company_id = p_company_id and assortment.status = 'active'
            and (assortment.valid_from is null or assortment.valid_from <= p_at) and (assortment.valid_to is null or assortment.valid_to > p_at)
        ) then 'outside_assortment' end,
        case when not product.is_active then 'inactive' end,
        case when not product.is_sellable then 'not_sellable' end,
        case when product.commercial_review_required then 'commercial_review_required' end,
        case when product.sales_unit_id is null then 'missing_sales_unit' end,
        case when product.tax_category_id is null then 'missing_tax_category' end,
        case when product.tax_category_id is not null and not exists (
          select 1 from public.tax_rates tax_rate where tax_rate.tax_category_id = product.tax_category_id and tax_rate.valid_from <= p_at and (tax_rate.valid_to is null or tax_rate.valid_to > p_at)
        ) then 'missing_current_tax_rate' end,
        case when coalesce(price.amount, 0) <= 0 then 'missing_or_zero_price' end,
        case when product.is_inventory_tracked and coalesce(balance.quantity_on_hand, 0) <= 0 then 'out_of_stock' end
      ]::text[], null) as blockers
    from matching product
    left join public.inventory_balances balance on balance.location_id = p_location_id and balance.product_id = product.id
    left join lateral (
      select product_price.amount from public.product_prices product_price
      where product_price.product_id = product.id and product_price.price_list_id = v_price_list_id and product_price.currency_code = v_currency_code
        and product_price.valid_from <= p_at and (product_price.valid_to is null or product_price.valid_to > p_at)
      order by product_price.valid_from desc limit 1
    ) price on true
    left join lateral (
      select count(*)::integer as location_count, coalesce(sum(remote_balance.quantity_on_hand), 0) as quantity_on_hand
      from public.inventory_balances remote_balance
      join public.locations remote_location on remote_location.id = remote_balance.location_id
      where v_can_view_inventory and remote_balance.company_id = p_company_id and remote_balance.product_id = product.id
        and remote_balance.location_id <> p_location_id and remote_balance.quantity_on_hand > 0
        and remote_location.is_active and public.can_access_location(remote_location.id)
    ) remote_stock on true
  ), blocked as materialized (
    select * from detailed where cardinality(blockers) > 0
  ), paged as (
    select * from blocked order by name, id limit v_size offset (v_page - 1) * v_size
  )
  select (select count(*) from blocked), coalesce((
    select jsonb_agg(jsonb_build_object(
      'product_id', product.id, 'code', coalesce(product.internal_sku, product.barcode), 'name', product.name, 'unit', product.unit,
      'inventory_tracked', product.is_inventory_tracked, 'quantity_on_hand', product.quantity_on_hand, 'price_amount', product.price_amount,
      'currency_code', v_currency_code, 'other_location_stock_count', product.other_location_stock_count,
      'other_location_stock_quantity', product.other_location_stock_quantity, 'blockers', to_jsonb(product.blockers)
    ) order by product.name, product.id) from paged product
  ), '[]'::jsonb) into v_total, v_items;

  return jsonb_build_object('items', v_items, 'total', coalesce(v_total, 0), 'page', v_page, 'page_size', v_size);
end;
$$;

revoke all on function public.search_pos_blocked_products(uuid, uuid, uuid, text, integer, integer, timestamptz) from public;
grant execute on function public.search_pos_blocked_products(uuid, uuid, uuid, text, integer, integer, timestamptz) to authenticated;
notify pgrst, 'reload schema';
