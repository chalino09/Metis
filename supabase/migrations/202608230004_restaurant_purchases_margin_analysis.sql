-- Restaurante · compras directas, análisis semanal y alertas de margen.
-- Volumen operativo esperado: 5–100 partidas por recepción manual.
-- Volúmenes mayores permanecen en el Centro de Migraciones.

begin;

insert into public.role_permissions(role_id,permission_id)
select role_data.id,permission_data.id
from public.roles role_data
cross join public.permissions permission_data
where role_data.code='sucursal'
  and permission_data.code in(
    'view_suppliers','view_purchase_receipts','manage_purchase_receipt_drafts',
    'confirm_purchase_receipts'
  )
on conflict do nothing;

create table public.restaurant_margin_policies(
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  minimum_margin_percent numeric(9,4) not null check(minimum_margin_percent>=0 and minimum_margin_percent<100),
  is_active boolean not null default true,
  updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(company_id,product_id)
);
create trigger restaurant_margin_policies_updated_at before update on public.restaurant_margin_policies
for each row execute function public.set_updated_at();
alter table public.restaurant_margin_policies enable row level security;
create policy restaurant_margin_policies_read on public.restaurant_margin_policies for select to authenticated
using(public.has_company_permission(company_id,'view_costs'));
revoke all on public.restaurant_margin_policies from public,anon,authenticated;
grant select on public.restaurant_margin_policies to authenticated;

insert into public.bi_alert_rules(
  code,version,metric_code,favorable_direction,comparison_type,threshold,minimum_data,
  severity_policy,dimensions,explanation_template,suggested_action,auto_resolve,is_active
) values(
  'restaurant_dish_margin_below_threshold',1,'gross_margin','up','threshold','{}','{"sale_price_min":0.01}',
  '{"warning":"warning","critical":"critical"}',array['product'],
  'El margen proyectado del platillo está debajo de su límite.','Revisa costos, porción o precio antes de continuar vendiendo.',true,true
) on conflict(code) do update set
  version=excluded.version,metric_code=excluded.metric_code,favorable_direction=excluded.favorable_direction,
  comparison_type=excluded.comparison_type,threshold=excluded.threshold,minimum_data=excluded.minimum_data,
  severity_policy=excluded.severity_policy,dimensions=excluded.dimensions,
  explanation_template=excluded.explanation_template,suggested_action=excluded.suggested_action,
  auto_resolve=true,is_active=true,updated_at=now();

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
      cost.amount current_cost,cost.currency_code,
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

