-- Costo reconocido por partida vendida.
-- La evidencia se congela al insertar sale_items; ningún lector vuelve a
-- reconstruir ventas confirmadas desde el costo vigente del catálogo.

alter table public.sale_items
  add column if not exists recognized_unit_cost numeric(18,6),
  add column if not exists recognized_cost_method text,
  add column if not exists recognized_cost_currency_code text,
  add column if not exists recognized_product_cost_id uuid references public.product_costs(id) on delete restrict,
  add column if not exists recognized_cost_amount numeric(18,6)
    generated always as (
      case when recognized_unit_cost is null then null
      else round(quantity * recognized_unit_cost, 6) end
    ) stored;

alter table public.sale_items drop constraint if exists sale_items_recognized_cost_complete;
alter table public.sale_items add constraint sale_items_recognized_cost_complete check (
  (recognized_unit_cost is null
    and recognized_cost_method is null
    and recognized_cost_currency_code is null
    and recognized_product_cost_id is null)
  or
  (recognized_unit_cost is not null and recognized_unit_cost >= 0
    and recognized_cost_method in ('replacement_cost','standard_cost','average_cost')
    and recognized_cost_currency_code ~ '^[A-Z]{3}$'
    and recognized_product_cost_id is not null)
);

create index if not exists sale_items_recognized_cost_idx
  on public.sale_items(sale_id, recognized_product_cost_id)
  where recognized_product_cost_id is not null;

-- Los roles que sólo ven ventas no deben obtener el costo unitario ni su total
-- al leer sale_items. Las RPC security definer de BI y contabilidad son la
-- única frontera que agrega margen tras verificar view_costs.
revoke select on public.sale_items from public,anon,authenticated;
grant select (
  id,sale_id,product_id,product_code,product_name,unit_name,quantity,price_list_id,
  unit_price_amount,gross_amount,discount_percent,discount_amount,taxable_amount,
  tax_amount,total_amount,created_at
) on public.sale_items to authenticated;

create or replace function public.capture_sale_item_recognized_cost()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  v_sale public.sales%rowtype;
  v_method text;
  v_cost public.product_costs%rowtype;
begin
  select * into v_sale
  from public.sales
  where id = new.sale_id;

  if not found then
    raise exception 'La venta de la partida no existe.';
  end if;

  -- La matriz aprobada define el método. Antes de M4B se conserva la regla
  -- canónica ya usada por el dominio: costo de reemplazo.
  select cost_method into v_method
  from public.accounting_event_rule_sets
  where company_id = v_sale.company_id and status = 'approved';
  v_method := coalesce(v_method, 'replacement_cost');

  select * into v_cost
  from public.product_costs
  where company_id = v_sale.company_id
    and product_id = new.product_id
    and cost_type = v_method
    and currency_code = v_sale.currency_code
    and valid_from <= v_sale.completed_at
    and (valid_to is null or valid_to > v_sale.completed_at)
  order by valid_from desc, id desc
  limit 1;

  if found then
    new.recognized_unit_cost := v_cost.amount;
    new.recognized_cost_method := v_method;
    new.recognized_cost_currency_code := v_cost.currency_code;
    new.recognized_product_cost_id := v_cost.id;
  else
    -- La ausencia es evidencia explícita: no se suplanta con costo actual ni cero.
    new.recognized_unit_cost := null;
    new.recognized_cost_method := null;
    new.recognized_cost_currency_code := null;
    new.recognized_product_cost_id := null;
  end if;

  return new;
end;
$$;

drop trigger if exists sale_items_capture_recognized_cost on public.sale_items;
create trigger sale_items_capture_recognized_cost
before insert on public.sale_items
for each row execute function public.capture_sale_item_recognized_cost();

-- La contabilidad usa exactamente el costo que quedó en la partida. El trigger
-- diferido de sales continúa ejecutándose al final de la misma transacción.
create or replace function public.capture_sale_accounting_event()
returns trigger language plpgsql security definer set search_path=public as $$
declare
  v_set public.accounting_event_rule_sets%rowtype;
  v_config public.accounting_config_versions%rowtype;
  v_payment public.sale_payments%rowtype;
  v_cost numeric:=0;
  v_items bigint:=0;
  v_costed bigint:=0;
  v_settlement text;
  v_tax_role text;
  v_lines jsonb;
begin
  if not public.accounting_operational_matrix_active(new.company_id) then return new; end if;
  select * into v_set from public.accounting_event_rule_sets where company_id=new.company_id and status='approved';
  select * into v_config from public.accounting_config_versions where id=v_set.accounting_config_version_id;
  if new.currency_code<>v_config.base_currency then raise exception 'La venta debe estar en la moneda base contable.'; end if;

  select coalesce(sum(si.recognized_cost_amount),0), count(*), count(si.recognized_cost_amount)
  into v_cost,v_items,v_costed
  from public.sale_items si
  where si.sale_id=new.id;

  if v_items=0 or v_costed<>v_items then
    raise exception 'La venta no puede contabilizarse: falta costo reconocido para una o más partidas.';
  end if;

  if new.sale_type='cash' then
    select * into v_payment from public.sale_payments where sale_id=new.id;
    if not found then raise exception 'La venta de contado no tiene liquidación.'; end if;
    v_settlement:=case when v_payment.settlement_kind='cash_drawer' then 'cash' else 'banks' end;
    v_tax_role:='vat_collected';
  else
    v_settlement:='accounts_receivable';
    v_tax_role:='vat_pending';
  end if;

  v_lines:=jsonb_build_array(jsonb_build_object('role',v_settlement,'debit',new.total_amount,'credit',0,'description','Liquidación de venta'));
  if new.discount_amount>0 then
    v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','sales_discounts','debit',new.discount_amount,'credit',0,'description','Descuento comercial'));
  end if;
  v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','sales_revenue','debit',0,'credit',new.subtotal_amount,'description','Venta'));
  if new.tax_amount>0 then
    v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role',v_tax_role,'debit',0,'credit',new.tax_amount,'description','IVA de venta'));
  end if;
  if round(v_cost,6)>0 then
    v_lines:=v_lines||jsonb_build_array(
      jsonb_build_object('role','cost_of_goods_sold','debit',round(v_cost,6),'credit',0,'description','Costo de venta'),
      jsonb_build_object('role','inventory','debit',0,'credit',round(v_cost,6),'description','Salida de inventario')
    );
  end if;
  perform public.capture_accounting_event(
    new.company_id,'sale_confirmed','sale',new.id,1,new.completed_at::date,new.completed_at,v_lines,
    jsonb_build_object('description','Venta confirmada','cost_method',v_set.cost_method,'costed_item_count',v_costed,'item_count',v_items)
  );
  return new;
