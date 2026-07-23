-- Readiness remains dynamic. This migration only makes its read paths set-based
-- and exposes the existing blocker codes to the product catalog.

create index if not exists product_prices_current_lookup_idx
  on public.product_prices(price_list_id, product_id, currency_code, valid_from desc);

create index if not exists tax_rates_current_lookup_idx
  on public.tax_rates(tax_category_id, valid_from, valid_to);

create index if not exists product_external_references_code_trgm_idx
  on public.product_external_references using gin (lower(external_code) extensions.gin_trgm_ops);

create or replace function public.search_products(
  p_company_id uuid,
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 50,
  p_category_id uuid default null,
  p_is_active boolean default null,
  p_is_sellable boolean default null,
  p_inventory_tracked boolean default null,
  p_price_list_id uuid default null
)
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare
  v_page int:=greatest(coalesce(p_page,1),1);
  v_size int:=least(greatest(coalesce(p_page_size,50),1),100);
  v_q text:=lower(trim(coalesce(p_query,'')));
  v_total bigint;
  v_items jsonb;
  v_policy text;
  v_default_list uuid;
  v_list uuid;
  v_can_view_prices boolean;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_products') then
    raise exception 'No autorizado para consultar productos.';
  end if;

  v_can_view_prices:=public.has_company_permission(p_company_id,'view_prices');
  select default_price_policy,default_price_list_id
    into v_policy,v_default_list from public.companies where id=p_company_id;
  if v_can_view_prices then
    v_list:=coalesce(p_price_list_id,case when v_policy='specific_list' then v_default_list else null end);
  end if;

  with filtered as materialized (
    select p.*,
      case when v_q='' then 0 when lower(coalesce(p.barcode,''))=v_q then 1
        when lower(p.alpha_sku)=v_q or lower(coalesce(p.internal_sku,''))=v_q then 2
        when lower(p.alpha_sku) like v_q||'%' then 3
        when exists(select 1 from public.product_aliases a where a.product_id=p.id and a.normalized_value like '%'||v_q||'%') then 4
        else 5 end rank
    from public.products p
    where p.company_id=p_company_id
      and (p_category_id is null or p.category_id=p_category_id)
      and (p_is_active is null or p.is_active=p_is_active)
      and (p_is_sellable is null or p.is_sellable=p_is_sellable)
      and (p_inventory_tracked is null or p.is_inventory_tracked=p_inventory_tracked)
      and (v_q='' or lower(p.alpha_sku) like '%'||v_q||'%'
        or lower(coalesce(p.internal_sku,'')) like '%'||v_q||'%'
        or lower(coalesce(p.barcode,''))=v_q or lower(p.name) like '%'||v_q||'%'
        or exists(select 1 from public.product_aliases a where a.product_id=p.id and a.normalized_value like '%'||v_q||'%'))
  ), paged as materialized (
    select * from filtered order by rank,name limit v_size offset (v_page-1)*v_size
  ), detailed as (
    select p.*,price.amount price_amount,price.currency_code,
      array_remove(array[
        case when not p.is_active then 'inactive' end,
        case when not p.is_sellable then 'not_sellable' end,
        case when p.commercial_review_required then 'commercial_review_required' end,
        case when p.sales_unit_id is null then 'missing_sales_unit' end,
        case when p.tax_category_id is null then 'missing_tax_category' end,
        case when p.tax_category_id is not null and not exists(
          select 1 from public.tax_rates tr where tr.tax_category_id=p.tax_category_id
            and tr.valid_from<=now() and (tr.valid_to is null or tr.valid_to>now())
        ) then 'missing_current_tax_rate' end,
        case when coalesce(price.amount,0)<=0 then 'missing_or_zero_price' end
      ]::text[],null) blockers
    from paged p
    left join lateral (
      select pp.amount,pp.currency_code from public.product_prices pp
      where pp.product_id=p.id and pp.valid_from<=now() and (pp.valid_to is null or pp.valid_to>now())
        and (v_list is null or pp.price_list_id=v_list)
      order by case when v_list is null then pp.amount end desc nulls last,pp.valid_from desc limit 1
    ) price on true
  )
  select
    (select count(*) from filtered),
    coalesce((select jsonb_agg(jsonb_build_object(
      'id',p.id,'alpha_sku',p.alpha_sku,'internal_sku',p.internal_sku,'barcode',p.barcode,
      'name',p.name,'unit',p.unit,'alpha_class',p.alpha_class,'product_group',p.product_group,
      'product_type',p.product_type,'is_active',p.is_active,'is_sellable',p.is_sellable,
      'is_inventory_tracked',p.is_inventory_tracked,'category_id',p.category_id,
      'tax_category_id',p.tax_category_id,
      'price',case when v_can_view_prices then p.price_amount else null end,
      'currency_code',case when v_can_view_prices then p.currency_code else null end,
      'blockers',to_jsonb(p.blockers),'warnings','[]'::jsonb,
      'pos_ready',cardinality(p.blockers)=0
    ) order by p.rank,p.name) from detailed p),'[]'::jsonb)
  into v_total,v_items;

  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,
    'page_size',v_size,'price_list_id',v_list,
    'price_policy',case when p_price_list_id is not null then 'selected_list' else v_policy end);
