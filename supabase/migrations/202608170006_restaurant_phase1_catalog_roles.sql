-- Restaurante fase 1 · catálogo separado por función culinaria.
-- No crea un catálogo paralelo: sólo proyecta products en dos experiencias.

create or replace function public.search_restaurant_catalog(
  p_company_id uuid,
  p_role text default 'dish',
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 50,
  p_is_sellable boolean default null
)
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);
  v_query text:=lower(trim(coalesce(p_query,'')));
  v_total bigint;
  v_items jsonb;
  v_can_view_prices boolean;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_products') then
    raise exception 'No autorizado para consultar el catálogo.';
  end if;
  if p_role not in ('dish','ingredient') then raise exception 'Rol culinario no reconocido.'; end if;
  v_can_view_prices:=public.has_company_permission(p_company_id,'view_prices');

  with scoped as materialized (
    select p.*,
      exists(
        select 1 from public.culinary_recipes r
        where r.company_id=p_company_id and r.product_id=p.id and r.recipe_kind='dish'
      ) as is_dish,
      exists(
        select 1 from public.culinary_recipes r
        where r.company_id=p_company_id and r.product_id=p.id and r.recipe_kind='preparation'
      ) as is_preparation,
      price.amount as price_amount,price.currency_code,
      case
        when v_query='' then 0
        when lower(coalesce(p.internal_sku,''))=v_query then 1
        when lower(coalesce(p.barcode,''))=v_query then 2
        else 3
      end as rank
    from public.products p
    left join lateral (
      select pp.amount,pp.currency_code
      from public.product_prices pp
      where pp.product_id=p.id and pp.valid_from<=now() and (pp.valid_to is null or pp.valid_to>now())
      order by pp.valid_from desc,pp.id desc limit 1
    ) price on true
    where p.company_id=p_company_id
      and p.is_active
      and (p_is_sellable is null or p.is_sellable=p_is_sellable)
      and (v_query='' or lower(p.name) like '%'||v_query||'%'
        or lower(coalesce(p.internal_sku,'')) like '%'||v_query||'%'
        or lower(coalesce(p.barcode,''))=v_query
        or exists(select 1 from public.product_aliases a where a.product_id=p.id and a.normalized_value like '%'||v_query||'%'))
  ), filtered as materialized (
    select * from scoped
    where (p_role='dish' and (is_dish or (is_sellable and not is_inventory_tracked)))
       or (p_role='ingredient' and is_inventory_tracked and not is_dish)
  ), paged as materialized (
    select * from filtered order by rank,name,id limit v_size offset (v_page-1)*v_size
  )
  select
    (select count(*) from filtered),
    coalesce((select jsonb_agg(jsonb_build_object(
      'id',p.id,'alpha_sku',p.alpha_sku,'internal_sku',p.internal_sku,'barcode',p.barcode,
      'name',p.name,'unit',p.unit,'product_group',p.product_group,
      'product_type',p.product_type,'is_active',p.is_active,'is_sellable',p.is_sellable,
      'is_inventory_tracked',p.is_inventory_tracked,'price',case when v_can_view_prices then p.price_amount else null end,'currency_code',case when v_can_view_prices then p.currency_code else null end,
      'pos_ready',false,'blockers','[]'::jsonb,'catalog_role',p_role,
      'is_preparation',p.is_preparation
    ) order by p.rank,p.name,p.id) from paged p),'[]'::jsonb)
  into v_total,v_items;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size,'catalog_role',p_role);
end $$;

create or replace function public.search_restaurant_recipe_components(
  p_company_id uuid,
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 30
)
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,30),1),50);
  v_query text:=lower(trim(coalesce(p_query,'')));
  v_total bigint;
  v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_recipes') then
    raise exception 'No autorizado para consultar insumos.';
  end if;
  with scope as materialized (
    select p.id,p.internal_sku,p.name,p.unit,p.is_inventory_tracked,r.recipe_kind,
      (select count(*) from public.culinary_recipe_components c where c.component_product_id=p.id) usage_count
    from public.products p
    left join public.culinary_recipes r on r.company_id=p.company_id and r.product_id=p.id
    where p.company_id=p_company_id and p.is_active
      and (p.is_inventory_tracked or r.recipe_kind='preparation')
      and (v_query='' or lower(p.name) like '%'||v_query||'%' or lower(p.internal_sku) like '%'||v_query||'%')
  ), paged as (
    select * from scope order by usage_count desc,name,id limit v_size offset (v_page-1)*v_size
  )
  select (select count(*) from scope),coalesce((select jsonb_agg(to_jsonb(p) order by p.usage_count desc,p.name,p.id) from paged p),'[]')
    into v_total,v_items;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size);
end $$;

revoke all on function public.search_restaurant_catalog(uuid,text,text,integer,integer,boolean) from public,anon;
revoke all on function public.search_restaurant_recipe_components(uuid,text,integer,integer) from public,anon;
grant execute on function public.search_restaurant_catalog(uuid,text,text,integer,integer,boolean) to authenticated;
grant execute on function public.search_restaurant_recipe_components(uuid,text,integer,integer) to authenticated;

create index if not exists culinary_recipes_company_kind_product_idx
  on public.culinary_recipes(company_id,recipe_kind,product_id);
create index if not exists products_restaurant_ingredient_lookup_idx
  on public.products(company_id,is_active,is_inventory_tracked,name);