end;
$$;

-- Contrato reutilizable para agregaciones. Sólo presenta ventas no canceladas,
-- moneda solicitada y la cobertura necesaria para no publicar un margen parcial.
create or replace function public.sale_margin_coverage(
  p_company_id uuid,
  p_date_from date,
  p_date_to date,
  p_currency_code text,
  p_location_id uuid default null,
  p_product_id uuid default null,
  p_customer_id uuid default null
) returns table(
  net_sales numeric,
  recognized_cost numeric,
  gross_margin numeric,
  item_count bigint,
  costed_item_count bigint,
  missing_cost_item_count bigint
)
language sql stable security definer set search_path=public as $$
  select
    coalesce(sum(si.taxable_amount),0),
    coalesce(sum(si.recognized_cost_amount),0),
    case when count(*) filter(where si.recognized_cost_amount is null)=0
      then coalesce(sum(si.taxable_amount-si.recognized_cost_amount),0) end,
    count(*),
    count(si.recognized_cost_amount),
    count(*) filter(where si.recognized_cost_amount is null)
  from public.sales s
  join public.sale_items si on si.sale_id=s.id
  where s.company_id=p_company_id
    and s.currency_code=p_currency_code
    and s.completed_at::date between p_date_from and p_date_to
    and public.can_access_location(s.location_id)
    and (p_location_id is null or s.location_id=p_location_id)
    and (p_product_id is null or si.product_id=p_product_id)
    and (p_customer_id is null or s.customer_id=p_customer_id)
    and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id);
$$;

revoke all on function public.sale_margin_coverage(uuid,date,date,text,uuid,uuid,uuid) from public,anon,authenticated;

-- El catálogo se amplía sin reescribir los contratos de Fase 3/5.
alter function public.bi_get_metric_catalog(uuid) rename to bi_get_metric_catalog_before_recognized_cost;
revoke all on function public.bi_get_metric_catalog_before_recognized_cost(uuid) from public,anon,authenticated;
create or replace function public.bi_get_metric_catalog(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare c jsonb; m jsonb; v_currency text; v_can_cost boolean;
begin
  c:=public.bi_get_metric_catalog_before_recognized_cost(p_company_id);
  v_currency:=c->>'currency_code';
  v_can_cost:=public.has_company_permission(p_company_id,'view_costs');
  select coalesce(jsonb_agg(
    case
      when value->>'code'='gross_margin' then jsonb_build_object(
        'code','gross_margin','name','Margen bruto','module','Margen',
        'formula','Σ importe gravable − Σ costo reconocido congelado por partida',
        'unit','currency','source','sales + sale_items.recognized_cost_amount + sale_cancellations',
        'grain','flow_day','dimensions',jsonb_build_array('period','location','product','category'),
        'kind','accrual','visualizations',jsonb_build_array('line','bar','area','scatter'),'drilldown',true,
        'available',v_currency is not null and v_can_cost,
        'unavailable_reason',case when not v_can_cost then 'No tienes permiso para consultar costos y margen.' when v_currency is null then 'Falta una moneda base contable aprobada.' end,
        'limitations','Sólo se publica cuando todas las partidas del alcance tienen costo reconocido; ventas históricas sin snapshot mantienen el resultado incompleto.'
      )
      when value->>'code' ~ '^gross_margin_(actual|variance|projection|attainment)$' then
        value || jsonb_build_object('available',v_currency is not null and v_can_cost,'unavailable_reason',case when not v_can_cost then 'No tienes permiso para consultar costos y margen.' when v_currency is null then 'Falta una moneda base contable aprobada.' end,
          'limitations','El resultado exige cobertura completa de costo reconocido en todas las partidas del alcance.')
      else value
    end
  ),'[]'::jsonb) into m
  from jsonb_array_elements(c->'metrics');
  return jsonb_set(c,'{metrics}',m);
end;
$$;
revoke all on function public.bi_get_metric_catalog(uuid) from public,anon;
grant execute on function public.bi_get_metric_catalog(uuid) to authenticated;

-- El motor de presupuestos usa la misma cobertura, evitando calcular margen de
-- una parte del periodo como si fuera el total.
create or replace function public.bi_budget_actual(p_version_id uuid,p_from date,p_to date)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v public.bi_budget_versions%rowtype;
  parent_location uuid;
  amount numeric:=0;
  rows_count bigint:=0;
  attributed bigint:=0;
  missing_cost bigint:=0;
begin
  select * into v from public.bi_budget_versions where id=p_version_id;
  if not found or not public.bi_can_view_budget_version(v.id) then raise exception 'Presupuesto no disponible.'; end if;
  if v.metric_code='gross_margin' and not public.has_company_permission(v.company_id,'view_costs') then
    return jsonb_build_object('available',false,'value',null,'reason','No tienes permiso para consultar costos y margen.');
  end if;
  if v.parent_version_id is not null then
    select location_id into parent_location from public.bi_budget_versions where id=v.parent_version_id and scope_type='location';
  end if;

  select
    coalesce(sum(case when v.metric_code='units_sold' then si.quantity when v.metric_code='gross_margin' then si.taxable_amount-si.recognized_cost_amount else si.taxable_amount end),0),
    count(distinct s.id),
    count(distinct s.id) filter(where sr.id is not null),
    count(*) filter(where v.metric_code='gross_margin' and si.recognized_cost_amount is null)
  into amount,rows_count,attributed,missing_cost
  from public.sales s
  join public.sale_items si on si.sale_id=s.id
  join public.products p on p.id=si.product_id
  left join public.sale_responsibilities sr on sr.sale_id=s.id
  where s.company_id=v.company_id and s.completed_at::date between p_from and p_to
    and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id)
    and (v.metric_code<>'gross_margin' or s.currency_code=v.unit_code)
    and public.can_access_location(s.location_id)
    and (v.location_id is null or s.location_id=v.location_id)
    and (parent_location is null or s.location_id=parent_location)
    and (v.collaborator_id is null or sr.collaborator_id=v.collaborator_id)
    and (v.category_id is null or p.category_id=v.category_id);

  if v.metric_code='gross_margin' and missing_cost>0 then
    return jsonb_build_object('available',false,'value',null,'reason',format('Hay %s partidas sin costo reconocido en el alcance.',missing_cost),
      'operation_count',rows_count,'missing_cost_item_count',missing_cost);
  end if;
  return jsonb_build_object('available',true,'value',amount,'operation_count',rows_count,
    'attributed_operation_count',attributed,'attribution_limited',v.collaborator_id is not null,
    'missing_cost_item_count',missing_cost);
