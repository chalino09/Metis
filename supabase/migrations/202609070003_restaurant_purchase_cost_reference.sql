begin;

-- Restaurante: referencia de compra para entradas de 5–100 partidas.
-- El precio sugerido procede exclusivamente de una recepción confirmada.
-- Se normaliza con el factor histórico antes de convertir a la presentación actual.
-- Los campos current_cost heredados conservan su semántica de reposición;
-- no se usan como precio de compra ni como costo promedio para recetas.
create or replace function public.search_restaurant_purchase_ingredients(
  p_company_id uuid,p_query text default null,p_limit integer default 30
) returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare v_query text:=lower(trim(coalesce(p_query,'')));v_limit integer:=least(greatest(coalesce(p_limit,30),1),50);v_items jsonb;v_currency text;v_can_cost boolean;
begin
  if auth.uid() is null or not (
    public.has_company_permission(p_company_id,'manage_purchase_receipt_drafts')
    or public.has_company_permission(p_company_id,'view_products')
  ) then raise exception 'No autorizado para seleccionar insumos.';end if;
  if not exists(select 1 from public.companies where id=p_company_id and product_experience_code='restaurant') then raise exception 'Este selector sólo está disponible en Restaurante.';end if;
  select base_currency_code into v_currency from public.companies where id=p_company_id;
  v_can_cost:=public.has_company_permission(p_company_id,'view_costs');
  select coalesce(jsonb_agg(to_jsonb(item) order by item.rank,item.name,item.id),'[]'::jsonb) into v_items
  from(
    select product.id,product.internal_sku,product.name,
      purchase_unit.code purchase_unit,base_unit.code base_unit,
      coalesce(conversion.base_units_per_purchase_unit,1) base_units_per_purchase_unit,
      product.lot_controlled,
      cost.amount current_cost,
      case when cost.amount is null then null else round(cost.amount*coalesce(conversion.base_units_per_purchase_unit,1),6) end current_purchase_unit_cost,
      coalesce(cost.currency_code,v_currency) currency_code,
      last_purchase.receipt_date last_purchase_date,
      last_purchase.folio last_purchase_folio,
      round(last_purchase.base_cost*coalesce(conversion.base_units_per_purchase_unit,1),6) last_purchase_unit_cost,
      case when v_query<>'' and lower(product.internal_sku)=v_query then 0
        when v_query<>'' and lower(product.name) like v_query||'%' then 1 else 2 end rank
    from public.products product
    join public.product_culinary_roles role_data on role_data.company_id=product.company_id and role_data.product_id=product.id and role_data.role='ingredient'
    left join public.product_purchase_units conversion on conversion.product_id=product.id
    left join public.units_of_measure purchase_unit on purchase_unit.id=coalesce(conversion.purchase_unit_id,product.purchase_unit_id,product.base_unit_id)
    left join public.units_of_measure base_unit on base_unit.id=product.base_unit_id
    left join lateral(
      select product_cost.amount,product_cost.currency_code from public.product_costs product_cost
      where v_can_cost and product_cost.company_id=p_company_id and product_cost.product_id=product.id
        and product_cost.currency_code=v_currency
        and product_cost.cost_type='replacement_cost' and product_cost.valid_from<=now()
        and(product_cost.valid_to is null or product_cost.valid_to>now())
      order by product_cost.valid_from desc,product_cost.id desc limit 1
    )cost on true
    left join lateral(
      select receipt.receipt_date,receipt.folio,
        sum(line.line_cost)/nullif(sum(line.inventory_quantity),0) base_cost
      from public.purchase_receipt_lines line
      join public.purchase_receipts receipt on receipt.id=line.purchase_receipt_id and receipt.company_id=p_company_id
      join public.purchase_orders purchase_order on purchase_order.id=receipt.purchase_order_id and purchase_order.company_id=p_company_id
      where v_can_cost and line.company_id=p_company_id and line.product_id=product.id
        and receipt.status='confirmed' and receipt.receipt_date<=current_date
        and purchase_order.currency_code=v_currency
        and public.can_access_location(receipt.location_id)
      group by receipt.id,receipt.receipt_date,receipt.folio,receipt.confirmed_at
      order by receipt.receipt_date desc,receipt.confirmed_at desc,receipt.id desc limit 1
    )last_purchase on true
    where product.company_id=p_company_id and product.is_active and product.is_inventory_tracked
      and purchase_unit.id is not null
      and(v_query='' or lower(product.name) like'%'||v_query||'%' or lower(product.internal_sku) like'%'||v_query||'%'
        or lower(coalesce(product.barcode,''))=v_query)
    order by rank,product.name,product.id limit v_limit
  )item;
  return jsonb_build_object('items',v_items);
end$$;

commit;