create or replace function public.confirm_restaurant_purchase_receipt(
  p_company_id uuid,p_supplier_id uuid,p_location_id uuid,p_receipt_date date,
  p_document_reference text,p_notes text,p_lines jsonb,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_order_id uuid;v_order_folio text;v_receipt_id uuid;v_receipt_folio text;v_line jsonb;v_lot jsonb;
  v_product public.products%rowtype;v_conversion public.product_purchase_units%rowtype;v_purchase_unit uuid;v_unit text;
  v_order_line_id uuid;v_receipt_line_id uuid;v_line_number integer:=0;v_quantity numeric;v_unit_cost numeric;
  v_product_id uuid;v_lot_controlled boolean;
  v_factor numeric;v_lot_total numeric;v_lot_quantity numeric;v_lot_count integer;v_result jsonb;v_existing public.purchase_receipts%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_purchase_receipt_drafts')
    or not public.has_company_permission(p_company_id,'confirm_purchase_receipts') then raise exception 'No autorizado para registrar entradas de compra.';end if;
  if p_client_request_id is null then raise exception 'La referencia de la operación es obligatoria.';end if;
  select * into v_existing from public.purchase_receipts where company_id=p_company_id and client_request_id=p_client_request_id;
  if found then return jsonb_build_object('receipt_id',v_existing.id,'folio',v_existing.folio,'status',v_existing.status,'idempotent',true);end if;
  if not exists(select 1 from public.companies where id=p_company_id and product_experience_code='restaurant') then raise exception 'La compra directa sólo está disponible en Restaurante.';end if;
  if not exists(select 1 from public.suppliers where id=p_supplier_id and company_id=p_company_id and is_active) then raise exception 'Selecciona un proveedor activo.';end if;
  if not exists(select 1 from public.locations where id=p_location_id and company_id=p_company_id and is_active and public.can_access_location(id)) then raise exception 'Selecciona una sucursal o almacén disponible.';end if;
  if p_receipt_date is null or p_receipt_date>current_date then raise exception 'La fecha de recepción no puede estar en el futuro.';end if;
  if jsonb_typeof(coalesce(p_lines,'null'::jsonb))<>'array' or jsonb_array_length(p_lines) not between 1 and 100 then raise exception 'Captura entre 1 y 100 insumos por recepción.';end if;
  if length(trim(coalesce(p_document_reference,'')))>160 or length(trim(coalesce(p_notes,'')))>1000 then raise exception 'La referencia o las notas son demasiado largas.';end if;

  insert into public.purchase_orders(
    company_id,supplier_id,folio,status,origin,currency_code,ordered_date,expected_date,
    supplier_reference,notes,submitted_at,submitted_by,decided_at,decided_by
  ) values(
    p_company_id,p_supplier_id,public.next_purchase_order_folio(p_company_id,false),'draft','operational',
    coalesce((select base_currency_code from public.companies where id=p_company_id),'MXN'),
    p_receipt_date,p_receipt_date,nullif(trim(p_document_reference),''),
    concat_ws(' · ','Compra directa de Restaurante',nullif(trim(p_notes),'')),now(),auth.uid(),now(),auth.uid()
  ) returning id,folio into v_order_id,v_order_folio;

  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_line_number:=v_line_number+1;
    begin v_quantity:=(v_line->>'quantity')::numeric;v_unit_cost:=(v_line->>'unit_cost')::numeric;
    exception when others then raise exception 'Revisa cantidad y precio en la partida %.',v_line_number;end;
    if v_quantity<=0 or v_unit_cost<0 then raise exception 'Cantidad y precio deben ser válidos en la partida %.',v_line_number;end if;
    select product.* into v_product from public.products product
    join public.product_culinary_roles role_data on role_data.company_id=product.company_id and role_data.product_id=product.id and role_data.role='ingredient'
    where product.id=nullif(v_line->>'product_id','')::uuid and product.company_id=p_company_id and product.is_active and product.is_inventory_tracked for update of product;
    if not found then raise exception 'La partida % debe usar un insumo activo de Restaurante.',v_line_number;end if;
    select * into v_conversion from public.product_purchase_units where product_id=v_product.id;
    v_purchase_unit:=coalesce(v_conversion.purchase_unit_id,v_product.purchase_unit_id,v_product.base_unit_id);
    v_factor:=coalesce(v_conversion.base_units_per_purchase_unit,1);
    select code into v_unit from public.units_of_measure where id=v_purchase_unit and company_id=p_company_id and is_active;
    if v_unit is null or v_factor<=0 then raise exception 'Configura la unidad de compra de %.',v_product.name;end if;
    insert into public.purchase_order_lines(
      company_id,purchase_order_id,line_number,product_id,description,unit,purchase_unit_id,
      base_units_per_purchase_unit,quantity,unit_cost,expected_date
    ) values(
      p_company_id,v_order_id,v_line_number,v_product.id,v_product.name,v_unit,v_purchase_unit,
      v_factor,v_quantity,v_unit_cost,p_receipt_date
    ) returning id into v_order_line_id;
  end loop;
  perform public.recalculate_purchase_order(v_order_id);
  update public.purchase_orders set status='approved',updated_by=auth.uid() where id=v_order_id;
  insert into public.purchase_order_decisions(company_id,purchase_order_id,decision,reason,actor_id)
  values(p_company_id,v_order_id,'submitted','Compra directa capturada al recibir.',auth.uid()),
    (p_company_id,v_order_id,'approved','Entrada confirmada por el responsable de la recepción.',auth.uid());

  v_receipt_folio:=public.next_purchase_receipt_folio(p_company_id);
  insert into public.purchase_receipts(
    company_id,purchase_order_id,supplier_id,location_id,folio,status,receipt_date,
    document_reference,notes,client_request_id,created_by,updated_by
  ) values(
    p_company_id,v_order_id,p_supplier_id,p_location_id,v_receipt_folio,'draft',p_receipt_date,
    nullif(trim(p_document_reference),''),nullif(trim(p_notes),''),p_client_request_id,auth.uid(),auth.uid()
  ) returning id into v_receipt_id;

  v_line_number:=0;
  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_line_number:=v_line_number+1;v_quantity:=(v_line->>'quantity')::numeric;
    select id,product_id,base_units_per_purchase_unit,unit_cost into v_order_line_id,v_product_id,v_factor,v_unit_cost
    from public.purchase_order_lines where purchase_order_id=v_order_id and line_number=v_line_number;
    insert into public.purchase_receipt_lines(
      company_id,purchase_receipt_id,purchase_order_line_id,product_id,quantity,base_units_per_purchase_unit,unit_cost
    ) values(p_company_id,v_receipt_id,v_order_line_id,v_product_id,v_quantity,v_factor,v_unit_cost)
    returning id into v_receipt_line_id;
    select lot_controlled into v_lot_controlled from public.products where id=v_product_id;
    if v_lot_controlled then
      if jsonb_typeof(coalesce(v_line->'lots','null'::jsonb))<>'array' or jsonb_array_length(v_line->'lots')=0 then raise exception 'Captura lote y caducidad para la partida %.',v_line_number;end if;
      v_lot_total:=0;v_lot_count:=0;
      for v_lot in select value from jsonb_array_elements(v_line->'lots') loop
        begin v_lot_quantity:=(v_lot->>'quantity')::numeric;exception when others then raise exception 'Cantidad de lote inválida en la partida %.',v_line_number;end;
        if nullif(trim(v_lot->>'lot_code'),'') is null or nullif(v_lot->>'expiration_date','')::date is null or v_lot_quantity<=0 then raise exception 'Completa los lotes de la partida %.',v_line_number;end if;
        insert into public.purchase_receipt_lots(company_id,purchase_receipt_line_id,product_id,lot_code,expiration_date,quantity)
        values(p_company_id,v_receipt_line_id,v_product_id,upper(trim(v_lot->>'lot_code')),(v_lot->>'expiration_date')::date,v_lot_quantity);
        v_lot_total:=v_lot_total+v_lot_quantity;v_lot_count:=v_lot_count+1;
      end loop;
      if abs(v_lot_total-v_quantity)>0.000001 then raise exception 'Los lotes de la partida % deben sumar la cantidad recibida.',v_line_number;end if;
    elsif v_line?'lots' and jsonb_array_length(coalesce(v_line->'lots','[]'::jsonb))>0 then raise exception 'La partida % no requiere lotes.',v_line_number;end if;
  end loop;

  v_result:=public.confirm_purchase_receipt(p_company_id,v_receipt_id,gen_random_uuid());
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'restaurant.purchase_received','purchase_receipt',v_receipt_id,
    jsonb_build_object('purchase_order_id',v_order_id,'supplier_id',p_supplier_id,'location_id',p_location_id,
      'line_count',jsonb_array_length(p_lines),'client_request_id',p_client_request_id,'capture_mode','direct_restaurant'));
  begin perform public.restaurant_evaluate_margin_alerts(p_company_id,auth.uid());exception when undefined_function then null;when others then null;end;
  return v_result||jsonb_build_object('receipt_id',v_receipt_id,'folio',v_receipt_folio,'purchase_order_id',v_order_id,'purchase_order_folio',v_order_folio,'idempotent',false);