end;
$$;

-- Los contratos de presupuesto ya existían; sólo se habilitan las variantes de
-- margen cuando su resultado real conserva cobertura completa.
create or replace function public.bi_budget_explorer_query(
  p_company_id uuid,p_metric_codes text[],p_dimension text,p_visualization text,p_date_from date,p_date_to date,
  p_page integer,p_page_size integer
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);
  v_total bigint;
  v_items jsonb;
  v_chart jsonb;
  first_code text;
  target text;
  suffix text;
begin
  if not public.has_company_permission(p_company_id,'view_bi_budgets') then raise exception 'No autorizado para consultar presupuestos.'; end if;
  if coalesce(cardinality(p_metric_codes),0)=0 then raise exception 'Selecciona al menos una métrica presupuestal.'; end if;
  first_code:=p_metric_codes[1];
  target:=regexp_replace(first_code,'_(budget|actual|variance|projection|attainment)$','');
  if exists(select 1 from unnest(p_metric_codes)c where regexp_replace(c,'_(budget|actual|variance|projection|attainment)$','')<>target) then
    raise exception 'Combina indicadores del mismo objetivo base.';
  end if;
  if target='gross_margin' and exists(select 1 from unnest(p_metric_codes)c where c!~'_budget$')
    and not public.has_company_permission(p_company_id,'view_costs') then
    raise exception 'No tienes permiso para consultar costos y margen.';
  end if;
  if p_dimension not in('period','location','responsible','category') then raise exception 'Dimensión no compatible con presupuestos.'; end if;

  drop table if exists pg_temp.bi_budget_explorer_result;
  create temporary table bi_budget_explorer_result(
    metric_code text,group_key text,group_label text,current_value numeric,previous_value numeric,available boolean,reason text
  ) on commit drop;

  foreach first_code in array p_metric_codes loop
    suffix:=regexp_replace(first_code,'^.*_(budget|actual|variance|projection|attainment)$','\1');
    insert into bi_budget_explorer_result
    select first_code,
      case p_dimension when 'period' then v.period_start::text when 'location' then coalesce(v.location_id::text,'company')
        when 'responsible' then coalesce(v.collaborator_id::text,'unassigned') else coalesce(v.category_id::text,'all') end,
      case p_dimension when 'period' then to_char(v.period_start,'Mon YYYY') when 'location' then coalesce(l.name,'Empresa')
        when 'responsible' then coalesce(c.display_name,'Sin responsable') else coalesce(pc.name,'Todas las categorías') end,
      case suffix
        when 'budget' then v.value
        when 'actual' then a.value
        when 'variance' then case when a.available then v.value-a.value end
        when 'projection' then case when a.available then case when current_date>=v.period_end then a.value
          else round(a.value/greatest(current_date-v.period_start+1,1)*(v.period_end-v.period_start+1),6) end end
        else case when a.available and v.value<>0 then round(a.value/v.value*100,2) end
      end,
      null,
      case when suffix='budget' then true else a.available end,
      case when suffix='budget' or a.available then null else coalesce(a.reason,'Resultado real no disponible.') end
    from public.bi_budget_versions v
    left join public.locations l on l.id=v.location_id
    left join public.collaborators c on c.id=v.collaborator_id
    left join public.product_categories pc on pc.id=v.category_id
    cross join lateral(select public.bi_budget_actual(v.id,v.period_start,least(current_date,v.period_end)) payload) raw
    cross join lateral(select (raw.payload->>'value')::numeric value,
      coalesce((raw.payload->>'available')::boolean,false) available,raw.payload->>'reason' reason) a
    where v.company_id=p_company_id and v.status='approved' and v.metric_code=target and v.budget_kind='independent'
      and v.period_end>=p_date_from and v.period_start<=p_date_to and public.bi_can_view_budget_version(v.id);
  end loop;

  select count(*) into v_total from bi_budget_explorer_result;
  select coalesce(jsonb_agg(to_jsonb(x) order by group_label,metric_code),'[]'::jsonb) into v_items
  from (select * from bi_budget_explorer_result order by group_label,metric_code limit v_size offset(v_page-1)*v_size)x;
  select coalesce(jsonb_agg(to_jsonb(x) order by group_key,metric_code),'[]'::jsonb) into v_chart
  from (select * from bi_budget_explorer_result order by group_key,metric_code limit 500)x;
  return jsonb_build_object(
    'query',jsonb_build_object('metric_codes',p_metric_codes,'dimension',p_dimension,'visualization',p_visualization),
    'period',jsonb_build_object('from',p_date_from,'to',p_date_to),
    'currency_code',(public.bi_get_metric_catalog(p_company_id)->>'currency_code'),'updated_at',now(),
    'chart',v_chart,'items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total),
    'trace',jsonb_build_object('query','bi_budget_explorer_query','company_id',p_company_id)
  );