end $$;

create or replace function public.search_pos_sale_products(
  p_company_id uuid,p_location_id uuid,p_customer_id uuid default null,p_query text default null,
  p_page integer default 1,p_page_size integer default 50,p_at timestamptz default now()
)
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);
  v_query text:=lower(trim(coalesce(p_query,'')));
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
    where p.company_id=p_company_id and (v_query='' or lower(p.name) like '%'||v_query||'%'
      or lower(coalesce(p.internal_sku,'')) like '%'||v_query||'%'
      or lower(coalesce(p.barcode,''))=v_query
      or exists(select 1 from public.product_aliases x where x.product_id=p.id and x.normalized_value like '%'||v_query||'%')
      or exists(select 1 from public.product_external_references x where x.product_id=p.id and lower(x.external_code) like '%'||v_query||'%'))
  ), eligible as materialized (
    select p.id,p.name,p.internal_sku,p.barcode,p.unit,p.is_inventory_tracked,
      coalesce(b.quantity_on_hand,0) quantity_on_hand,price.amount price_amount,p.rank
    from matched p
    left join public.inventory_balances b on b.location_id=p_location_id and b.product_id=p.id
    left join lateral (
      select pp.amount from public.product_prices pp
      where pp.product_id=p.id and pp.price_list_id=v_price_list_id and pp.currency_code=v_currency_code
        and pp.valid_from<=p_at and (pp.valid_to is null or pp.valid_to>p_at)
      order by pp.valid_from desc limit 1
    ) price on true
    where p.is_active and p.is_sellable and not p.commercial_review_required
      and p.sales_unit_id is not null and p.tax_category_id is not null
      and exists(select 1 from public.tax_rates tr where tr.tax_category_id=p.tax_category_id
        and tr.valid_from<=p_at and (tr.valid_to is null or tr.valid_to>p_at))
      and coalesce(price.amount,0)>0
      and (not p.is_inventory_tracked or coalesce(b.quantity_on_hand,0)>0)
  ), paged as (
    select * from eligible order by rank,name limit v_size offset (v_page-1)*v_size
  )
  select (select count(*) from eligible),coalesce((select jsonb_agg(jsonb_build_object(
    'product_id',p.id,'code',coalesce(p.internal_sku,p.barcode),'name',p.name,'unit',p.unit,
    'inventory_tracked',p.is_inventory_tracked,'quantity_on_hand',p.quantity_on_hand,
    'price_list_id',v_price_list_id,'price_amount',round(p.price_amount,2),'currency_code',v_currency_code
  ) order by p.rank,p.name) from paged p),'[]'::jsonb) into v_total,v_items;

  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size);
end $$;

create or replace function public.search_pos_blocked_products(
  p_company_id uuid,p_location_id uuid,p_customer_id uuid default null,p_query text default null,
  p_page integer default 1,p_page_size integer default 30,p_at timestamptz default now()
)
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,30),1),100);
  v_query text:=lower(trim(coalesce(p_query,'')));
  v_total integer;
  v_items jsonb;
  v_price_list_id uuid;
  v_currency_code text;
