-- Satrapy · Política canónica de inventario por producto.
-- La pertenencia comercial permanece intacta: un producto pendiente de
-- inventario sigue en su surtido, pero POS no lo puede vender hasta resolverlo.

begin;

alter table public.products
  add column if not exists inventory_policy text not null default 'unclassified';

alter table public.products
  drop constraint if exists products_inventory_policy_check;

alter table public.products
  add constraint products_inventory_policy_check
  check (inventory_policy in ('tracked', 'not_required', 'unclassified'));

comment on column public.products.inventory_policy is
  'Política canónica de inventario: tracked para mercancía, not_required para servicio y unclassified hasta resolver una importación ambigua.';

-- La columna booleana continúa siendo la señal operativa para los módulos de
-- inventario. La política es la fuente de intención de negocio.
create or replace function public.normalize_product_inventory_policy()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.inventory_policy is null or new.inventory_policy not in ('tracked', 'not_required', 'unclassified') then
    raise exception 'La política de inventario es inválida.';
  end if;

  -- Conserva compatibilidad con inserciones existentes que sólo indican el
  -- booleano de inventario, sin convertir falsos históricos en servicios.
  if new.inventory_policy = 'unclassified' and new.is_inventory_tracked then
    new.inventory_policy := 'tracked';
  end if;
  new.is_inventory_tracked := new.inventory_policy = 'tracked';
  return new;
end;
$$;

drop trigger if exists products_normalize_inventory_policy on public.products;
create trigger products_normalize_inventory_policy
before insert or update of inventory_policy, is_inventory_tracked on public.products
for each row execute function public.normalize_product_inventory_policy();

-- Las existencias canónicas son evidencia suficiente para una mercancía. Esta
-- regla es transaccional y no altera surtidos ni habilitación comercial.
create or replace function public.track_products_from_new_inventory_balances()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  with updated_products as (
    update public.products product
    set inventory_policy = 'tracked',
        is_inventory_tracked = true,
        updated_at = now()
    from (
      select distinct company_id, product_id
      from new_inventory_rows
    ) evidence
    where product.company_id = evidence.company_id
      and product.id = evidence.product_id
      and product.inventory_policy <> 'tracked'
    returning product.id, product.company_id
  )
  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  select company_id, auth.uid(), 'inventory.tracking_enabled', 'products', null,
    jsonb_build_object('product_count', count(*), 'evidence', 'inventory_balance_insert', 'scope', 'statement')
  from updated_products
  group by company_id;
  return null;
end;
$$;

-- Sólo los valores inequívocos del origen Alpha se traducen. Cualquier otro
-- valor permanece pendiente: no se adivina que una mercancía sea un servicio.
create or replace function public.alpha_product_inventory_policy(p_product_type text)
returns text
language sql
immutable
set search_path = public
as $$
  select case lower(trim(coalesce(p_product_type, '')))
    when 'p. terminado' then 'tracked'
    when 'servicios' then 'not_required'
    else 'unclassified'
  end;
$$;

-- Reconciliación inicial, set-based y auditada. No rellena inventario ni
-- modifica el catálogo comercial; únicamente etiqueta lo que ya sabemos.
with classified as (
  update public.products product
  set inventory_policy = case
    when product.is_inventory_tracked then 'tracked'
    when public.alpha_product_inventory_policy(product.product_type) = 'not_required' then 'not_required'
    else 'unclassified'
  end,
  updated_at = now()
  where product.inventory_policy = 'unclassified'
  returning product.company_id, inventory_policy
)
insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
select company_id, null, 'inventory.policy_reconciled', 'products', null,
  jsonb_build_object('product_count', count(*), 'scope', 'company')