end;
$$;
revoke all on function public.bi_budget_explorer_query(uuid,text[],text,text,date,date,integer,integer) from public,anon;
grant execute on function public.bi_budget_explorer_query(uuid,text[],text,text,date,date,integer,integer) to authenticated;

-- KPI ejecutivo: agrega margen sólo cuando ambos periodos son completos.
alter function public.bi_get_executive_summary(uuid,date,date,uuid,uuid,uuid,uuid)
  rename to bi_get_executive_summary_before_recognized_cost;
revoke all on function public.bi_get_executive_summary_before_recognized_cost(uuid,date,date,uuid,uuid,uuid,uuid) from public,anon,authenticated;
create or replace function public.bi_get_executive_summary(
  p_company_id uuid,p_date_from date,p_date_to date,p_location_id uuid default null,p_product_id uuid default null,p_customer_id uuid default null,p_supplier_id uuid default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  r jsonb;
  v_currency text;
  v_days integer;
  v_previous_from date;
  v_previous_to date;
  v_current_margin numeric;
  v_previous_margin numeric;
  v_current_items bigint:=0;
  v_current_costed bigint:=0;
  v_current_missing bigint:=0;
  v_previous_missing bigint:=0;
  v_can_cost boolean;
  metric jsonb;
begin
  r:=public.bi_get_executive_summary_before_recognized_cost(p_company_id,p_date_from,p_date_to,p_location_id,p_product_id,p_customer_id,p_supplier_id);
  v_currency:=r->>'currency_code';
  v_days:=p_date_to-p_date_from+1;
  v_previous_to:=p_date_from-1;
  v_previous_from:=v_previous_to-v_days+1;
  v_can_cost:=public.has_company_permission(p_company_id,'view_costs');
  if p_supplier_id is null and v_currency is not null and v_can_cost then
    select gross_margin,item_count,costed_item_count,missing_cost_item_count
    into v_current_margin,v_current_items,v_current_costed,v_current_missing
    from public.sale_margin_coverage(p_company_id,p_date_from,p_date_to,v_currency,p_location_id,p_product_id,p_customer_id);
    select gross_margin,missing_cost_item_count
    into v_previous_margin,v_previous_missing
    from public.sale_margin_coverage(p_company_id,v_previous_from,v_previous_to,v_currency,p_location_id,p_product_id,p_customer_id);
  end if;
  metric:=jsonb_build_object(
    'code','gross_margin',
    'value',case when p_supplier_id is null and v_currency is not null and v_can_cost and v_current_missing=0 then v_current_margin end,
    'previous_value',case when p_supplier_id is null and v_currency is not null and v_can_cost and v_previous_missing=0 then v_previous_margin end,
    'available',p_supplier_id is null and v_currency is not null and v_can_cost and v_current_missing=0 and v_previous_missing=0,
    'coverage',case when v_current_items=0 then null else round(100.0*v_current_costed/v_current_items,1) end,
    'reason',case when not v_can_cost then 'No tienes permiso para consultar costos y margen.' when v_currency is null then 'Falta una moneda base contable aprobada.'
      when p_supplier_id is not null then 'Proveedor no es una dimensión comprobada de margen.'
      when v_current_missing>0 or v_previous_missing>0 then 'El periodo actual o comparable contiene partidas sin costo reconocido.' end
  );
  return jsonb_set(r,'{metrics}',(r->'metrics')||jsonb_build_array(metric));
end;
$$;
revoke all on function public.bi_get_executive_summary(uuid,date,date,uuid,uuid,uuid,uuid) from public,anon;
grant execute on function public.bi_get_executive_summary(uuid,date,date,uuid,uuid,uuid,uuid) to authenticated;

-- La gráfica ejecutiva conserva el motor existente y sustituye únicamente la
-- serie de margen con agregados de snapshots.
alter function public.bi_get_executive_charts(uuid,date,date,uuid,uuid,uuid,uuid)
  rename to bi_get_executive_charts_before_recognized_cost;
revoke all on function public.bi_get_executive_charts_before_recognized_cost(uuid,date,date,uuid,uuid,uuid,uuid) from public,anon,authenticated;
create or replace function public.bi_get_executive_charts(
  p_company_id uuid,p_date_from date,p_date_to date,p_location_id uuid default null,p_product_id uuid default null,p_customer_id uuid default null,p_supplier_id uuid default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  r jsonb;
  v_currency text;
  v_days integer;
  v_previous_from date;
  v_previous_to date;
  v_current_margin numeric;
  v_previous_margin numeric;
  v_current_missing bigint:=0;
  v_previous_missing bigint:=0;
  v_current_items bigint:=0;
  v_current_costed bigint:=0;
  v_can_cost boolean;
  v_points jsonb:='[]'::jsonb;
  v_margin_chart jsonb;
  v_charts jsonb;
  v_comparisons jsonb;
begin
  r:=public.bi_get_executive_charts_before_recognized_cost(p_company_id,p_date_from,p_date_to,p_location_id,p_product_id,p_customer_id,p_supplier_id);
  v_currency:=r->>'currency_code';
  v_days:=p_date_to-p_date_from+1;
  v_previous_to:=p_date_from-1;
  v_previous_from:=v_previous_to-v_days+1;
  v_can_cost:=public.has_company_permission(p_company_id,'view_costs');

  if p_supplier_id is null and v_currency is not null and v_can_cost then
    select gross_margin,item_count,costed_item_count,missing_cost_item_count
    into v_current_margin,v_current_items,v_current_costed,v_current_missing
    from public.sale_margin_coverage(p_company_id,p_date_from,p_date_to,v_currency,p_location_id,p_product_id,p_customer_id);
    select gross_margin,missing_cost_item_count
    into v_previous_margin,v_previous_missing
    from public.sale_margin_coverage(p_company_id,v_previous_from,v_previous_to,v_currency,p_location_id,p_product_id,p_customer_id);

    if v_current_missing=0 and v_previous_missing=0 then
      with day_axis as (
        select i,p_date_from+i as current_date,v_previous_from+i as previous_date
        from generate_series(0,v_days-1) as g(i)
      ), facts as (
        select s.completed_at::date occurred_on,sum(si.taxable_amount-si.recognized_cost_amount) amount
        from public.sales s join public.sale_items si on si.sale_id=s.id
        where s.company_id=p_company_id and s.currency_code=v_currency
          and s.completed_at::date between v_previous_from and p_date_to
          and public.can_access_location(s.location_id)
          and (p_location_id is null or s.location_id=p_location_id)
          and (p_product_id is null or si.product_id=p_product_id)
          and (p_customer_id is null or s.customer_id=p_customer_id)
          and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id)
        group by s.completed_at::date
      )
      select coalesce(jsonb_agg(jsonb_build_object(
        'index',d.i,'date',d.current_date,'value',coalesce(c.amount,0),
        'previous_date',d.previous_date,'previous_value',coalesce(p.amount,0)
      ) order by d.i),'[]'::jsonb)
      into v_points
      from day_axis d
      left join facts c on c.occurred_on=d.current_date
      left join facts p on p.occurred_on=d.previous_date;
    end if;
  end if;

  v_margin_chart:=jsonb_build_object(
    'code','gross_margin','metric_code','gross_margin','kind','Devengado','visualization','line',
    'available',p_supplier_id is null and v_currency is not null and v_can_cost and v_current_missing=0 and v_previous_missing=0,
    'reason',case when not v_can_cost then 'No tienes permiso para consultar costos y margen.' when v_currency is null then 'Falta una moneda base contable aprobada.'
      when p_supplier_id is not null then 'Proveedor no es una dimensión comprobada de margen.'
      when v_current_missing>0 or v_previous_missing>0 then 'El periodo actual o comparable contiene partidas sin costo reconocido.' end,
    'coverage',case when v_current_items=0 then null else round(100.0*v_current_costed/v_current_items,1) end,
    'points',v_points
  );
  select coalesce(jsonb_agg(case when value->>'code'='gross_margin' then v_margin_chart else value end order by ordinality),'[]'::jsonb)
  into v_charts from jsonb_array_elements(r->'charts') with ordinality;
  v_comparisons:=coalesce(r->'comparisons','{}'::jsonb)||jsonb_build_object('gross_margin',jsonb_build_object(
    'value',case when v_current_missing=0 then v_current_margin end,
    'previous_value',case when v_previous_missing=0 then v_previous_margin end,
    'available',p_supplier_id is null and v_currency is not null and v_can_cost and v_current_missing=0 and v_previous_missing=0,
    'coverage',case when v_current_items=0 then null else round(100.0*v_current_costed/v_current_items,1) end,
    'reason',v_margin_chart->>'reason'
  ));
  r:=jsonb_set(r,'{charts}',v_charts);
  return jsonb_set(r,'{comparisons}',v_comparisons);
end;
$$;
revoke all on function public.bi_get_executive_charts(uuid,date,date,uuid,uuid,uuid,uuid) from public,anon;
grant execute on function public.bi_get_executive_charts(uuid,date,date,uuid,uuid,uuid,uuid) to authenticated;

create or replace function public.bi_gross_margin_explorer_query(
  p_company_id uuid,p_dimension text,p_visualization text,p_date_from date,p_date_to date,
  p_location_id uuid default null,p_product_id uuid default null,p_customer_id uuid default null,p_supplier_id uuid default null,
  p_page integer default 1,p_page_size integer default 25
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_currency text;
  v_days integer;
  v_previous_from date;
  v_previous_to date;
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);
  v_total bigint;
  v_items jsonb;
  v_chart jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_bi') then raise exception 'No autorizado para consultar BI.'; end if;
  if not public.has_company_permission(p_company_id,'view_costs') then raise exception 'No tienes permiso para consultar costos y margen.'; end if;
  if p_date_from is null or p_date_to is null or p_date_to<p_date_from or p_date_to-p_date_from+1>366 then raise exception 'Periodo de BI inválido.'; end if;
  if p_dimension not in('period','location','product','category') then raise exception 'La dimensión no es válida para Margen bruto.'; end if;
  if p_visualization not in('line','bar','area','scatter') then raise exception 'Visualización no disponible.'; end if;
  if p_visualization in('line','area') and p_dimension<>'period' then raise exception 'Línea y área requieren la dimensión periodo.'; end if;
  if p_visualization='scatter' then raise exception 'Dispersión requiere dos métricas compatibles.'; end if;
  if p_supplier_id is not null then raise exception 'Proveedor no es una dimensión comprobada de margen.'; end if;
  if p_location_id is not null and not exists(select 1 from public.locations l where l.id=p_location_id and l.company_id=p_company_id and public.can_access_location(l.id)) then raise exception 'Ubicación no disponible.'; end if;
  if p_product_id is not null and not exists(select 1 from public.products p where p.id=p_product_id and p.company_id=p_company_id) then raise exception 'Producto no disponible.'; end if;
  if p_customer_id is not null and not exists(select 1 from public.customers c where c.id=p_customer_id and c.company_id=p_company_id) then raise exception 'Cliente no disponible.'; end if;
  select base_currency into v_currency from public.accounting_config_versions where company_id=p_company_id and status='approved';
  if v_currency is null then raise exception 'Falta una moneda base contable aprobada.'; end if;
  v_days:=p_date_to-p_date_from+1;
  v_previous_to:=p_date_from-1;
  v_previous_from:=v_previous_to-v_days+1;

  drop table if exists pg_temp.bi_gross_margin_result;
  create temporary table bi_gross_margin_result(
    metric_code text not null default 'gross_margin',group_key text not null,group_label text not null,
    current_value numeric,previous_value numeric,available boolean not null,reason text,
    primary key(metric_code,group_key)
  ) on commit drop;

  insert into bi_gross_margin_result(group_key,group_label,current_value,previous_value,available,reason)
  select
    case p_dimension when 'period' then to_char(case when s.completed_at::date<p_date_from then s.completed_at::date+v_days else s.completed_at::date end,'YYYY-MM-DD')
      when 'location' then s.location_id::text when 'product' then si.product_id::text else coalesce(p.category_id::text,'uncategorized') end,
    case p_dimension when 'period' then to_char(case when s.completed_at::date<p_date_from then s.completed_at::date+v_days else s.completed_at::date end,'DD Mon')
      when 'location' then l.name when 'product' then p.name else coalesce(pc.name,'Sin categoría') end,
    case when count(*) filter(where s.completed_at::date between p_date_from and p_date_to and si.recognized_cost_amount is null)=0
      then coalesce(sum(si.taxable_amount-si.recognized_cost_amount) filter(where s.completed_at::date between p_date_from and p_date_to),0) end,
    case when count(*) filter(where s.completed_at::date between v_previous_from and v_previous_to and si.recognized_cost_amount is null)=0
      then coalesce(sum(si.taxable_amount-si.recognized_cost_amount) filter(where s.completed_at::date between v_previous_from and v_previous_to),0) end,
    count(*) filter(where si.recognized_cost_amount is null)=0,
    case when count(*) filter(where si.recognized_cost_amount is null)>0 then
      format('Hay %s partidas sin costo reconocido en este agregado.',count(*) filter(where si.recognized_cost_amount is null)) end
  from public.sales s
  join public.sale_items si on si.sale_id=s.id
  join public.products p on p.id=si.product_id
  join public.locations l on l.id=s.location_id
  left join public.product_categories pc on pc.id=p.category_id
  where s.company_id=p_company_id and s.currency_code=v_currency
    and s.completed_at::date between v_previous_from and p_date_to
    and public.can_access_location(s.location_id)
    and (p_location_id is null or s.location_id=p_location_id)
    and (p_product_id is null or si.product_id=p_product_id)
    and (p_customer_id is null or s.customer_id=p_customer_id)
    and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id)
  group by 1,2;

  select count(*) into v_total from bi_gross_margin_result;
  select coalesce(jsonb_agg(to_jsonb(x) order by group_label,metric_code),'[]'::jsonb) into v_items
  from (select * from bi_gross_margin_result order by group_label,metric_code limit v_size offset(v_page-1)*v_size)x;
  select coalesce(jsonb_agg(to_jsonb(x) order by group_key,metric_code),'[]'::jsonb) into v_chart
  from (select * from bi_gross_margin_result order by group_key,metric_code limit 120)x;
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)
  values(p_company_id,auth.uid(),'bi.explorer_queried','bi_query',jsonb_build_object('metric_codes',array['gross_margin'],'dimension',p_dimension,'page',v_page,'page_size',v_size));
  return jsonb_build_object(
    'query',jsonb_build_object('metric_codes',jsonb_build_array('gross_margin'),'dimension',p_dimension,'visualization',p_visualization),
    'period',jsonb_build_object('from',p_date_from,'to',p_date_to,'previous_from',v_previous_from,'previous_to',v_previous_to),
    'currency_code',v_currency,'updated_at',now(),'chart',v_chart,'items',v_items,
    'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total),
    'trace',jsonb_build_object('query','bi_gross_margin_explorer_query','company_id',p_company_id)
  );
