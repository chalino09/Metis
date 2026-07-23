-- Fase 1 de ventas: búsqueda POS por términos, precio total visible y
-- consulta administrativa del desglose fiscal. La base contable no cambia.

begin;

create or replace function public.search_pos_sale_products(
  p_company_id uuid,p_location_id uuid,p_customer_id uuid default null,p_query text default null,
  p_page integer default 1,p_page_size integer default 50,p_at timestamptz default now()
)
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);
  v_query text:=lower(trim(regexp_replace(coalesce(p_query,''),'\s+',' ','g')));
  v_total integer;
  v_items jsonb;
  v_price_list_id uuid;
  v_currency_code text;
begin
  perform public.assert_pos_access(p_company_id,p_location_id,'use_pos');
  if p_customer_id is not null and not exists(select 1 from public.customers c where c.id=p_customer_id and c.company_id=p_company_id and c.is_active) then
    raise exception 'Cliente no encontrado o inactivo.';
  end if;

  select coalesce(c.price_list_id,l.default_price_list_id,co.default_price_list_id)
    into v_price_list_id
  from public.companies co join public.locations l on l.id=p_location_id and l.company_id=co.id
  left join public.customers c on c.id=p_customer_id
  where co.id=p_company_id;
  select pl.currency_code into v_currency_code from public.price_lists pl
    where pl.id=v_price_list_id and pl.company_id=p_company_id and pl.is_active and pl.status='active';
  if v_currency_code is null then
    return jsonb_build_object('items','[]'::jsonb,'total',0,'page',v_page,'page_size',v_size);
  end if;

  with candidate_ids as materialized (
    select distinct i.product_id
    from public.location_sales_assortments la
    join public.sales_assortments a on a.id=la.assortment_id
    join public.sales_assortment_items i on i.assortment_id=a.id
    where la.location_id=p_location_id and la.valid_from<=p_at and (la.valid_to is null or la.valid_to>p_at)
      and a.company_id=p_company_id and a.status='active'
      and (a.valid_from is null or a.valid_from<=p_at) and (a.valid_to is null or a.valid_to>p_at)
  ), matched as materialized (
    select p.*,
      case when v_query='' then 9 when lower(coalesce(p.barcode,''))=v_query then 1
        when lower(coalesce(p.internal_sku,''))=v_query then 2
        when lower(coalesce(p.internal_sku,'')) like v_query||'%' then 3
        when exists(select 1 from public.product_external_references r where r.product_id=p.id and lower(r.external_code)=v_query) then 4
        else 5 end rank
    from candidate_ids c join public.products p on p.id=c.product_id
    where p.company_id=p_company_id and (
      v_query='' or not exists (
        select 1 from regexp_split_to_table(v_query,'\s+') token
        where token<>'' and not (
          lower(p.name) like '%'||token||'%'
          or lower(coalesce(p.internal_sku,'')) like '%'||token||'%'
          or lower(coalesce(p.barcode,''))=token
          or exists(select 1 from public.product_aliases x where x.product_id=p.id and x.normalized_value like '%'||token||'%')
          or exists(select 1 from public.product_external_references x where x.product_id=p.id and lower(x.external_code) like '%'||token||'%')
        )
      )
    )
  ), eligible as materialized (
    select p.id,p.name,p.internal_sku,p.barcode,p.unit,p.is_inventory_tracked,
      coalesce(b.quantity_on_hand,0) quantity_on_hand,price.amount base_price_amount,
      tax.rate tax_rate,round(price.amount*tax.rate,2) tax_amount,
      round(price.amount*(1+tax.rate),2) price_amount,p.rank
    from matched p
    left join public.inventory_balances b on b.location_id=p_location_id and b.product_id=p.id
    left join lateral (
      select pp.amount from public.product_prices pp
      where pp.product_id=p.id and pp.price_list_id=v_price_list_id and pp.currency_code=v_currency_code
        and pp.valid_from<=p_at and (pp.valid_to is null or pp.valid_to>p_at)
      order by pp.valid_from desc limit 1
    ) price on true
    left join lateral (
      select tr.rate from public.tax_rates tr where tr.tax_category_id=p.tax_category_id
        and tr.valid_from<=p_at and (tr.valid_to is null or tr.valid_to>p_at)
      order by tr.valid_from desc limit 1
    ) tax on true
    where p.is_active and p.is_sellable and not p.commercial_review_required
      and p.sales_unit_id is not null and p.tax_category_id is not null
      and tax.rate is not null and coalesce(price.amount,0)>0
      and (not p.is_inventory_tracked or coalesce(b.quantity_on_hand,0)>0)
  ), paged as (
    select * from eligible order by rank,name limit v_size offset (v_page-1)*v_size
  )
  select (select count(*) from eligible),coalesce((select jsonb_agg(jsonb_build_object(
    'product_id',p.id,'code',coalesce(p.internal_sku,p.barcode),'name',p.name,'unit',p.unit,
    'inventory_tracked',p.is_inventory_tracked,'quantity_on_hand',p.quantity_on_hand,
    'price_list_id',v_price_list_id,'base_price_amount',round(p.base_price_amount,2),
    'tax_rate',p.tax_rate,'tax_amount',p.tax_amount,'price_amount',p.price_amount,
    'currency_code',v_currency_code
  ) order by p.rank,p.name) from paged p),'[]'::jsonb) into v_total,v_items;

  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size);