end$$;

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

create or replace function public.set_restaurant_margin_threshold(
  p_company_id uuid,p_product_id uuid,p_minimum_margin_percent numeric,p_active boolean,p_reason text,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_previous jsonb;v_policy public.restaurant_margin_policies%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_recipes') or not public.has_company_permission(p_company_id,'view_costs')then raise exception 'No autorizado para configurar límites de margen.';end if;
  if p_client_request_id is null or length(trim(coalesce(p_reason,'')))<5 then raise exception 'Indica un motivo de al menos 5 caracteres.';end if;
  if p_minimum_margin_percent is null or p_minimum_margin_percent<0 or p_minimum_margin_percent>=100 then raise exception 'El límite debe estar entre 0 y 99.99 por ciento.';end if;
  if not exists(select 1 from public.product_culinary_roles where company_id=p_company_id and product_id=p_product_id and role='dish')then raise exception 'Selecciona un platillo de Restaurante.';end if;
  select to_jsonb(policy)into v_previous from public.restaurant_margin_policies policy where policy.company_id=p_company_id and policy.product_id=p_product_id for update;
  insert into public.restaurant_margin_policies(company_id,product_id,minimum_margin_percent,is_active,updated_by)
  values(p_company_id,p_product_id,round(p_minimum_margin_percent,4),coalesce(p_active,true),auth.uid())
  on conflict(company_id,product_id)do update set minimum_margin_percent=excluded.minimum_margin_percent,is_active=excluded.is_active,updated_by=auth.uid(),updated_at=now()
  returning*into v_policy;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'restaurant.margin_threshold_set','product',p_product_id,jsonb_build_object('previous',v_previous,'current',to_jsonb(v_policy),'reason',trim(p_reason),'request_id',p_client_request_id));
  perform public.restaurant_evaluate_margin_alerts(p_company_id,auth.uid());
  return to_jsonb(v_policy);