end;
$$;
revoke all on function public.bi_gross_margin_explorer_query(uuid,text,text,date,date,uuid,uuid,uuid,uuid,integer,integer) from public,anon,authenticated;

-- El explorador existente conserva sus combinaciones; Margen se consulta por
-- separado mientras se exige cobertura completa por cada agregado.
alter function public.bi_explorer_query(uuid,text[],text,text,date,date,uuid,uuid,uuid,uuid,boolean,integer,integer)
  rename to bi_explorer_query_before_recognized_cost;
revoke all on function public.bi_explorer_query_before_recognized_cost(uuid,text[],text,text,date,date,uuid,uuid,uuid,uuid,boolean,integer,integer) from public,anon,authenticated;
create or replace function public.bi_explorer_query(
  p_company_id uuid,p_metric_codes text[],p_dimension text,p_visualization text,p_date_from date,p_date_to date,
  p_location_id uuid default null,p_product_id uuid default null,p_customer_id uuid default null,p_supplier_id uuid default null,
  p_compare_previous boolean default true,p_page integer default 1,p_page_size integer default 25
) returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if 'gross_margin'=any(p_metric_codes) then
    if cardinality(p_metric_codes)<>1 then raise exception 'Margen bruto se consulta individualmente para conservar su cobertura verificable.'; end if;
    return public.bi_gross_margin_explorer_query(p_company_id,p_dimension,p_visualization,p_date_from,p_date_to,p_location_id,p_product_id,p_customer_id,p_supplier_id,p_page,p_page_size);
  end if;
  return public.bi_explorer_query_before_recognized_cost(p_company_id,p_metric_codes,p_dimension,p_visualization,p_date_from,p_date_to,
    p_location_id,p_product_id,p_customer_id,p_supplier_id,p_compare_previous,p_page,p_page_size);
