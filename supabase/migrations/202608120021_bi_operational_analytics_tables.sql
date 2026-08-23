-- Satrapy BI · Fase 3: tablas analíticas operativas.
-- Reutiliza bi_explorer_query como capa semántica y pagina únicamente agregados.

create or replace function public.bi_get_operational_table(
  p_company_id uuid,
  p_metric_code text,
  p_dimension text,
  p_date_from date,
  p_date_to date,
  p_location_id uuid default null,
  p_product_id uuid default null,
  p_customer_id uuid default null,
  p_supplier_id uuid default null,
  p_search text default null,
  p_sort_by text default 'negative_impact',
  p_sort_direction text default 'desc',
  p_page integer default 1,
  p_page_size integer default 25,
  p_comparison_mode text default 'previous_period'
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_metric_code text:=lower(trim(coalesce(p_metric_code,'')));
  v_dimension text:=lower(trim(coalesce(p_dimension,'')));
  v_search text:=nullif(trim(coalesce(p_search,'')),'');
  v_sort text:=lower(trim(coalesce(p_sort_by,'negative_impact')));
  v_direction text:=lower(trim(coalesce(p_sort_direction,'desc')));
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);
  v_catalog jsonb;
  v_metric jsonb;
  v_base jsonb;
  v_items jsonb:='[]'::jsonb;
  v_total bigint:=0;
  v_scope_total bigint:=0;
  v_partial_count bigint:=0;
  v_current_total numeric:=0;
  v_previous_total numeric:=0;
  v_change_total numeric:=0;
  v_comparison_mode text:=lower(trim(coalesce(p_comparison_mode,'previous_period')));
  v_comparison_from date;
  v_comparison_to date;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_bi') then
    raise exception 'No autorizado para consultar BI.';
  end if;
  if v_dimension not in('location','category','product') then
    raise exception 'La tabla operativa sólo admite sucursal, categoría o producto.';
  end if;
  if v_metric_code not in('net_sales','gross_margin','tickets') then
    raise exception 'La métrica no tiene una prioridad operativa comprobada para estas tablas.';
  end if;
  if v_metric_code='tickets' and v_dimension<>'location' then
    raise exception 'Tickets sólo es aditivo por sucursal en las tablas operativas.';
  end if;
  if v_sort not in('negative_impact','positive_contribution','current_value','previous_value','change_value','change_percent','share_percent','contribution_percent','entity') then
    raise exception 'Columna de ordenamiento no permitida.';
  end if;
  if v_direction not in('asc','desc') then raise exception 'Dirección de ordenamiento inválida.'; end if;
  if length(coalesce(v_search,''))>120 then raise exception 'La búsqueda admite hasta 120 caracteres.'; end if;
  if v_comparison_mode not in('previous_period','previous_year') then raise exception 'Comparación no permitida.'; end if;
  if v_comparison_mode='previous_year' then
    v_comparison_from:=(p_date_from-interval '1 year')::date;
    v_comparison_to:=(p_date_to-interval '1 year')::date;
  else
    v_comparison_to:=p_date_from-1;
    v_comparison_from:=v_comparison_to-(p_date_to-p_date_from);
  end if;

  v_catalog:=public.bi_get_metric_catalog(p_company_id);
  select value into v_metric
  from jsonb_array_elements(v_catalog->'metrics')
  where value->>'code'=v_metric_code;
  if v_metric is null or not coalesce((v_metric->>'available')::boolean,false) then
    raise exception '%',coalesce(v_metric->>'unavailable_reason','Métrica no disponible.');
  end if;
  if not (coalesce(v_metric->'dimensions','[]'::jsonb) ? v_dimension) then
    raise exception 'La dimensión no es compatible con la métrica seleccionada.';
  end if;

  -- El RPC del Explorador valida periodo, moneda, alcance de ubicación, filtros,
  -- permisos de costo y fórmulas. También materializa todos los grupos antes de
  -- aplicar su propia página; esta función sólo vuelve a paginar los agregados.
  v_base:=public.bi_explorer_query(
    p_company_id,array[v_metric_code],v_dimension,'bar',p_date_from,p_date_to,
    p_location_id,p_product_id,p_customer_id,p_supplier_id,true,1,1
  );

  drop table if exists pg_temp.bi_operational_source;
  create temporary table bi_operational_source(
    group_key text not null,
    group_label text not null,
    current_value numeric,
    previous_value numeric,
    available boolean not null,
    reason text
  ) on commit drop;

  if v_metric_code='gross_margin' then
    insert into pg_temp.bi_operational_source
    select group_key,group_label,current_value,previous_value,available,reason
    from pg_temp.bi_gross_margin_result
    where metric_code=v_metric_code;
  else
    insert into pg_temp.bi_operational_source
    select group_key,group_label,current_value,previous_value,available,reason
    from pg_temp.bi_explorer_result
    where metric_code=v_metric_code;
  end if;

  if v_comparison_mode='previous_year' then
    perform public.bi_explorer_query(
      p_company_id,array[v_metric_code],v_dimension,'bar',v_comparison_from,v_comparison_to,
      p_location_id,p_product_id,p_customer_id,p_supplier_id,false,1,1
    );
    if v_metric_code='gross_margin' then
      update pg_temp.bi_operational_source source
      set previous_value=comparison.current_value,
          available=source.available and comparison.available,
          reason=coalesce(source.reason,comparison.reason)
      from pg_temp.bi_gross_margin_result comparison
      where comparison.metric_code=v_metric_code and comparison.group_key=source.group_key;
    else
      update pg_temp.bi_operational_source source
      set previous_value=comparison.current_value,
          available=source.available and comparison.available,
          reason=coalesce(source.reason,comparison.reason)
      from pg_temp.bi_explorer_result comparison
      where comparison.metric_code=v_metric_code and comparison.group_key=source.group_key;
    end if;
  end if;

  select count(*),count(*) filter(where not available),
    coalesce(sum(coalesce(current_value,0)) filter(where available),0),
    coalesce(sum(coalesce(previous_value,0)) filter(where available),0)
  into v_scope_total,v_partial_count,v_current_total,v_previous_total
  from pg_temp.bi_operational_source;
  v_change_total:=v_current_total-v_previous_total;

  with factors as materialized (
    select source.group_key,source.group_label,source.current_value,source.previous_value,source.available,source.reason,
      case when source.available then coalesce(source.current_value,0)-coalesce(source.previous_value,0) end change_value,
      case when source.available and coalesce(source.previous_value,0)<>0
        then 100.0*(coalesce(source.current_value,0)-coalesce(source.previous_value,0))/abs(source.previous_value) end change_percent,
      case when source.available and v_current_total<>0 then 100.0*coalesce(source.current_value,0)/v_current_total end share_percent,
      case when source.available and v_change_total<>0 then 100.0*(coalesce(source.current_value,0)-coalesce(source.previous_value,0))/v_change_total end contribution_percent,
      case
        when not source.available then 'partial'
        when abs(coalesce(source.current_value,0)-coalesce(source.previous_value,0))<=greatest(abs(v_change_total)*0.01,0.01) then 'neutral'
        when coalesce(source.current_value,0)-coalesce(source.previous_value,0)>0 then 'improved'
        else 'deteriorated'
      end status,
      case
        when not source.available then 'partial'
        when source.previous_value is null or source.previous_value=0 then 'previous_zero'
        else 'comparable'
      end comparison_state
    from pg_temp.bi_operational_source source
  ), filtered as materialized (
    select * from factors
    where v_search is null or lower(group_label) like '%'||lower(v_search)||'%'
  ), ranked as materialized (
    select row_number() over(order by
      case when v_sort='negative_impact' then change_value end asc nulls last,
      case when v_sort='positive_contribution' then contribution_percent end desc nulls last,
      case when v_sort='current_value' and v_direction='asc' then current_value end asc nulls last,
      case when v_sort='current_value' and v_direction='desc' then current_value end desc nulls last,
      case when v_sort='previous_value' and v_direction='asc' then previous_value end asc nulls last,
      case when v_sort='previous_value' and v_direction='desc' then previous_value end desc nulls last,
      case when v_sort='change_value' and v_direction='asc' then change_value end asc nulls last,
      case when v_sort='change_value' and v_direction='desc' then change_value end desc nulls last,
      case when v_sort='change_percent' and v_direction='asc' then change_percent end asc nulls last,
      case when v_sort='change_percent' and v_direction='desc' then change_percent end desc nulls last,
      case when v_sort='share_percent' and v_direction='asc' then share_percent end asc nulls last,
      case when v_sort='share_percent' and v_direction='desc' then share_percent end desc nulls last,
      case when v_sort='contribution_percent' and v_direction='asc' then contribution_percent end asc nulls last,
      case when v_sort='contribution_percent' and v_direction='desc' then contribution_percent end desc nulls last,
      case when v_sort='entity' and v_direction='asc' then lower(group_label) end asc nulls last,
      case when v_sort='entity' and v_direction='desc' then lower(group_label) end desc nulls last,
      lower(group_label),group_key
    )::integer ranking,*
    from filtered
  ), paged as (
    select * from ranked order by ranking
    limit v_size offset (v_page-1)*v_size
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'group_key',group_key,'group_label',group_label,'ranking',ranking,
    'current_value',current_value,'previous_value',previous_value,
    'change_value',change_value,'change_percent',change_percent,
    'share_percent',share_percent,'contribution_percent',contribution_percent,
    'status',status,'comparison_state',comparison_state,'available',available,'reason',reason
  ) order by ranking),'[]'::jsonb),(select count(*) from filtered)
  into v_items,v_total
  from paged;

  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)
  values(p_company_id,auth.uid(),'bi.operational_table_queried','bi_query',jsonb_build_object(
    'metric_code',v_metric_code,'dimension',v_dimension,'date_from',p_date_from,'date_to',p_date_to,
    'location_id',p_location_id,'product_id',p_product_id,'customer_id',p_customer_id,'supplier_id',p_supplier_id,
    'search',v_search,'sort_by',v_sort,'sort_direction',v_direction,'page',v_page,'page_size',v_size,
    'filtered_count',v_total,'scope_count',v_scope_total,'partial_count',v_partial_count
  ));

  return jsonb_build_object(
    'metric',jsonb_build_object('code',v_metric->>'code','name',v_metric->>'name','unit',v_metric->>'unit',
      'formula',v_metric->>'formula','source',v_metric->>'source','limitations',v_metric->>'limitations'),
    'dimension',v_dimension,'period',jsonb_build_object('from',p_date_from,'to',p_date_to,
      'previous_from',v_comparison_from,'previous_to',v_comparison_to,'days',p_date_to-p_date_from+1,
      'comparison_mode',v_comparison_mode),'currency_code',v_base->>'currency_code','updated_at',now(),
    'items',v_items,
    'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total),
    'scope',jsonb_build_object('total_groups',v_scope_total,'partial_groups',v_partial_count,
      'current_total',v_current_total,'previous_total',v_previous_total,'change_total',v_change_total),
    'query',jsonb_build_object('search',v_search,'sort_by',v_sort,'sort_direction',v_direction),
    'partial',v_partial_count>0,
    'trace',jsonb_build_object('query','bi_get_operational_table → bi_explorer_query','server_side',true,
      'source',v_metric->>'source','formula',v_metric->>'formula')
  );
