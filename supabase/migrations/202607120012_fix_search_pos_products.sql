-- Fix the POS search aggregation alias introduced by the preflight migration.
-- Safe to apply after 202607120011_pos_preflight_foundation.sql.

create or replace function public.search_pos_products(
  p_company_id uuid,
  p_location_id uuid,
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 50,
  p_at timestamptz default now()
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
  if auth.uid() is null or not public.can_access_location(p_location_id) then
    raise exception 'No autorizado para consultar esta ubicación.';
  end if;

  if not exists (
    select 1 from public.locations
    where id = p_location_id and company_id = p_company_id
  ) then
    raise exception 'Ubicación no encontrada.';
  end if;

  with eligible_products as (
    select distinct product.id, product.name, product.internal_sku, product.barcode, product.unit
    from public.sales_assortment_items item
    join public.sales_assortments assortment on assortment.id = item.assortment_id
    join public.location_sales_assortments assignment on assignment.assortment_id = assortment.id
    join public.products product on product.id = item.product_id
    cross join lateral public.product_pos_readiness_detail(p_company_id, product.id, null, p_at) readiness
    where assignment.location_id = p_location_id
      and assignment.valid_from <= p_at
      and (assignment.valid_to is null or assignment.valid_to > p_at)
      and assortment.status = 'active'
      and (assortment.valid_from is null or assortment.valid_from <= p_at)
      and (assortment.valid_to is null or assortment.valid_to > p_at)
      and product.company_id = p_company_id
      and coalesce((readiness ->> 'pos_ready')::boolean, false)
      and (
        v_query = ''
        or lower(product.name) like '%' || v_query || '%'
        or lower(coalesce(product.internal_sku, '')) like '%' || v_query || '%'
        or lower(coalesce(product.barcode, '')) = v_query
        or exists (
          select 1 from public.product_aliases alias
          where alias.product_id = product.id
            and lower(alias.normalized_value) like '%' || v_query || '%'
        )
        or exists (
          select 1 from public.product_external_references reference
          where reference.product_id = product.id
            and lower(reference.external_code) like '%' || v_query || '%'
        )
      )
  )
  select count(*) into v_total from eligible_products;

  with eligible_products as (
    select distinct product.id, product.name, product.internal_sku, product.barcode, product.unit,
      public.resolve_product_sale_price(p_company_id, product.id, null, p_at) as price
    from public.sales_assortment_items item
    join public.sales_assortments assortment on assortment.id = item.assortment_id
    join public.location_sales_assortments assignment on assignment.assortment_id = assortment.id
    join public.products product on product.id = item.product_id
    cross join lateral public.product_pos_readiness_detail(p_company_id, product.id, null, p_at) readiness
    where assignment.location_id = p_location_id
      and assignment.valid_from <= p_at
      and (assignment.valid_to is null or assignment.valid_to > p_at)
      and assortment.status = 'active'
      and (assortment.valid_from is null or assortment.valid_from <= p_at)
      and (assortment.valid_to is null or assortment.valid_to > p_at)
      and product.company_id = p_company_id
      and coalesce((readiness ->> 'pos_ready')::boolean, false)
      and (
        v_query = ''
        or lower(product.name) like '%' || v_query || '%'
        or lower(coalesce(product.internal_sku, '')) like '%' || v_query || '%'
        or lower(coalesce(product.barcode, '')) = v_query
        or exists (
          select 1 from public.product_aliases alias
          where alias.product_id = product.id
            and lower(alias.normalized_value) like '%' || v_query || '%'
        )
        or exists (
          select 1 from public.product_external_references reference
          where reference.product_id = product.id
            and lower(reference.external_code) like '%' || v_query || '%'
        )
      )
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'product_id', paged.id,
    'code', coalesce(paged.internal_sku, (
      select reference.external_code
      from public.product_external_references reference
      where reference.product_id = paged.id
      order by reference.is_primary desc, reference.created_at asc
      limit 1
    )),
    'name', paged.name,
    'unit', paged.unit,
    'price_amount', paged.price -> 'amount',
    'currency_code', paged.price -> 'currency_code'
  ) order by paged.name), '[]'::jsonb)
  into v_items
  from (
    select * from eligible_products
    order by name
    limit v_size offset (v_page - 1) * v_size
  ) paged;

  return jsonb_build_object('items', v_items, 'total', coalesce(v_total, 0), 'page', v_page, 'page_size', v_size);
end;
$$;

revoke all on function public.search_pos_products(uuid, uuid, text, integer, integer, timestamptz) from public;
grant execute on function public.search_pos_products(uuid, uuid, text, integer, integer, timestamptz) to authenticated;
