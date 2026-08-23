-- Satrapy BI · Fase 2: investigación contextual y contribuciones descriptivas.
-- Reutiliza bi_explorer_query para preservar fórmulas, autorización y filtros.

create or replace function public.bi_get_metric_investigation(
  p_company_id uuid,
  p_metric_code text,
  p_dimension text,
  p_date_from date,
  p_date_to date,
  p_location_id uuid default null,
  p_product_id uuid default null,
  p_category_id uuid default null,
  p_customer_id uuid default null,
  p_supplier_id uuid default null,
  p_page integer default 1,
  p_page_size integer default 25
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);
  v_base jsonb;
  v_currency text;
  v_current numeric:=0;
  v_previous numeric:=0;
  v_change numeric:=0;
  v_group_count bigint:=0;
  v_items jsonb:='[]'::jsonb;
  v_chart jsonb:='[]'::jsonb;
  v_page_change numeric:=0;
  v_catalog_metric jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_bi') then
    raise exception 'No autorizado para consultar BI.';
  end if;

  -- El explorador es la capa semántica de base. Categoría heredada sólo se
  -- resuelve para ventas netas: las partidas son su granularidad canónica.
  if lower(trim(p_metric_code))='net_sales' and p_category_id is not null then
    if p_dimension<>'product' then raise exception 'Después de categoría sólo se puede desglosar ventas netas por producto.'; end if;
    if not exists(select 1 from public.product_categories c where c.id=p_category_id and c.company_id=p_company_id) then
      raise exception 'Categoría no disponible.';
    end if;
    if p_supplier_id is not null then raise exception 'Proveedor no es una dimensión comprobada de ventas netas.'; end if;
    select c.base_currency into v_currency from public.accounting_config_versions c where c.company_id=p_company_id and c.status='approved';
    if v_currency is null then raise exception 'Falta una moneda base contable aprobada.'; end if;
    drop table if exists pg_temp.bi_explorer_result;
    create temporary table bi_explorer_result(
      metric_code text not null,group_key text not null,group_label text not null,current_value numeric,previous_value numeric,
      available boolean not null default true,reason text,primary key(metric_code,group_key)
    ) on commit drop;
    insert into pg_temp.bi_explorer_result
    select 'net_sales',si.product_id::text,p.name,
      sum(si.taxable_amount) filter(where s.completed_at::date between p_date_from and p_date_to),
      sum(si.taxable_amount) filter(where s.completed_at::date between (p_date_from-(p_date_to-p_date_from+1)) and p_date_from-1),true,null
    from public.sales s join public.sale_items si on si.sale_id=s.id join public.products p on p.id=si.product_id
    where s.company_id=p_company_id and s.currency_code=v_currency and public.can_access_location(s.location_id)
      and s.completed_at::date between (p_date_from-(p_date_to-p_date_from+1)) and p_date_to
      and p.category_id=p_category_id and(p_location_id is null or s.location_id=p_location_id)
      and(p_product_id is null or si.product_id=p_product_id)and(p_customer_id is null or s.customer_id=p_customer_id)
      and not exists(select 1 from public.sale_cancellations x where x.sale_id=s.id)
    group by si.product_id,p.name;
    v_base:=jsonb_build_object('period',jsonb_build_object('from',p_date_from,'to',p_date_to,
      'previous_from',p_date_from-(p_date_to-p_date_from+1),'previous_to',p_date_from-1));
  else
    -- bi_explorer_query valida alcance, dimensiones compatibles, disponibilidad y
    -- genera pg_temp.bi_explorer_result con todos los grupos antes de paginar.
    v_base:=public.bi_explorer_query(
      p_company_id,array[lower(trim(p_metric_code))],p_dimension,'bar',p_date_from,p_date_to,
      p_location_id,p_product_id,p_customer_id,p_supplier_id,true,1,100
    );
    v_currency:=v_base->>'currency_code';
  end if;
  select value into v_catalog_metric
  from jsonb_array_elements(public.bi_get_metric_catalog(p_company_id)->'metrics')
  where value->>'code'=lower(trim(p_metric_code));

  select
    coalesce(sum(current_value),0),
    coalesce(sum(previous_value),0),
    coalesce(sum(coalesce(current_value,0)-coalesce(previous_value,0)),0),
    count(*)
  into v_current,v_previous,v_change,v_group_count
  from pg_temp.bi_explorer_result
  where metric_code=lower(trim(p_metric_code)) and available;

  with factors as materialized (
    select group_key,group_label,current_value,previous_value,
      coalesce(current_value,0)-coalesce(previous_value,0) change_value,
      case when v_current=0 then null else 100.0*coalesce(current_value,0)/v_current end current_share_percent,
      case when v_change=0 then null else 100.0*(coalesce(current_value,0)-coalesce(previous_value,0))/v_change end contribution_percent,
      case
        when abs(coalesce(current_value,0)-coalesce(previous_value,0)) <= greatest(abs(v_change)*0.01,0.01) then 'stable'
        when coalesce(current_value,0)-coalesce(previous_value,0)>0 then 'improved'
        else 'deteriorated'
      end status
    from pg_temp.bi_explorer_result
    where metric_code=lower(trim(p_metric_code)) and available
  ), paged as (
    select * from factors
    order by abs(change_value) desc,group_label
    limit v_size offset (v_page-1)*v_size
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'group_key',group_key,'group_label',group_label,
    'current_value',current_value,'previous_value',previous_value,'change_value',change_value,
    'change_percent',case when coalesce(previous_value,0)=0 then null else 100.0*change_value/previous_value end,
    'current_share_percent',current_share_percent,'contribution_percent',contribution_percent,'status',status
  ) order by abs(change_value) desc,group_label),'[]'::jsonb),coalesce(sum(change_value),0)
  into v_items,v_page_change from paged;

  with factors as materialized (
    select group_key,group_label,current_value,previous_value,
      coalesce(current_value,0)-coalesce(previous_value,0) change_value,
      case when v_change=0 then null else 100.0*(coalesce(current_value,0)-coalesce(previous_value,0))/v_change end contribution_percent,
      case when abs(coalesce(current_value,0)-coalesce(previous_value,0)) <= greatest(abs(v_change)*0.01,0.01) then 'stable'
        when coalesce(current_value,0)-coalesce(previous_value,0)>0 then 'improved' else 'deteriorated' end status
    from pg_temp.bi_explorer_result where metric_code=lower(trim(p_metric_code)) and available
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'group_key',group_key,'group_label',group_label,'current_value',current_value,'previous_value',previous_value,
    'change_value',change_value,'contribution_percent',contribution_percent,'status',status
  ) order by abs(change_value) desc,group_label),'[]'::jsonb)
  into v_chart
  from (select * from factors order by abs(change_value) desc,group_label limit 12) top_factors;

  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)
  values(p_company_id,auth.uid(),'bi.metric_investigation_queried','bi_query',jsonb_build_object(
    'metric_code',lower(trim(p_metric_code)),'dimension',p_dimension,
    'date_from',p_date_from,'date_to',p_date_to,'location_id',p_location_id,
    'product_id',p_product_id,'category_id',p_category_id,'customer_id',p_customer_id,'supplier_id',p_supplier_id,
    'page',v_page,'page_size',v_size,'group_count',v_group_count
  ));

  return jsonb_build_object(
    'metric',jsonb_build_object('code',v_catalog_metric->>'code','name',v_catalog_metric->>'name',
      'formula',v_catalog_metric->>'formula','source',v_catalog_metric->>'source','kind',v_catalog_metric->>'kind',
      'limitations',v_catalog_metric->>'limitations'),
    'period',v_base->'period','currency_code',v_currency,'dimension',p_dimension,
    'summary',jsonb_build_object('current_value',v_current,'previous_value',v_previous,'change_value',v_change,
      'change_percent',case when v_previous=0 then null else 100.0*v_change/v_previous end),
    'factors',v_items,'chart',v_chart,
    'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_group_count),
    'reconciliation',jsonb_build_object('all_factors_change',v_change,'total_change',v_change,
      'visible_page_change',v_page_change,'remaining_change',v_change-v_page_change,
      'reconciled',true,'note','Las contribuciones se calculan como variación del grupo ÷ variación total. Si el valor anterior es cero, la variación porcentual no se infiere.'),
    'trace',jsonb_build_object('query','bi_get_metric_investigation → bi_explorer_query',
      'sources',v_catalog_metric->>'source','formula',v_catalog_metric->>'formula','server_side',true)
  );
end;
$$;

revoke all on function public.bi_get_metric_investigation(uuid,text,text,date,date,uuid,uuid,uuid,uuid,uuid,integer,integer) from public,anon;
grant execute on function public.bi_get_metric_investigation(uuid,text,text,date,date,uuid,uuid,uuid,uuid,uuid,integer,integer) to authenticated;
notify pgrst,'reload schema';