end;
$$;

alter table public.bi_export_jobs drop constraint if exists bi_export_jobs_target_type_check;
alter table public.bi_export_jobs add constraint bi_export_jobs_target_type_check
  check(target_type in('view','widget','dashboard','operational_table'));

create or replace function public.bi_prepare_operational_export(
  p_company_id uuid,
  p_format text,
  p_definition jsonb
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_preview jsonb;
  v_definition jsonb;
  v_configs jsonb;
  v_target_id uuid:=gen_random_uuid();
  v_job public.bi_export_jobs%rowtype;
  v_dimension_label text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_bi')
    or not public.has_company_permission(p_company_id,'export_bi_reports') then
    raise exception 'No autorizado para exportar BI.';
  end if;
  if p_format not in('csv','xlsx') then raise exception 'Formato no disponible para la tabla operativa.'; end if;
  if jsonb_typeof(coalesce(p_definition,'null'::jsonb))<>'object' then raise exception 'Definición de exportación inválida.'; end if;

  v_preview:=public.bi_get_operational_table(
    p_company_id,p_definition->>'metric_code',p_definition->>'dimension',
    (p_definition->>'date_from')::date,(p_definition->>'date_to')::date,
    nullif(p_definition->>'location_id','')::uuid,nullif(p_definition->>'product_id','')::uuid,
    nullif(p_definition->>'customer_id','')::uuid,nullif(p_definition->>'supplier_id','')::uuid,
    nullif(p_definition->>'search',''),coalesce(p_definition->>'sort_by','negative_impact'),
    coalesce(p_definition->>'sort_direction','desc'),1,1,
    coalesce(p_definition->>'comparison_mode','previous_period')
  );
  v_definition:=jsonb_strip_nulls(jsonb_build_object(
    'kind','operational_table','metric_code',p_definition->>'metric_code','dimension',p_definition->>'dimension',
    'date_from',p_definition->>'date_from','date_to',p_definition->>'date_to',
    'location_id',nullif(p_definition->>'location_id',''),'product_id',nullif(p_definition->>'product_id',''),
    'customer_id',nullif(p_definition->>'customer_id',''),'supplier_id',nullif(p_definition->>'supplier_id',''),
    'search',nullif(p_definition->>'search',''),'sort_by',coalesce(p_definition->>'sort_by','negative_impact'),
    'sort_direction',coalesce(p_definition->>'sort_direction','desc'),
    'comparison_mode',coalesce(p_definition->>'comparison_mode','previous_period')
  ));
  v_dimension_label:=case p_definition->>'dimension' when 'location' then 'Sucursales' when 'category' then 'Categorías' else 'Productos' end;
  v_configs:=jsonb_build_array(jsonb_build_object(
    'title',v_dimension_label||' · '||(v_preview->'metric'->>'name'),
    'target_id',v_target_id,'widget_type','table','definition',v_definition
  ));

  insert into public.bi_export_jobs(company_id,target_type,target_id,format,query_snapshot)
  values(p_company_id,'operational_table',v_target_id,p_format,jsonb_build_object('configs',v_configs))
  returning * into v_job;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'bi.operational_export_requested','bi_export_job',v_job.id,
    jsonb_build_object('format',p_format,'definition',v_definition,'estimated_rows',v_preview->'pagination'->>'total'));
  return jsonb_build_object('job_id',v_job.id,'configs',v_configs);
end;
$$;

revoke all on function public.bi_get_operational_table(uuid,text,text,date,date,uuid,uuid,uuid,uuid,text,text,text,integer,integer,text) from public,anon;
revoke all on function public.bi_prepare_operational_export(uuid,text,jsonb) from public,anon;
grant execute on function public.bi_get_operational_table(uuid,text,text,date,date,uuid,uuid,uuid,uuid,text,text,text,integer,integer,text) to authenticated;
grant execute on function public.bi_prepare_operational_export(uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';