end$$;

create or replace function public.bi_evaluate_all_alerts()returns void language plpgsql security definer set search_path=public as $$
declare company_row record;v_principal uuid;
begin
  for company_row in select id from public.companies loop
    select ur.user_id into v_principal from public.user_roles ur join public.roles role_data on role_data.id=ur.role_id
    where ur.company_id=company_row.id and role_data.code='direccion_admin'order by ur.created_at limit 1;
    if v_principal is not null then
      begin perform public.bi_evaluate_company_alerts(company_row.id,current_date-29,current_date,'previous_period',v_principal);exception when others then null;end;
      begin perform public.restaurant_evaluate_margin_alerts(company_row.id,v_principal);exception when others then null;end;
    end if;
  end loop;
end$$;

revoke all on function public.search_restaurant_purchase_ingredients(uuid,text,integer)from public,anon;
revoke all on function public.confirm_restaurant_purchase_receipt(uuid,uuid,uuid,date,text,text,jsonb,uuid)from public,anon;
revoke all on function public.get_restaurant_weekly_cost_analysis(uuid,date,text,integer,integer,integer)from public,anon;
revoke all on function public.restaurant_evaluate_margin_alerts(uuid,uuid)from public,anon;
revoke all on function public.set_restaurant_margin_threshold(uuid,uuid,numeric,boolean,text,uuid)from public,anon;
grant execute on function public.search_restaurant_purchase_ingredients(uuid,text,integer)to authenticated;
grant execute on function public.confirm_restaurant_purchase_receipt(uuid,uuid,uuid,date,text,text,jsonb,uuid)to authenticated;
grant execute on function public.get_restaurant_weekly_cost_analysis(uuid,date,text,integer,integer,integer)to authenticated;
grant execute on function public.restaurant_evaluate_margin_alerts(uuid,uuid)to authenticated,service_role;
grant execute on function public.set_restaurant_margin_threshold(uuid,uuid,numeric,boolean,text,uuid)to authenticated;
revoke all on function public.bi_evaluate_all_alerts()from public,anon,authenticated;
grant execute on function public.bi_evaluate_all_alerts()to service_role;

notify pgrst,'reload schema';
commit;