from classified
group by company_id;

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
    'inventory_policy',v_product.inventory_policy,
    'inventory_prepared',v_product.inventory_policy <> 'unclassified',
    'sales_unit_valid',v_product.sales_unit_id is not null,
    'tax_configured',v_product.tax_category_id is not null and v_has_tax,
    'price_configured',coalesce((v_price->>'amount')::numeric,0)>0,
    'classification_resolved',not v_product.commercial_review_required,
    'cost_available_for_margin',case when public.has_company_permission(p_company_id,'view_costs') then v_has_cost else null end,
    'pos_ready',v_product.is_active and v_product.is_sellable and v_product.inventory_policy <> 'unclassified' and v_product.sales_unit_id is not null and v_product.tax_category_id is not null and v_has_tax and coalesce((v_price->>'amount')::numeric,0)>0 and not v_product.commercial_review_required
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
    ('inventory_setup_required'::text, v_product.inventory_policy = 'unclassified'),
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
    'inventory_policy', v_product.inventory_policy,
    'inventory_prepared', v_product.inventory_policy <> 'unclassified',
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
  p_company_id uuid, p_query text default null, p_page integer default 1, p_page_size integer default 50,
  p_category_id uuid default null, p_is_active boolean default null, p_is_sellable boolean default null,
  p_inventory_tracked boolean default null, p_price_list_id uuid default null
)
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare
  v_page int:=greatest(coalesce(p_page,1),1); v_size int:=least(greatest(coalesce(p_page_size,50),1),100);
  v_q text:=lower(trim(coalesce(p_query,''))); v_total bigint; v_items jsonb; v_policy text; v_default_list uuid; v_list uuid; v_can_view_prices boolean;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_products') then raise exception 'No autorizado para consultar productos.'; end if;
  v_can_view_prices:=public.has_company_permission(p_company_id,'view_prices');
  select default_price_policy,default_price_list_id into v_policy,v_default_list from public.companies where id=p_company_id;
  if v_can_view_prices then v_list:=coalesce(p_price_list_id,case when v_policy='specific_list' then v_default_list else null end); end if;
  with filtered as materialized (
    select p.*, case when v_q='' then 0 when lower(coalesce(p.barcode,''))=v_q then 1 when lower(p.alpha_sku)=v_q or lower(coalesce(p.internal_sku,''))=v_q then 2 when lower(p.alpha_sku) like v_q||'%' then 3 when exists(select 1 from public.product_aliases a where a.product_id=p.id and a.normalized_value like '%'||v_q||'%') then 4 else 5 end rank
    from public.products p where p.company_id=p_company_id and (p_category_id is null or p.category_id=p_category_id) and (p_is_active is null or p.is_active=p_is_active) and (p_is_sellable is null or p.is_sellable=p_is_sellable) and (p_inventory_tracked is null or p.is_inventory_tracked=p_inventory_tracked)
      and (v_q='' or lower(p.alpha_sku) like '%'||v_q||'%' or lower(coalesce(p.internal_sku,'')) like '%'||v_q||'%' or lower(coalesce(p.barcode,''))=v_q or lower(p.name) like '%'||v_q||'%' or exists(select 1 from public.product_aliases a where a.product_id=p.id and a.normalized_value like '%'||v_q||'%'))
  ), paged as materialized (
    select * from filtered order by rank,name limit v_size offset (v_page-1)*v_size
  ), detailed as (
    select p.*,price.amount price_amount,price.currency_code,array_remove(array[
      case when not p.is_active then 'inactive' end, case when not p.is_sellable then 'not_sellable' end,
      case when p.commercial_review_required then 'commercial_review_required' end,
      case when p.inventory_policy='unclassified' then 'inventory_setup_required' end,
      case when p.sales_unit_id is null then 'missing_sales_unit' end, case when p.tax_category_id is null then 'missing_tax_category' end,
      case when p.tax_category_id is not null and not exists(select 1 from public.tax_rates tr where tr.tax_category_id=p.tax_category_id and tr.valid_from<=now() and (tr.valid_to is null or tr.valid_to>now())) then 'missing_current_tax_rate' end,
      case when coalesce(price.amount,0)<=0 then 'missing_or_zero_price' end
    ]::text[],null) blockers
    from paged p left join lateral (select pp.amount,pp.currency_code from public.product_prices pp where pp.product_id=p.id and pp.valid_from<=now() and (pp.valid_to is null or pp.valid_to>now()) and (v_list is null or pp.price_list_id=v_list) order by case when v_list is null then pp.amount end desc nulls last,pp.valid_from desc limit 1) price on true
  )
  select (select count(*) from filtered),coalesce((select jsonb_agg(jsonb_build_object(
    'id',p.id,'alpha_sku',p.alpha_sku,'internal_sku',p.internal_sku,'barcode',p.barcode,'name',p.name,'unit',p.unit,'alpha_class',p.alpha_class,'product_group',p.product_group,'product_type',p.product_type,
    'inventory_policy',p.inventory_policy,'is_active',p.is_active,'is_sellable',p.is_sellable,'is_inventory_tracked',p.is_inventory_tracked,'category_id',p.category_id,'tax_category_id',p.tax_category_id,
    'price',case when v_can_view_prices then p.price_amount else null end,'currency_code',case when v_can_view_prices then p.currency_code else null end,'blockers',to_jsonb(p.blockers),'warnings','[]'::jsonb,'pos_ready',cardinality(p.blockers)=0
  ) order by p.rank,p.name) from detailed p),'[]'::jsonb) into v_total,v_items;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size,'price_list_id',v_list,'price_policy',case when p_price_list_id is not null then 'selected_list' else v_policy end);
