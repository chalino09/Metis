-- Global navigation foundation: product visibility is an explicit capability,
-- not an implicit effect of company membership.

insert into public.permissions (code, description) values
  ('view_products', 'Consultar el catálogo de productos.')
on conflict (code) do update set description = excluded.description;

-- Preserve the current product-consultation audience while making the grant
-- auditable and independently revocable.
insert into public.role_permissions (role_id, permission_id)
select role_data.id, permission_data.id
from public.roles role_data
join public.permissions permission_data on permission_data.code = 'view_products'
where role_data.code in (
  'super_admin', 'direccion_admin', 'sucursal', 'ingeniero_campo', 'almacen', 'punto_venta'
)
on conflict do nothing;

drop policy if exists products_read on public.products;
create policy products_read on public.products
  for select to authenticated
  using (public.has_company_permission(company_id, 'view_products'));

drop policy if exists aliases_read on public.product_aliases;
create policy aliases_read on public.product_aliases
  for select to authenticated
  using (public.has_company_permission(company_id, 'view_products'));

drop policy if exists product_external_references_read on public.product_external_references;
create policy product_external_references_read on public.product_external_references
  for select to authenticated
  using (public.has_company_permission(company_id, 'view_products'));

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
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_products') then
    raise exception 'No autorizado para consultar productos.';
  end if;
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

create or replace function public.product_pos_readiness_detail(
  p_company_id uuid,
  p_product_id uuid,
  p_price_list_id uuid default null,
  p_at timestamptz default now()
)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_product public.products%rowtype;
  v_policy text;
  v_default_price_list_id uuid;
  v_price_list_id uuid;
  v_price numeric;
  v_currency text;
  v_has_tax boolean;
  v_has_cost boolean;
  v_blockers jsonb;
  v_warnings jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_products') then
    raise exception 'No autorizado para consultar productos.';
  end if;
  select * into v_product from public.products where id = p_product_id and company_id = p_company_id;
  if not found then raise exception 'Producto no encontrado.'; end if;
  select default_price_policy, default_price_list_id into v_policy, v_default_price_list_id from public.companies where id = p_company_id;
  v_price_list_id := coalesce(p_price_list_id, case when v_policy = 'specific_list' then v_default_price_list_id else null end);
  select price.amount, price.currency_code into v_price, v_currency
  from public.product_prices price
  where price.product_id = p_product_id
    and price.valid_from <= p_at
    and (price.valid_to is null or price.valid_to > p_at)
    and (v_price_list_id is null or price.price_list_id = v_price_list_id)
  order by case when v_price_list_id is null then price.amount end desc nulls last, price.valid_from desc
  limit 1;
  select exists (select 1 from public.tax_rates rate where rate.tax_category_id = v_product.tax_category_id and rate.valid_from <= p_at and (rate.valid_to is null or rate.valid_to > p_at)) into v_has_tax;
  select exists (select 1 from public.product_costs cost where cost.company_id = p_company_id and cost.product_id = p_product_id and cost.valid_from <= p_at and (cost.valid_to is null or cost.valid_to > p_at)) into v_has_cost;
  select coalesce(jsonb_agg(check_data.code), '[]'::jsonb) into v_blockers
  from (values
    ('inactive'::text, not v_product.is_active),
    ('not_sellable'::text, not v_product.is_sellable),
    ('commercial_review_required'::text, v_product.commercial_review_required),
    ('missing_sales_unit'::text, v_product.sales_unit_id is null),
    ('missing_tax_category'::text, v_product.tax_category_id is null),
    ('missing_current_tax_rate'::text, not coalesce(v_has_tax, false)),
    ('missing_or_zero_price'::text, coalesce(v_price, 0) <= 0)
  ) as check_data(code, is_blocked)
  where check_data.is_blocked;
  v_warnings := case when v_has_cost then '[]'::jsonb else jsonb_build_array('missing_current_cost') end;
  return jsonb_build_object(
    'product_id', v_product.id,
    'is_active', v_product.is_active,
    'is_sellable', v_product.is_sellable,
    'sales_unit_valid', v_product.sales_unit_id is not null,
    'tax_configured', v_product.tax_category_id is not null and coalesce(v_has_tax, false),
    'price_configured', coalesce(v_price, 0) > 0,
    'price_amount', v_price,
    'currency_code', v_currency,
    'classification_resolved', not v_product.commercial_review_required,
    'cost_available_for_margin', case when public.has_company_permission(p_company_id, 'view_costs') then v_has_cost else null end,
    'blockers', v_blockers,
    'warnings', v_warnings,
    'pos_ready', jsonb_array_length(v_blockers) = 0
  );
end $$;

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
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_products') then
    raise exception 'No autorizado para consultar productos.';
  end if;
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
  ), paged as (select * from filtered order by rank,name limit v_size offset (v_page-1)*v_size)
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

revoke all on function public.product_pos_readiness(uuid,uuid,uuid,timestamptz) from public;
grant execute on function public.product_pos_readiness(uuid,uuid,uuid,timestamptz) to authenticated;
revoke all on function public.product_pos_readiness_detail(uuid,uuid,uuid,timestamptz) from public;
grant execute on function public.product_pos_readiness_detail(uuid,uuid,uuid,timestamptz) to authenticated;
revoke all on function public.search_products(uuid,text,integer,integer,uuid,boolean,boolean,boolean,uuid) from public;
grant execute on function public.search_products(uuid,text,integer,integer,uuid,boolean,boolean,boolean,uuid) to authenticated;