end $$;

create or replace function public.search_price_list_products(
  p_company_id uuid,p_price_list_id uuid,p_query text default null,p_page integer default 1,p_page_size integer default 50
)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);
  v_query text:=lower(trim(regexp_replace(coalesce(p_query,''),'\s+',' ','g')));
  v_total bigint;
  v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_prices') then raise exception 'No autorizado para consultar precios.';end if;
  if not exists(select 1 from public.price_lists where id=p_price_list_id and company_id=p_company_id) then raise exception 'Lista de precios no encontrada.';end if;

  with matching as materialized (
    select product.* from public.products product
    where product.company_id=p_company_id and (
      v_query='' or not exists (
        select 1 from regexp_split_to_table(v_query,'\s+') token
        where token<>'' and not (
          lower(product.internal_sku) like '%'||token||'%'
          or lower(product.name) like '%'||token||'%'
          or lower(coalesce(product.barcode,''))=token
        )
      )
    )
  ), page_rows as (
    select * from matching order by name,id limit v_size offset (v_page-1)*v_size
  )
  select
    (select count(*) from matching),
    coalesce(jsonb_agg(jsonb_build_object(
      'product_id',product.id,'internal_sku',product.internal_sku,'name',product.name,'unit',product.unit,'is_active',product.is_active,
      'amount',current_price.amount,'tax_rate',tax.rate,
      'tax_amount',case when current_price.amount is null or tax.rate is null then null else round(current_price.amount*tax.rate,2) end,
      'total_amount',case when current_price.amount is null or tax.rate is null then null else round(current_price.amount*(1+tax.rate),2) end,
      'valid_from',current_price.valid_from,'valid_to',current_price.valid_to,
      'next_amount',next_price.amount,'next_valid_from',next_price.valid_from
    ) order by product.name,product.id),'[]'::jsonb)
  into v_total,v_items
  from page_rows product
  left join lateral (
    select price.amount,price.valid_from,price.valid_to from public.product_prices price
    where price.product_id=product.id and price.price_list_id=p_price_list_id
      and price.valid_from<=now() and (price.valid_to is null or price.valid_to>now())
    order by price.valid_from desc limit 1
  ) current_price on true
  left join lateral (
    select price.amount,price.valid_from from public.product_prices price
    where price.product_id=product.id and price.price_list_id=p_price_list_id and price.valid_from>now()
    order by price.valid_from limit 1
  ) next_price on true
  left join lateral (
    select rate.rate from public.tax_rates rate where rate.tax_category_id=product.tax_category_id
      and rate.valid_from<=now() and (rate.valid_to is null or rate.valid_to>now())
    order by rate.valid_from desc limit 1
  ) tax on true;

  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size);
end $$;

revoke all on function public.search_pos_sale_products(uuid,uuid,uuid,text,integer,integer,timestamptz) from public;
grant execute on function public.search_pos_sale_products(uuid,uuid,uuid,text,integer,integer,timestamptz) to authenticated;
revoke all on function public.search_price_list_products(uuid,uuid,text,integer,integer) from public;
grant execute on function public.search_price_list_products(uuid,uuid,text,integer,integer) to authenticated;

commit;