end $$;

create or replace function public.search_pos_sale_products(
  p_company_id uuid,p_location_id uuid,p_customer_id uuid default null,p_query text default null,
  p_page integer default 1,p_page_size integer default 50,p_at timestamptz default now()
)
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare
  v_page integer:=greatest(coalesce(p_page,1),1); v_size integer:=least(greatest(coalesce(p_page_size,50),1),100); v_query text:=lower(trim(regexp_replace(coalesce(p_query,''),'\s+',' ','g'))); v_total integer; v_items jsonb; v_price_list_id uuid; v_currency_code text;
begin
  perform public.assert_pos_access(p_company_id,p_location_id,'use_pos');
  if p_customer_id is not null and not exists(select 1 from public.customers c where c.id=p_customer_id and c.company_id=p_company_id and c.is_active) then raise exception 'Cliente no encontrado o inactivo.'; end if;
  select coalesce(c.price_list_id,l.default_price_list_id,co.default_price_list_id) into v_price_list_id from public.companies co join public.locations l on l.id=p_location_id and l.company_id=co.id left join public.customers c on c.id=p_customer_id where co.id=p_company_id;
  select pl.currency_code into v_currency_code from public.price_lists pl where pl.id=v_price_list_id and pl.company_id=p_company_id and pl.is_active and pl.status='active';
  if v_currency_code is null then return jsonb_build_object('items','[]'::jsonb,'total',0,'page',v_page,'page_size',v_size); end if;
  with candidate_ids as materialized (
    select distinct i.product_id from public.location_sales_assortments la join public.sales_assortments a on a.id=la.assortment_id join public.sales_assortment_items i on i.assortment_id=a.id where la.location_id=p_location_id and la.valid_from<=p_at and (la.valid_to is null or la.valid_to>p_at) and a.company_id=p_company_id and a.status='active' and (a.valid_from is null or a.valid_from<=p_at) and (a.valid_to is null or a.valid_to>p_at)
  ), matched as materialized (
    select p.*,case when v_query='' then 9 when lower(coalesce(p.barcode,''))=v_query then 1 when lower(coalesce(p.internal_sku,''))=v_query then 2 when lower(coalesce(p.internal_sku,'')) like v_query||'%' then 3 when exists(select 1 from public.product_external_references r where r.product_id=p.id and lower(r.external_code)=v_query) then 4 else 5 end rank from candidate_ids c join public.products p on p.id=c.product_id where p.company_id=p_company_id and (v_query='' or not exists(select 1 from regexp_split_to_table(v_query,'\s+') token where token<>'' and not (lower(p.name) like '%'||token||'%' or lower(coalesce(p.internal_sku,'')) like '%'||token||'%' or lower(coalesce(p.barcode,''))=token or exists(select 1 from public.product_aliases x where x.product_id=p.id and x.normalized_value like '%'||token||'%') or exists(select 1 from public.product_external_references x where x.product_id=p.id and lower(x.external_code) like '%'||token||'%'))))
  ), eligible as materialized (
    select p.id,p.name,p.internal_sku,p.barcode,p.unit,p.is_inventory_tracked,coalesce(b.quantity_on_hand,0) quantity_on_hand,price.amount base_price_amount,tax.rate tax_rate,round(price.amount*tax.rate,2) tax_amount,round(price.amount*(1+tax.rate),2) price_amount,p.rank from matched p left join public.inventory_balances b on b.location_id=p_location_id and b.product_id=p.id left join lateral (select pp.amount from public.product_prices pp where pp.product_id=p.id and pp.price_list_id=v_price_list_id and pp.currency_code=v_currency_code and pp.valid_from<=p_at and (pp.valid_to is null or pp.valid_to>p_at) order by pp.valid_from desc limit 1) price on true left join lateral (select tr.rate from public.tax_rates tr where tr.tax_category_id=p.tax_category_id and tr.valid_from<=p_at and (tr.valid_to is null or tr.valid_to>p_at) order by tr.valid_from desc limit 1) tax on true where p.is_active and p.is_sellable and not p.commercial_review_required and p.inventory_policy<>'unclassified' and p.sales_unit_id is not null and p.tax_category_id is not null and tax.rate is not null and coalesce(price.amount,0)>0 and (not p.is_inventory_tracked or coalesce(b.quantity_on_hand,0)>0)
  ), paged as (select * from eligible order by rank,name limit v_size offset (v_page-1)*v_size)
  select (select count(*) from eligible),coalesce((select jsonb_agg(jsonb_build_object('product_id',p.id,'code',coalesce(p.internal_sku,p.barcode),'name',p.name,'unit',p.unit,'inventory_tracked',p.is_inventory_tracked,'quantity_on_hand',p.quantity_on_hand,'price_list_id',v_price_list_id,'base_price_amount',round(p.base_price_amount,2),'tax_rate',p.tax_rate,'tax_amount',p.tax_amount,'price_amount',p.price_amount,'currency_code',v_currency_code) order by p.rank,p.name) from paged p),'[]'::jsonb) into v_total,v_items;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size);
