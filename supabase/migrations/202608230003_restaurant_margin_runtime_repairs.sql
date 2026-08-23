-- Reparaciones de ejecución para instalaciones que aplicaron 202608230002 antes de la validación E2E.
begin;

create or replace function public.get_restaurant_weekly_cost_analysis(
  p_company_id uuid,p_week_start date default null,p_query text default null,
  p_ingredient_page integer default 1,p_dish_page integer default 1,p_page_size integer default 20
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_start date:=coalesce(p_week_start,date_trunc('week',current_date)::date);v_end date;v_previous_start date;v_previous_end date;
  v_query text:=lower(trim(coalesce(p_query,'')));v_size integer:=least(greatest(coalesce(p_page_size,20),1),50);
  v_ingredient_page integer:=greatest(coalesce(p_ingredient_page,1),1);v_dish_page integer:=greatest(coalesce(p_dish_page,1),1);
  v_currency text;v_ingredients jsonb;v_dishes jsonb;v_ingredient_total bigint;v_dish_total bigint;v_below_threshold bigint;v_summary jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_bi') or not public.has_company_permission(p_company_id,'view_costs') then raise exception 'No autorizado para consultar costos y márgenes.';end if;
  if not exists(select 1 from public.companies where id=p_company_id and product_experience_code='restaurant') then raise exception 'Este análisis sólo está disponible en Restaurante.';end if;
  if v_start>current_date or v_start<current_date-interval'2 years' then raise exception 'Selecciona una semana válida.';end if;
  v_end:=v_start+6;v_previous_start:=v_start-7;v_previous_end:=v_start-1;
  v_currency:=coalesce((select base_currency_code from public.companies where id=p_company_id),'MXN');

  with ingredient_scope as materialized(
    select product.id product_id,product.internal_sku,product.name,coalesce(base_unit.code,lower(product.unit)) base_unit,
      current_cost.amount current_cost,previous_cost.amount previous_cost,
      current_cost.valid_from last_cost_at,current_cost.source_file_name cost_source,
      current_cost.amount-previous_cost.amount change_amount,
      case when previous_cost.amount>0 then round(100*(current_cost.amount-previous_cost.amount)/previous_cost.amount,2) end change_percent,
      coalesce(receipts.receipt_count,0) receipt_count,receipts.last_receipt_date
    from public.products product
    join public.product_culinary_roles role_data on role_data.company_id=product.company_id and role_data.product_id=product.id and role_data.role='ingredient'
    left join public.units_of_measure base_unit on base_unit.id=product.base_unit_id
    left join lateral(select cost.amount,cost.valid_from,cost.source_file_name from public.product_costs cost where cost.company_id=p_company_id and cost.product_id=product.id and cost.cost_type='replacement_cost' and cost.currency_code=v_currency and cost.valid_from<v_end+1 order by cost.valid_from desc,cost.id desc limit 1)current_cost on true
    left join lateral(select cost.amount from public.product_costs cost where cost.company_id=p_company_id and cost.product_id=product.id and cost.cost_type='replacement_cost' and cost.currency_code=v_currency and cost.valid_from<v_start order by cost.valid_from desc,cost.id desc limit 1)previous_cost on true
    left join lateral(select count(distinct receipt.id)::integer receipt_count,max(receipt.receipt_date) last_receipt_date from public.purchase_receipt_lines line join public.purchase_receipts receipt on receipt.id=line.purchase_receipt_id and receipt.status='confirmed' where line.product_id=product.id and receipt.receipt_date between v_start and v_end)receipts on true
    where product.company_id=p_company_id and product.is_active and(v_query='' or lower(product.name)like'%'||v_query||'%' or lower(product.internal_sku)like'%'||v_query||'%')
  ),ingredient_paged as(select * from ingredient_scope order by abs(coalesce(change_percent,0)) desc,name,product_id limit v_size offset(v_ingredient_page-1)*v_size)
  select(select count(*)from ingredient_scope),coalesce(jsonb_agg(to_jsonb(ingredient_paged)order by abs(coalesce(change_percent,0))desc,name,product_id),'[]'::jsonb)
  into v_ingredient_total,v_ingredients from ingredient_paged;

  with dish_scope as materialized(
    select product.id product_id,product.internal_sku,product.name,price.amount sale_price,
      case when coalesce((recipe_cost->>'allowed')::boolean,false) then(recipe_cost->>'cost_per_portion')::numeric end projected_cost,
      case when price.amount>0 and coalesce((recipe_cost->>'allowed')::boolean,false) then round(price.amount-(recipe_cost->>'cost_per_portion')::numeric,2) end projected_margin,
      case when price.amount>0 and coalesce((recipe_cost->>'allowed')::boolean,false) then round(100*(price.amount-(recipe_cost->>'cost_per_portion')::numeric)/price.amount,2) end projected_margin_percent,
      policy.minimum_margin_percent,coalesce(policy.is_active,false) threshold_active,
      coalesce(sales.quantity_sold,0) quantity_sold,coalesce(sales.net_sales,0) realized_sales,
      case when coalesce(sales.missing_cost_count,0)=0 then coalesce(sales.recognized_cost,0) end realized_cost,
      case when coalesce(sales.missing_cost_count,0)=0 then coalesce(sales.net_sales,0)-coalesce(sales.recognized_cost,0) end realized_margin,
      case when coalesce(sales.missing_cost_count,0)=0 and coalesce(sales.net_sales,0)>0 then round(100*(sales.net_sales-sales.recognized_cost)/sales.net_sales,2) end realized_margin_percent,
      coalesce(sales.missing_cost_count,0) missing_cost_count,
      case when policy.is_active and price.amount>0 and coalesce((recipe_cost->>'allowed')::boolean,false)
        then round(100*(price.amount-(recipe_cost->>'cost_per_portion')::numeric)/price.amount,2)<policy.minimum_margin_percent else false end below_threshold
    from public.products product
    join public.product_culinary_roles role_data on role_data.company_id=product.company_id and role_data.product_id=product.id and role_data.role='dish'
    left join public.culinary_recipes recipe on recipe.company_id=product.company_id and recipe.product_id=product.id and recipe.recipe_kind='dish'
    left join public.culinary_recipe_versions active_version on active_version.recipe_id=recipe.id and active_version.status='active'
    left join lateral(select case when active_version.id is null then null else public.culinary_version_cost(active_version.id,active_version.portion_count,v_end+interval'1 day'-interval'1 microsecond',v_currency) end recipe_cost)cost_data on true
    left join lateral(select product_price.amount from public.product_prices product_price join public.price_lists price_list on price_list.id=product_price.price_list_id and price_list.is_active where product_price.product_id=product.id and product_price.currency_code=v_currency and product_price.valid_from<v_end+1 and(product_price.valid_to is null or product_price.valid_to>=v_start) order by product_price.valid_from desc,product_price.id desc limit 1)price on true
    left join public.restaurant_margin_policies policy on policy.company_id=p_company_id and policy.product_id=product.id
    left join lateral(
      select sum(item.quantity)quantity_sold,sum(item.taxable_amount)net_sales,sum(item.recognized_cost_amount)recognized_cost,count(*)filter(where item.recognized_cost_amount is null)missing_cost_count
      from public.sale_items item join public.sales sale on sale.id=item.sale_id
      where item.product_id=product.id and sale.company_id=p_company_id and sale.currency_code=v_currency and sale.completed_at::date between v_start and v_end and public.can_access_location(sale.location_id) and not exists(select 1 from public.sale_cancellations cancellation where cancellation.sale_id=sale.id)
    )sales on true
    where product.company_id=p_company_id and product.is_active and(v_query='' or lower(product.name)like'%'||v_query||'%' or lower(product.internal_sku)like'%'||v_query||'%')
  ),dish_paged as(select * from dish_scope order by below_threshold desc,coalesce(projected_margin_percent,-999),name,product_id limit v_size offset(v_dish_page-1)*v_size)
  select(select count(*)from dish_scope),(select count(*)from dish_scope where below_threshold),coalesce(jsonb_agg(to_jsonb(dish_paged)order by below_threshold desc,coalesce(projected_margin_percent,-999),name,product_id),'[]'::jsonb)
  into v_dish_total,v_below_threshold,v_dishes from dish_paged;

  select jsonb_build_object(
    'ingredients_with_cost',(select count(*)from public.product_culinary_roles role_data join public.products product on product.id=role_data.product_id where role_data.company_id=p_company_id and role_data.role='ingredient' and exists(select 1 from public.product_costs cost where cost.company_id=p_company_id and cost.product_id=product.id and cost.cost_type='replacement_cost' and cost.currency_code=v_currency and cost.valid_from<v_end+1)),
    'ingredients_changed',(select count(distinct change_data.product_id)from public.purchase_receipt_cost_changes change_data join public.purchase_receipts receipt on receipt.id=change_data.purchase_receipt_id and receipt.status='confirmed' where change_data.company_id=p_company_id and change_data.currency_code=v_currency and receipt.receipt_date between v_start and v_end and change_data.previous_amount is distinct from change_data.applied_amount),
    'dishes_below_threshold',coalesce(v_below_threshold,0),
    'realized_sales',coalesce((select sum(item.taxable_amount)from public.sale_items item join public.sales sale on sale.id=item.sale_id where sale.company_id=p_company_id and sale.currency_code=v_currency and sale.completed_at::date between v_start and v_end and public.can_access_location(sale.location_id) and not exists(select 1 from public.sale_cancellations cancellation where cancellation.sale_id=sale.id)),0),
    'realized_margin',case when not exists(select 1 from public.sale_items item join public.sales sale on sale.id=item.sale_id where sale.company_id=p_company_id and sale.currency_code=v_currency and sale.completed_at::date between v_start and v_end and item.recognized_cost_amount is null and not exists(select 1 from public.sale_cancellations cancellation where cancellation.sale_id=sale.id)) then coalesce((select sum(item.taxable_amount-item.recognized_cost_amount)from public.sale_items item join public.sales sale on sale.id=item.sale_id where sale.company_id=p_company_id and sale.currency_code=v_currency and sale.completed_at::date between v_start and v_end and public.can_access_location(sale.location_id) and not exists(select 1 from public.sale_cancellations cancellation where cancellation.sale_id=sale.id)),0)end
  )into v_summary;
  return jsonb_build_object('period',jsonb_build_object('from',v_start,'to',v_end,'previous_from',v_previous_start,'previous_to',v_previous_end),
    'currency_code',v_currency,'updated_at',now(),'summary',v_summary,
    'ingredients',v_ingredients,'ingredient_pagination',jsonb_build_object('page',v_ingredient_page,'page_size',v_size,'total',v_ingredient_total),
    'dishes',v_dishes,'dish_pagination',jsonb_build_object('page',v_dish_page,'page_size',v_size,'total',v_dish_total),
    'trace',jsonb_build_object('query','get_restaurant_weekly_cost_analysis','server_side',true,'sources',jsonb_build_array('product_costs','purchase_receipt_cost_changes','culinary_recipe_versions','product_prices','sale_items')));
end$$;

create or replace function public.restaurant_evaluate_margin_alerts(p_company_id uuid,p_principal_user_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_start date:=date_trunc('week',current_date)::date;v_end date:=date_trunc('week',current_date)::date+6;v_currency text;
  v_eval public.bi_alert_evaluations%rowtype;v_row record;v_result text;v_detected text[]:='{}';v_created integer:=0;v_updated integer:=0;v_resolved integer:=0;v_severity text;
begin
  if auth.role()<>'service_role' and(auth.uid() is null or not(
    public.has_company_permission(p_company_id,'manage_bi_alerts') or public.has_company_permission(p_company_id,'manage_recipes') or public.has_company_permission(p_company_id,'confirm_purchase_receipts')
  ))then raise exception 'No autorizado para evaluar márgenes.';end if;
  if not exists(select 1 from public.companies where id=p_company_id and product_experience_code='restaurant')then return jsonb_build_object('skipped',true);end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text,8232));
  v_currency:=coalesce((select base_currency_code from public.companies where id=p_company_id),'MXN');
  insert into public.bi_alert_evaluations(company_id,period_from,period_to,comparison_mode,status,rules_evaluated,principal_user_id)
  values(p_company_id,v_start,v_end,'previous_period','completed',1,coalesce(p_principal_user_id,auth.uid()))returning*into v_eval;
  for v_row in
    select product.id,product.name,price.amount sale_price,policy.minimum_margin_percent,
      (cost_data.recipe_cost->>'cost_per_portion')::numeric projected_cost,
      round(100*(price.amount-(cost_data.recipe_cost->>'cost_per_portion')::numeric)/price.amount,2) projected_margin_percent
    from public.restaurant_margin_policies policy
    join public.products product on product.id=policy.product_id and product.company_id=policy.company_id and product.is_active
    join public.product_culinary_roles role_data on role_data.company_id=product.company_id and role_data.product_id=product.id and role_data.role='dish'
    join public.culinary_recipes recipe on recipe.company_id=product.company_id and recipe.product_id=product.id and recipe.recipe_kind='dish'
    join public.culinary_recipe_versions active_version on active_version.recipe_id=recipe.id and active_version.status='active'
    join lateral(select public.culinary_version_cost(active_version.id,active_version.portion_count,clock_timestamp(),v_currency)recipe_cost)cost_data on coalesce((cost_data.recipe_cost->>'allowed')::boolean,false)
    join lateral(select product_price.amount from public.product_prices product_price join public.price_lists price_list on price_list.id=product_price.price_list_id and price_list.is_active where product_price.product_id=product.id and product_price.currency_code=v_currency and product_price.valid_from<=clock_timestamp()and(product_price.valid_to is null or product_price.valid_to>clock_timestamp())order by product_price.valid_from desc,product_price.id desc limit 1)price on price.amount>0
    where policy.company_id=p_company_id and policy.is_active
      and 100*(price.amount-(cost_data.recipe_cost->>'cost_per_portion')::numeric)/price.amount<policy.minimum_margin_percent
  loop
    v_severity:=case when v_row.projected_margin_percent<=v_row.minimum_margin_percent-10 then'critical'else'warning'end;
    v_detected:=array_append(v_detected,'restaurant_dish_margin:'||v_row.id::text);
    v_result:=public.bi_store_detected_alert(v_eval.id,p_company_id,v_detected[array_length(v_detected,1)],
      'restaurant_dish_margin_below_threshold','threshold_breach','gross_margin',v_start,v_end,v_start-7,v_start-1,'previous_period',
      jsonb_build_object('product_id',v_row.id),'product',v_row.id,v_row.name,v_severity,v_row.projected_margin_percent,null,
      v_row.minimum_margin_percent,round(v_row.sale_price-v_row.projected_cost,2),v_row.projected_margin_percent-v_row.minimum_margin_percent,
      format('%s tiene margen proyectado de %s%%; el límite configurado es %s%%.',v_row.name,v_row.projected_margin_percent,v_row.minimum_margin_percent),
      'Revisa el costo de sus insumos, el tamaño de la porción o el precio de venta.',
      jsonb_build_object('sale_price',v_row.sale_price,'projected_cost',v_row.projected_cost,'projected_margin_percent',v_row.projected_margin_percent,'threshold_percent',v_row.minimum_margin_percent,'rule_version',1));
    if v_result='created'then v_created:=v_created+1;else v_updated:=v_updated+1;end if;
  end loop;
  update public.bi_alerts alert set status='resolved',resolved_at=now(),resolved_by=null,
    resolution_reason='El margen proyectado volvió a cumplir el límite configurado.',updated_at=now(),last_evaluation_id=v_eval.id
  where alert.company_id=p_company_id and alert.rule_code='restaurant_dish_margin_below_threshold' and alert.status in('active','reviewed')
    and not(alert.condition_key=any(v_detected));get diagnostics v_resolved=row_count;
  insert into public.bi_alert_events(company_id,alert_id,event_type,from_status,to_status,reason,snapshot)
  select p_company_id,alert.id,'resolved','active','resolved',alert.resolution_reason,jsonb_build_object('evaluation_id',v_eval.id,'automatic',true)
  from public.bi_alerts alert where alert.company_id=p_company_id and alert.rule_code='restaurant_dish_margin_below_threshold'
    and alert.last_evaluation_id=v_eval.id and alert.status='resolved' and alert.resolved_by is null;
  update public.bi_alert_evaluations set conditions_detected=coalesce(array_length(v_detected,1),0),alerts_created=v_created,
    alerts_updated=v_updated,alerts_resolved=v_resolved,completed_at=now(),trace=jsonb_build_object('query','restaurant_evaluate_margin_alerts','rule_version',1)
  where id=v_eval.id;
  return jsonb_build_object('evaluation_id',v_eval.id,'conditions_detected',coalesce(array_length(v_detected,1),0),'created',v_created,'updated',v_updated,'resolved',v_resolved);
end$$;

revoke all on function public.get_restaurant_weekly_cost_analysis(uuid,date,text,integer,integer,integer)from public,anon;
revoke all on function public.restaurant_evaluate_margin_alerts(uuid,uuid)from public,anon;
grant execute on function public.get_restaurant_weekly_cost_analysis(uuid,date,text,integer,integer,integer)to authenticated;
grant execute on function public.restaurant_evaluate_margin_alerts(uuid,uuid)to authenticated,service_role;

notify pgrst,'reload schema';
commit;
