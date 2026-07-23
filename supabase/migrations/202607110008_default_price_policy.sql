-- Teza's initial commercial rule: while a customer has no assigned price list,
-- use the highest valid current price for that product. It may later change to
-- a specific company list without rewriting price history.

alter table public.companies
  add column if not exists default_price_policy text not null default 'highest_available',
  add column if not exists default_price_list_id uuid references public.price_lists(id) on delete restrict;

alter table public.companies drop constraint if exists companies_default_price_policy_check;
alter table public.companies add constraint companies_default_price_policy_check
  check (default_price_policy in ('highest_available','specific_list'));

create or replace function public.resolve_product_sale_price(
  p_company_id uuid,
  p_product_id uuid,
  p_price_list_id uuid default null,
  p_at timestamptz default now()
)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_policy text;
  v_default_list uuid;
  v_list uuid;
begin
  if auth.uid() is null or not public.has_company_access(p_company_id) or not public.has_company_permission(p_company_id,'view_prices') then
    raise exception 'No autorizado para consultar precios.';
  end if;
  if not exists(select 1 from public.products where id=p_product_id and company_id=p_company_id) then
    raise exception 'Producto no encontrado.';
  end if;
  select default_price_policy,default_price_list_id into v_policy,v_default_list from public.companies where id=p_company_id;
  v_list:=coalesce(p_price_list_id,case when v_policy='specific_list' then v_default_list else null end);
  return (
    select jsonb_build_object(
      'price_list_id',pp.price_list_id,
      'amount',pp.amount,
      'currency_code',pp.currency_code,
      'valid_from',pp.valid_from,
      'policy',case when p_price_list_id is not null then 'selected_list' else v_policy end
    )
    from public.product_prices pp
    where pp.product_id=p_product_id and pp.valid_from<=p_at and (pp.valid_to is null or pp.valid_to>p_at)
      and (v_list is null or pp.price_list_id=v_list)
    order by case when v_list is null then pp.amount end desc nulls last,pp.valid_from desc
    limit 1
  );
end $$;

create or replace function public.product_pos_readiness(
  p_company_id uuid,
  p_product_id uuid,
  p_price_list_id uuid default null,
  p_at timestamptz default now()
)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_product public.products%rowtype;
  v_price jsonb;
  v_has_tax boolean;
  v_has_cost boolean;
begin
  if auth.uid() is null or not public.has_company_access(p_company_id) then raise exception 'No autorizado.'; end if;
  select * into v_product from public.products where id=p_product_id and company_id=p_company_id;
  if not found then raise exception 'Producto no encontrado.'; end if;
  if public.has_company_permission(p_company_id,'view_prices') then
    v_price:=public.resolve_product_sale_price(p_company_id,p_product_id,p_price_list_id,p_at);
  end if;
  select exists(select 1 from public.tax_rates where tax_category_id=v_product.tax_category_id and valid_from<=p_at and (valid_to is null or valid_to>p_at)) into v_has_tax;
  select exists(select 1 from public.product_costs where company_id=p_company_id and product_id=p_product_id and valid_from<=p_at and (valid_to is null or valid_to>p_at)) into v_has_cost;
  return jsonb_build_object(
    'product_id',v_product.id,
    'is_active',v_product.is_active,
    'is_sellable',v_product.is_sellable,
    'sales_unit_valid',v_product.sales_unit_id is not null,
    'tax_configured',v_product.tax_category_id is not null and v_has_tax,
    'price_configured',coalesce((v_price->>'amount')::numeric,0)>0,
    'classification_resolved',not v_product.commercial_review_required,
    'cost_available_for_margin',case when public.has_company_permission(p_company_id,'view_costs') then v_has_cost else null end,
    'pos_ready',v_product.is_active and v_product.is_sellable and v_product.sales_unit_id is not null and v_product.tax_category_id is not null and v_has_tax and coalesce((v_price->>'amount')::numeric,0)>0 and not v_product.commercial_review_required
  );
end $$;