end $$;

create or replace function public.search_pos_blocked_products(
  p_company_id uuid,p_location_id uuid,p_customer_id uuid default null,p_query text default null,p_page integer default 1,p_page_size integer default 30,p_at timestamptz default now()
)
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare
  v_page integer:=greatest(coalesce(p_page,1),1); v_size integer:=least(greatest(coalesce(p_page_size,30),1),100); v_query text:=lower(trim(regexp_replace(coalesce(p_query,''),'\s+',' ','g'))); v_total integer; v_items jsonb; v_price_list_id uuid; v_currency_code text; v_can_view_inventory boolean:=public.has_company_permission(p_company_id,'view_inventory');
begin
  perform public.assert_pos_access(p_company_id,p_location_id,'use_pos');
  if v_query='' then return jsonb_build_object('items','[]'::jsonb,'total',0,'page',1,'page_size',v_size); end if;
  if p_customer_id is not null and not exists(select 1 from public.customers customer where customer.id=p_customer_id and customer.company_id=p_company_id and customer.is_active) then raise exception 'Cliente no encontrado o inactivo.'; end if;
  select coalesce(customer.price_list_id,location.default_price_list_id,company.default_price_list_id) into v_price_list_id from public.companies company join public.locations location on location.id=p_location_id and location.company_id=company.id left join public.customers customer on customer.id=p_customer_id where company.id=p_company_id;
  select price_list.currency_code into v_currency_code from public.price_lists price_list where price_list.id=v_price_list_id and price_list.company_id=p_company_id and price_list.is_active and price_list.status='active';
  with matching as materialized (
    select product.* from public.products product where product.company_id=p_company_id and not exists(select 1 from regexp_split_to_table(v_query,'\s+') token where token<>'' and not (lower(product.name) like '%'||token||'%' or lower(coalesce(product.internal_sku,'')) like '%'||token||'%' or lower(coalesce(product.barcode,''))=token or exists(select 1 from public.product_aliases alias where alias.product_id=product.id and alias.normalized_value like '%'||token||'%') or exists(select 1 from public.product_external_references reference where reference.product_id=product.id and lower(reference.external_code) like '%'||token||'%')))
  ), detailed as materialized (
    select product.id,product.name,product.internal_sku,product.barcode,product.unit,product.is_inventory_tracked,coalesce(balance.quantity_on_hand,0) quantity_on_hand,price.amount price_amount,coalesce(remote_stock.location_count,0) other_location_stock_count,coalesce(remote_stock.quantity_on_hand,0) other_location_stock_quantity,array_remove(array[
      case when not exists(select 1 from public.location_sales_assortments assignment join public.sales_assortments assortment on assortment.id=assignment.assortment_id join public.sales_assortment_items item on item.assortment_id=assortment.id and item.product_id=product.id where assignment.location_id=p_location_id and assignment.valid_from<=p_at and (assignment.valid_to is null or assignment.valid_to>p_at) and assortment.company_id=p_company_id and assortment.status='active' and (assortment.valid_from is null or assortment.valid_from<=p_at) and (assortment.valid_to is null or assortment.valid_to>p_at)) then 'outside_assortment' end,
      case when not product.is_active then 'inactive' end,case when not product.is_sellable then 'not_sellable' end,case when product.commercial_review_required then 'commercial_review_required' end,case when product.inventory_policy='unclassified' then 'inventory_setup_required' end,case when product.sales_unit_id is null then 'missing_sales_unit' end,case when product.tax_category_id is null then 'missing_tax_category' end,case when product.tax_category_id is not null and not exists(select 1 from public.tax_rates tax_rate where tax_rate.tax_category_id=product.tax_category_id and tax_rate.valid_from<=p_at and (tax_rate.valid_to is null or tax_rate.valid_to>p_at)) then 'missing_current_tax_rate' end,case when coalesce(price.amount,0)<=0 then 'missing_or_zero_price' end,case when product.is_inventory_tracked and coalesce(balance.quantity_on_hand,0)<=0 then 'out_of_stock' end
    ]::text[],null) blockers from matching product left join public.inventory_balances balance on balance.location_id=p_location_id and balance.product_id=product.id left join lateral (select product_price.amount from public.product_prices product_price where product_price.product_id=product.id and product_price.price_list_id=v_price_list_id and product_price.currency_code=v_currency_code and product_price.valid_from<=p_at and (product_price.valid_to is null or product_price.valid_to>p_at) order by product_price.valid_from desc limit 1) price on true left join lateral (select count(*)::integer location_count,coalesce(sum(remote_balance.quantity_on_hand),0) quantity_on_hand from public.inventory_balances remote_balance join public.locations remote_location on remote_location.id=remote_balance.location_id where v_can_view_inventory and remote_balance.company_id=p_company_id and remote_balance.product_id=product.id and remote_balance.location_id<>p_location_id and remote_balance.quantity_on_hand>0 and remote_location.is_active and public.can_access_location(remote_location.id)) remote_stock on true
  ), blocked as materialized (select * from detailed where cardinality(blockers)>0), paged as (select * from blocked order by name,id limit v_size offset (v_page-1)*v_size)
  select (select count(*) from blocked),coalesce((select jsonb_agg(jsonb_build_object('product_id',product.id,'code',coalesce(product.internal_sku,product.barcode),'name',product.name,'unit',product.unit,'inventory_tracked',product.is_inventory_tracked,'quantity_on_hand',product.quantity_on_hand,'price_amount',product.price_amount,'currency_code',v_currency_code,'other_location_stock_count',product.other_location_stock_count,'other_location_stock_quantity',product.other_location_stock_quantity,'blockers',to_jsonb(product.blockers)) order by product.name,product.id) from paged product),'[]'::jsonb) into v_total,v_items;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size);