end;
$$;
revoke all on function public.bi_explorer_query(uuid,text[],text,text,date,date,uuid,uuid,uuid,uuid,boolean,integer,integer) from public,anon;
grant execute on function public.bi_explorer_query(uuid,text[],text,text,date,date,uuid,uuid,uuid,uuid,boolean,integer,integer) to authenticated;

create or replace function public.bi_gross_margin_drilldown(
  p_company_id uuid,p_date_from date,p_date_to date,p_location_id uuid default null,p_product_id uuid default null,
  p_customer_id uuid default null,p_supplier_id uuid default null,p_page integer default 1,p_page_size integer default 25
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_currency text;
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);
  v_total bigint;
  v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_bi') then raise exception 'No autorizado para consultar BI.'; end if;
  if not public.has_company_permission(p_company_id,'view_costs') then raise exception 'No tienes permiso para consultar costos y margen.'; end if;
  if p_date_from is null or p_date_to is null or p_date_to<p_date_from or p_date_to-p_date_from+1>366 then raise exception 'Periodo de BI inválido.'; end if;
  if p_supplier_id is not null then raise exception 'Proveedor no es una dimensión comprobada de margen.'; end if;
  select base_currency into v_currency from public.accounting_config_versions where company_id=p_company_id and status='approved';
  if v_currency is null then raise exception 'Falta una moneda base contable aprobada.'; end if;
  if exists(
    select 1 from public.sales s join public.sale_items si on si.sale_id=s.id
    where s.company_id=p_company_id and s.currency_code=v_currency and s.completed_at::date between p_date_from and p_date_to
      and public.can_access_location(s.location_id) and (p_location_id is null or s.location_id=p_location_id)
      and (p_product_id is null or si.product_id=p_product_id) and (p_customer_id is null or s.customer_id=p_customer_id)
      and si.recognized_cost_amount is null and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id)
  ) then raise exception 'El margen del alcance está incompleto: existen partidas sin costo reconocido.'; end if;
  with matching as materialized (
    select s.id,s.completed_at occurred_at,l.name location_name,
      string_agg(distinct p.name,', ' order by p.name) detail,sum(si.taxable_amount-si.recognized_cost_amount) amount
    from public.sales s join public.sale_items si on si.sale_id=s.id join public.products p on p.id=si.product_id join public.locations l on l.id=s.location_id
    where s.company_id=p_company_id and s.currency_code=v_currency and s.completed_at::date between p_date_from and p_date_to
      and public.can_access_location(s.location_id) and (p_location_id is null or s.location_id=p_location_id)
      and (p_product_id is null or si.product_id=p_product_id) and (p_customer_id is null or s.customer_id=p_customer_id)
      and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id)
    group by s.id,s.completed_at,l.name
  ), paged as (
    select * from matching order by occurred_at desc,id desc limit v_size offset(v_page-1)*v_size
  )
  select (select count(*) from matching),coalesce(jsonb_agg(to_jsonb(paged) order by occurred_at desc,id desc),'[]'::jsonb)
  into v_total,v_items from paged;
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)
  values(p_company_id,auth.uid(),'bi.gross_margin_drilldown_queried','bi_query',jsonb_build_object('date_from',p_date_from,'date_to',p_date_to,'page',v_page));
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',coalesce(v_total,0)),
    'source_path','/satrapy/ventas/historial','metric_code','gross_margin');