create or replace function public.search_products(p_company_id uuid,p_query text default null,p_page integer default 1,p_page_size integer default 50,p_category_id uuid default null,p_is_active boolean default null,p_is_sellable boolean default null,p_inventory_tracked boolean default null,p_price_list_id uuid default null)
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
begin
  if auth.uid() is null or not public.has_company_access(p_company_id) then raise exception 'No autorizado.'; end if;
  select default_price_policy,default_price_list_id into v_policy,v_default_list from public.companies where id=p_company_id;
  if public.has_company_permission(p_company_id,'view_prices') then
    v_list:=coalesce(p_price_list_id,case when v_policy='specific_list' then v_default_list else null end);
  end if;
  select count(*) into v_total from public.products p
  where p.company_id=p_company_id and (p_category_id is null or p.category_id=p_category_id) and (p_is_active is null or p.is_active=p_is_active) and (p_is_sellable is null or p.is_sellable=p_is_sellable) and (p_inventory_tracked is null or p.is_inventory_tracked=p_inventory_tracked)
    and (v_q='' or lower(p.alpha_sku) like '%'||v_q||'%' or lower(coalesce(p.internal_sku,'')) like '%'||v_q||'%' or lower(coalesce(p.barcode,''))=v_q or lower(p.name) like '%'||v_q||'%' or exists(select 1 from public.product_aliases a where a.product_id=p.id and a.normalized_value like '%'||v_q||'%'));
  with filtered as (
    select p.*,case when v_q='' then 0 when lower(coalesce(p.barcode,''))=v_q then 1 when lower(p.alpha_sku)=v_q or lower(coalesce(p.internal_sku,''))=v_q then 2 when lower(p.alpha_sku) like v_q||'%' then 3 when exists(select 1 from public.product_aliases a where a.product_id=p.id and a.normalized_value like '%'||v_q||'%') then 4 else 5 end rank
    from public.products p
    where p.company_id=p_company_id and (p_category_id is null or p.category_id=p_category_id) and (p_is_active is null or p.is_active=p_is_active) and (p_is_sellable is null or p.is_sellable=p_is_sellable) and (p_inventory_tracked is null or p.is_inventory_tracked=p_inventory_tracked)
      and (v_q='' or lower(p.alpha_sku) like '%'||v_q||'%' or lower(coalesce(p.internal_sku,'')) like '%'||v_q||'%' or lower(coalesce(p.barcode,''))=v_q or lower(p.name) like '%'||v_q||'%' or exists(select 1 from public.product_aliases a where a.product_id=p.id and a.normalized_value like '%'||v_q||'%'))
  ), paged as (
    select * from filtered order by rank,name limit v_size offset (v_page-1)*v_size
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.id,'alpha_sku',p.alpha_sku,'internal_sku',p.internal_sku,'barcode',p.barcode,'name',p.name,'unit',p.unit,'alpha_class',p.alpha_class,'product_group',p.product_group,'product_type',p.product_type,'is_active',p.is_active,'is_sellable',p.is_sellable,'is_inventory_tracked',p.is_inventory_tracked,'category_id',p.category_id,'tax_category_id',p.tax_category_id,
    'price',case when public.has_company_permission(p_company_id,'view_prices') then price.amount else null end,
    'currency_code',case when public.has_company_permission(p_company_id,'view_prices') then price.currency_code else null end,
    'pos_ready',p.is_active and p.is_sellable and not p.commercial_review_required and p.sales_unit_id is not null and p.tax_category_id is not null and price.amount>0 and exists(select 1 from public.tax_rates tr where tr.tax_category_id=p.tax_category_id and tr.valid_from<=now() and (tr.valid_to is null or tr.valid_to>now()))
  ) order by p.rank,p.name),'[]'::jsonb) into v_items
  from paged p
  left join lateral (
    select pp.amount,pp.currency_code from public.product_prices pp
    where pp.product_id=p.id and pp.valid_from<=now() and (pp.valid_to is null or pp.valid_to>now()) and (v_list is null or pp.price_list_id=v_list)
    order by case when v_list is null then pp.amount end desc nulls last,pp.valid_from desc limit 1
  ) price on true;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size,'price_list_id',v_list,'price_policy',case when p_price_list_id is not null then 'selected_list' else v_policy end);
end $$;

revoke all on function public.resolve_product_sale_price(uuid,uuid,uuid,timestamptz) from public;
grant execute on function public.resolve_product_sale_price(uuid,uuid,uuid,timestamptz) to authenticated;