end $$;

create or replace function public.save_product_with_inventory_policy(
  p_company_id uuid,p_product_id uuid,p_internal_sku text,p_name text,p_barcode text,p_unit text,p_product_group text,p_inventory_policy text,p_is_sellable boolean,p_is_active boolean,p_tax_category_id uuid,p_reason text,p_expected_updated_at timestamptz,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_product public.products%rowtype;v_previous jsonb;v_replayed jsonb;v_code text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_products') then raise exception 'No autorizado para administrar productos.';end if;
  if p_inventory_policy not in ('tracked','not_required') then raise exception 'Elige si el producto es mercancía con inventario o un servicio.';end if;
  if nullif(trim(p_name),'') is null or length(trim(p_name))>240 then raise exception 'El nombre es obligatorio y admite hasta 240 caracteres.';end if;
  if nullif(trim(p_reason),'') is null or p_client_request_id is null then raise exception 'Captura un motivo y vuelve a intentar.';end if;
  if p_tax_category_id is not null and not exists(select 1 from public.tax_categories where id=p_tax_category_id and company_id=p_company_id and is_active) then raise exception 'La categoría fiscal no pertenece a esta empresa o está inactiva.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text,0));
  select to_jsonb(product) into v_replayed from public.audit_log audit join public.products product on product.id=audit.entity_id and product.company_id=audit.company_id where audit.company_id=p_company_id and audit.action='product.admin_saved' and audit.metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_replayed is not null then return v_replayed||jsonb_build_object('idempotent',true);end if;
  if p_product_id is null then
    v_code:=coalesce(nullif(upper(trim(p_internal_sku)),''),public.next_company_internal_code(p_company_id,'PROD','public.products'::regclass,'internal_sku'));
    insert into public.products(company_id,internal_sku,alpha_sku,name,barcode,unit,product_group,inventory_policy,is_inventory_tracked,is_sellable,is_active,commercial_review_required,tax_category_id)
    values(p_company_id,v_code,null,trim(p_name),nullif(trim(p_barcode),''),nullif(trim(p_unit),''),nullif(trim(p_product_group),''),p_inventory_policy,p_inventory_policy='tracked',coalesce(p_is_sellable,false),coalesce(p_is_active,true),false,p_tax_category_id) returning * into v_product;
    v_previous:=null;
  else
    select * into v_product from public.products where id=p_product_id and company_id=p_company_id for update;
    if not found then raise exception 'El producto ya no está disponible.';end if;
    if p_expected_updated_at is null or v_product.updated_at<>p_expected_updated_at then raise exception 'El producto cambió mientras lo editabas. Actualiza y vuelve a intentarlo.';end if;
    v_previous:=to_jsonb(v_product);
    update public.products set name=trim(p_name),barcode=nullif(trim(p_barcode),''),unit=nullif(trim(p_unit),''),product_group=nullif(trim(p_product_group),''),inventory_policy=p_inventory_policy,is_inventory_tracked=p_inventory_policy='tracked',is_sellable=coalesce(p_is_sellable,false),is_active=coalesce(p_is_active,true),tax_category_id=p_tax_category_id where id=p_product_id returning * into v_product;
  end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'product.admin_saved','product',v_product.id,jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'origin','manual','previous',v_previous,'current',to_jsonb(v_product)));
  return to_jsonb(v_product)||jsonb_build_object('idempotent',false);