begin
  perform public.assert_pos_access(p_company_id,p_location_id,'use_pos');
  if v_query='' then return jsonb_build_object('items','[]'::jsonb,'total',0,'page',1,'page_size',v_size); end if;
  if p_customer_id is not null and not exists(select 1 from public.customers c where c.id=p_customer_id and c.company_id=p_company_id and c.is_active) then
    raise exception 'Cliente no encontrado o inactivo.';
  end if;
  select coalesce(c.price_list_id,l.default_price_list_id,co.default_price_list_id)
    into v_price_list_id from public.companies co
    join public.locations l on l.id=p_location_id and l.company_id=co.id
    left join public.customers c on c.id=p_customer_id where co.id=p_company_id;
  select pl.currency_code into v_currency_code from public.price_lists pl
    where pl.id=v_price_list_id and pl.company_id=p_company_id and pl.is_active and pl.status='active';

  with candidate_ids as materialized (
    select distinct i.product_id from public.location_sales_assortments la
    join public.sales_assortments a on a.id=la.assortment_id
    join public.sales_assortment_items i on i.assortment_id=a.id
    where la.location_id=p_location_id and la.valid_from<=p_at and (la.valid_to is null or la.valid_to>p_at)
      and a.company_id=p_company_id and a.status='active'
      and (a.valid_from is null or a.valid_from<=p_at) and (a.valid_to is null or a.valid_to>p_at)
  ), detailed as materialized (
    select p.id,p.name,p.internal_sku,p.barcode,p.unit,p.is_inventory_tracked,
      coalesce(b.quantity_on_hand,0) quantity_on_hand,price.amount price_amount,
      array_remove(array[
        case when not p.is_active then 'inactive' end,case when not p.is_sellable then 'not_sellable' end,
        case when p.commercial_review_required then 'commercial_review_required' end,
        case when p.sales_unit_id is null then 'missing_sales_unit' end,
        case when p.tax_category_id is null then 'missing_tax_category' end,
        case when p.tax_category_id is not null and not exists(select 1 from public.tax_rates tr
          where tr.tax_category_id=p.tax_category_id and tr.valid_from<=p_at and (tr.valid_to is null or tr.valid_to>p_at)) then 'missing_current_tax_rate' end,
        case when coalesce(price.amount,0)<=0 then 'missing_or_zero_price' end,
        case when p.is_inventory_tracked and coalesce(b.quantity_on_hand,0)<=0 then 'out_of_stock' end
      ]::text[],null) blockers
    from candidate_ids c join public.products p on p.id=c.product_id
    left join public.inventory_balances b on b.location_id=p_location_id and b.product_id=p.id
    left join lateral (
      select pp.amount from public.product_prices pp where pp.product_id=p.id
        and pp.price_list_id=v_price_list_id and pp.currency_code=v_currency_code
        and pp.valid_from<=p_at and (pp.valid_to is null or pp.valid_to>p_at)
      order by pp.valid_from desc limit 1
    ) price on true
    where p.company_id=p_company_id and (lower(p.name) like '%'||v_query||'%'
      or lower(coalesce(p.internal_sku,'')) like '%'||v_query||'%'
      or lower(coalesce(p.barcode,''))=v_query
      or exists(select 1 from public.product_aliases x where x.product_id=p.id and x.normalized_value like '%'||v_query||'%')
      or exists(select 1 from public.product_external_references x where x.product_id=p.id and lower(x.external_code) like '%'||v_query||'%'))
  ), blocked as materialized (
    select * from detailed where cardinality(blockers)>0
  ), paged as (
    select * from blocked order by name,id limit v_size offset (v_page-1)*v_size
  )
  select (select count(*) from blocked),coalesce((select jsonb_agg(jsonb_build_object(
    'product_id',p.id,'code',coalesce(p.internal_sku,p.barcode),'name',p.name,'unit',p.unit,
    'inventory_tracked',p.is_inventory_tracked,'quantity_on_hand',p.quantity_on_hand,
    'price_amount',p.price_amount,'currency_code',v_currency_code,'blockers',to_jsonb(p.blockers)
  ) order by p.name,p.id) from paged p),'[]'::jsonb) into v_total,v_items;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size);
end $$;

revoke all on function public.search_products(uuid,text,integer,integer,uuid,boolean,boolean,boolean,uuid) from public;
grant execute on function public.search_products(uuid,text,integer,integer,uuid,boolean,boolean,boolean,uuid) to authenticated;
revoke all on function public.search_pos_sale_products(uuid,uuid,uuid,text,integer,integer,timestamptz) from public;
grant execute on function public.search_pos_sale_products(uuid,uuid,uuid,text,integer,integer,timestamptz) to authenticated;
revoke all on function public.search_pos_blocked_products(uuid,uuid,uuid,text,integer,integer,timestamptz) from public;
grant execute on function public.search_pos_blocked_products(uuid,uuid,uuid,text,integer,integer,timestamptz) to authenticated;