end;
$$;
revoke all on function public.bi_gross_margin_drilldown(uuid,date,date,uuid,uuid,uuid,uuid,integer,integer) from public,anon,authenticated;

alter function public.bi_get_drilldown_v2(uuid,text,date,date,uuid,uuid,uuid,uuid,date,integer,integer)
  rename to bi_get_drilldown_v2_before_recognized_cost;
revoke all on function public.bi_get_drilldown_v2_before_recognized_cost(uuid,text,date,date,uuid,uuid,uuid,uuid,date,integer,integer) from public,anon,authenticated;
create or replace function public.bi_get_drilldown_v2(
  p_company_id uuid,p_metric_code text,p_date_from date,p_date_to date,p_location_id uuid default null,p_product_id uuid default null,
  p_customer_id uuid default null,p_supplier_id uuid default null,p_as_of_date date default null,p_page integer default 1,p_page_size integer default 25
) returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if lower(trim(coalesce(p_metric_code,'')))='gross_margin' then
    return public.bi_gross_margin_drilldown(p_company_id,p_date_from,p_date_to,p_location_id,p_product_id,p_customer_id,p_supplier_id,p_page,p_page_size);
  end if;
  return public.bi_get_drilldown_v2_before_recognized_cost(p_company_id,p_metric_code,p_date_from,p_date_to,p_location_id,p_product_id,p_customer_id,p_supplier_id,p_as_of_date,p_page,p_page_size);