end $$;

-- El API anterior se conserva y se interpreta de forma segura: falso significa
-- servicio, nunca mercancía sin inventario. La interfaz nueva usa la política
-- explícita para evitar esa ambigüedad.
create or replace function public.save_product(
  p_company_id uuid,p_product_id uuid,p_internal_sku text,p_name text,p_barcode text,p_unit text,p_product_group text,p_is_inventory_tracked boolean,p_is_sellable boolean,p_is_active boolean,p_tax_category_id uuid,p_reason text,p_expected_updated_at timestamptz,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
begin
  return public.save_product_with_inventory_policy(p_company_id,p_product_id,p_internal_sku,p_name,p_barcode,p_unit,p_product_group,case when coalesce(p_is_inventory_tracked,false) then 'tracked' else 'not_required' end,p_is_sellable,p_is_active,p_tax_category_id,p_reason,p_expected_updated_at,p_client_request_id);
end $$;

create or replace function public.save_product(
  p_company_id uuid,p_product_id uuid,p_internal_sku text,p_name text,p_barcode text,p_unit text,p_product_group text,p_inventory_policy text,p_is_sellable boolean,p_is_active boolean,p_tax_category_id uuid,p_reason text,p_expected_updated_at timestamptz,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
begin
  return public.save_product_with_inventory_policy(p_company_id,p_product_id,p_internal_sku,p_name,p_barcode,p_unit,p_product_group,p_inventory_policy,p_is_sellable,p_is_active,p_tax_category_id,p_reason,p_expected_updated_at,p_client_request_id);
end $$;

alter function public.confirm_staged_import(uuid) rename to confirm_staged_import_before_inventory_policy;
revoke all on function public.confirm_staged_import_before_inventory_policy(uuid) from public, anon, authenticated;

create function public.confirm_staged_import(p_import_batch_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_result jsonb; v_batch public.import_batches%rowtype; v_updated integer:=0;
begin
  v_result:=public.confirm_staged_import_before_inventory_policy(p_import_batch_id);
  if v_result->>'status'<>'completed' then return v_result; end if;
  select * into v_batch from public.import_batches where id=p_import_batch_id;
  if v_batch.import_type<>'products' then return v_result; end if;
  with imported as (
    select distinct on (row_data.normalized_data->>'alphaSku') row_data.normalized_data->>'alphaSku' alpha_sku,public.alpha_product_inventory_policy(row_data.normalized_data->>'productType') inventory_policy
    from public.import_staging_rows row_data where row_data.import_batch_id=p_import_batch_id and row_data.detected_type='products' and coalesce((row_data.normalized_data->>'rejected')::boolean,false)=false order by row_data.normalized_data->>'alphaSku',row_data.id
  )
  update public.products product set inventory_policy=imported.inventory_policy,is_inventory_tracked=imported.inventory_policy='tracked',updated_at=now()
  from imported where product.company_id=v_batch.company_id and product.alpha_sku=imported.alpha_sku and product.inventory_policy is distinct from imported.inventory_policy;
  get diagnostics v_updated=row_count;
  if v_updated>0 then
    perform public.write_sales_audit(v_batch.company_id,'product.inventory_policy_import_applied','import_batches',p_import_batch_id,jsonb_build_object('products_processed',v_updated,'source','alpha','scope','completed_batch'));
  end if;
  return v_result;
end $$;

revoke all on function public.alpha_product_inventory_policy(text), public.normalize_product_inventory_policy(), public.save_product_with_inventory_policy(uuid,uuid,text,text,text,text,text,text,boolean,boolean,uuid,text,timestamptz,uuid), public.confirm_staged_import(uuid) from public, anon;
grant execute on function public.confirm_staged_import(uuid), public.save_product(uuid,uuid,text,text,text,text,text,text,boolean,boolean,uuid,text,timestamptz,uuid) to authenticated;

notify pgrst, 'reload schema';

commit;
