begin;

-- Restaurante: el selector alimenta entradas manuales de 5–100 partidas.
-- Conserva el costo canónico por unidad base y expone, por separado, el precio
-- equivalente por presentación para no mostrar $/ml como si fuera $/litro.
create or replace function public.search_restaurant_purchase_ingredients(
  p_company_id uuid,p_query text default null,p_limit integer default 30
) returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare v_query text:=lower(trim(coalesce(p_query,'')));v_limit integer:=least(greatest(coalesce(p_limit,30),1),50);v_items jsonb;
begin
  if auth.uid() is null or not (
    public.has_company_permission(p_company_id,'manage_purchase_receipt_drafts')
    or public.has_company_permission(p_company_id,'view_products')
  ) then raise exception 'No autorizado para seleccionar insumos.';end if;
  if not exists(select 1 from public.companies where id=p_company_id and product_experience_code='restaurant') then raise exception 'Este selector sólo está disponible en Restaurante.';end if;
  select coalesce(jsonb_agg(to_jsonb(item) order by item.rank,item.name,item.id),'[]'::jsonb) into v_items
  from(
    select product.id,product.internal_sku,product.name,
      purchase_unit.code purchase_unit,base_unit.code base_unit,
      coalesce(conversion.base_units_per_purchase_unit,1) base_units_per_purchase_unit,
      product.lot_controlled,
      cost.amount current_cost,
      case when cost.amount is null then null else round(cost.amount*coalesce(conversion.base_units_per_purchase_unit,1),6) end current_purchase_unit_cost,
      cost.currency_code,
      case when v_query<>'' and lower(product.internal_sku)=v_query then 0
        when v_query<>'' and lower(product.name) like v_query||'%' then 1 else 2 end rank
    from public.products product
    join public.product_culinary_roles role_data on role_data.company_id=product.company_id and role_data.product_id=product.id and role_data.role='ingredient'
    left join public.product_purchase_units conversion on conversion.product_id=product.id
    left join public.units_of_measure purchase_unit on purchase_unit.id=coalesce(conversion.purchase_unit_id,product.purchase_unit_id,product.base_unit_id)
    left join public.units_of_measure base_unit on base_unit.id=product.base_unit_id
    left join lateral(
      select product_cost.amount,product_cost.currency_code from public.product_costs product_cost
      where product_cost.company_id=p_company_id and product_cost.product_id=product.id
        and product_cost.cost_type='replacement_cost' and product_cost.valid_from<=now()
        and(product_cost.valid_to is null or product_cost.valid_to>now())
      order by product_cost.valid_from desc,product_cost.id desc limit 1
    )cost on true
    where product.company_id=p_company_id and product.is_active and product.is_inventory_tracked
      and purchase_unit.id is not null
      and(v_query='' or lower(product.name) like'%'||v_query||'%' or lower(product.internal_sku) like'%'||v_query||'%'
        or lower(coalesce(product.barcode,''))=v_query)
    order by rank,product.name,product.id limit v_limit
  )item;
  return jsonb_build_object('items',v_items);
end$$;

commit;