end;
$$;
revoke all on function public.bi_get_drilldown_v2(uuid,text,date,date,uuid,uuid,uuid,uuid,date,integer,integer) from public,anon;
grant execute on function public.bi_get_drilldown_v2(uuid,text,date,date,uuid,uuid,uuid,uuid,date,integer,integer) to authenticated;

alter function public.bi_get_explorer_drilldown(uuid,text,text,text,date,date,uuid,uuid,uuid,uuid,integer,integer)
  rename to bi_get_explorer_drilldown_before_recognized_cost;
revoke all on function public.bi_get_explorer_drilldown_before_recognized_cost(uuid,text,text,text,date,date,uuid,uuid,uuid,uuid,integer,integer) from public,anon,authenticated;
create or replace function public.bi_get_explorer_drilldown(
  p_company_id uuid,p_metric_code text,p_dimension text,p_group_key text,p_date_from date,p_date_to date,
  p_location_id uuid default null,p_product_id uuid default null,p_customer_id uuid default null,p_supplier_id uuid default null,
  p_page integer default 1,p_page_size integer default 25
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_code text:=lower(trim(coalesce(p_metric_code,'')));
  v_group uuid;
  v_currency text;
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);
  v_total bigint;
  v_items jsonb;
begin
  if v_code<>'gross_margin' then
    return public.bi_get_explorer_drilldown_before_recognized_cost(p_company_id,p_metric_code,p_dimension,p_group_key,p_date_from,p_date_to,p_location_id,p_product_id,p_customer_id,p_supplier_id,p_page,p_page_size);
  end if;
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_bi') then raise exception 'No autorizado para consultar BI.'; end if;
  if not public.has_company_permission(p_company_id,'view_costs') then raise exception 'No tienes permiso para consultar costos y margen.'; end if;
  if p_dimension not in('period','location','product','category') then raise exception 'Grupo de margen inválido.'; end if;
  if p_dimension='period' then
    p_date_from:=p_group_key::date;
    p_date_to:=p_group_key::date;
  elsif not (p_dimension='category' and p_group_key='uncategorized') then
    begin v_group:=p_group_key::uuid; exception when invalid_text_representation then raise exception 'Grupo de BI inválido.'; end;
  end if;
  if p_supplier_id is not null then raise exception 'Proveedor no es una dimensión comprobada de margen.'; end if;
  select base_currency into v_currency from public.accounting_config_versions where company_id=p_company_id and status='approved';
  if v_currency is null then raise exception 'Falta una moneda base contable aprobada.'; end if;
  if exists(
    select 1 from public.sales s join public.sale_items si on si.sale_id=s.id join public.products p on p.id=si.product_id
    where s.company_id=p_company_id and s.currency_code=v_currency and s.completed_at::date between p_date_from and p_date_to and public.can_access_location(s.location_id)
      and (case p_dimension when 'location' then s.location_id=v_group when 'product' then si.product_id=v_group when 'category' then (p.category_id is not distinct from v_group) else true end)
      and (p_location_id is null or s.location_id=p_location_id) and (p_product_id is null or si.product_id=p_product_id) and (p_customer_id is null or s.customer_id=p_customer_id)
      and si.recognized_cost_amount is null and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id)
  ) then raise exception 'El margen del agregado está incompleto: existen partidas sin costo reconocido.'; end if;
  with matching as materialized(
    select s.id,s.completed_at occurred_at,l.name location_name,string_agg(distinct p.name,', ' order by p.name) detail,
      sum(si.taxable_amount-si.recognized_cost_amount) amount
    from public.sales s join public.sale_items si on si.sale_id=s.id join public.products p on p.id=si.product_id join public.locations l on l.id=s.location_id
    where s.company_id=p_company_id and s.currency_code=v_currency and s.completed_at::date between p_date_from and p_date_to and public.can_access_location(s.location_id)
      and (case p_dimension when 'location' then s.location_id=v_group when 'product' then si.product_id=v_group when 'category' then (p.category_id is not distinct from v_group) else true end)
      and (p_location_id is null or s.location_id=p_location_id) and (p_product_id is null or si.product_id=p_product_id) and (p_customer_id is null or s.customer_id=p_customer_id)
      and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id)
    group by s.id,s.completed_at,l.name
  ),paged as(select * from matching order by occurred_at desc,id desc limit v_size offset(v_page-1)*v_size)
  select(select count(*)from matching),coalesce(jsonb_agg(to_jsonb(paged)order by occurred_at desc,id desc),'[]'::jsonb) into v_total,v_items from paged;
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)
  values(p_company_id,auth.uid(),'bi.explorer_drilldown_queried','bi_query',jsonb_build_object('metric_code',v_code,'dimension',p_dimension,'group_key',p_group_key,'page',v_page));
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',coalesce(v_total,0)),
    'source_path','/satrapy/ventas/historial','metric_code','gross_margin');
end;
$$;
revoke all on function public.bi_get_explorer_drilldown(uuid,text,text,text,date,date,uuid,uuid,uuid,uuid,integer,integer) from public,anon;
grant execute on function public.bi_get_explorer_drilldown(uuid,text,text,text,date,date,uuid,uuid,uuid,uuid,integer,integer) to authenticated;

notify pgrst,'reload schema';
