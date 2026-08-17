-- Satrapy BI · Fase 5 final: contrato versionado y consulta estructurada.
-- Amplía el catálogo existente; no replica fórmulas ni hechos analíticos.

alter function public.bi_get_metric_catalog(uuid) rename to bi_get_metric_catalog_before_contract_v1;
revoke all on function public.bi_get_metric_catalog_before_contract_v1(uuid) from public,anon,authenticated;

alter table public.bi_alert_rules add column if not exists metric_contract_version text not null default '1.0.0';
alter table public.bi_alerts add column if not exists metric_contract_version text not null default '1.0.0';

create or replace function public.bi_get_metric_catalog(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare c jsonb; metrics jsonb;
begin
  c:=public.bi_get_metric_catalog_before_contract_v1(p_company_id);
  select coalesce(jsonb_agg(
    metric || jsonb_build_object(
      'metric_id',metric->>'code',
      'description',coalesce(metric->>'limitations',metric->>'formula'),
      'contract_version','1.0.0',
      'responsible_rpc','bi_explorer_query',
      'format',case metric->>'unit' when'currency'then'currency_2' when'percent'then'percent_2' when'count'then'integer' else'decimal_2'end,
      'favorable_direction',case when metric->>'code' in('payables','overdue_receivables','supplier_payments')then'down' when metric->>'code' in('bank_reconciliation')then'completeness'else'up'end,
      'compatible_filters',coalesce(metric->'dimensions','[]'::jsonb)-'period',
      'time_granularities',jsonb_build_array('total'),
      'supported_comparisons',jsonb_build_array('none','previous_period'),
      'availability',jsonb_build_object('available',coalesce((metric->>'available')::boolean,false),'reason',metric->>'unavailable_reason'),
      'data_requirements',coalesce(metric->>'source','Fuente canónica no declarada'),
      'value_behavior',jsonb_build_object(
        'zero','Dato disponible cuyo agregado es cero.',
        'null','No se calculó un valor numérico; consulta availability y quality.',
        'partial','El valor sólo se publica cuando el RPC responsable puede identificar su cobertura.',
        'unavailable',coalesce(metric->>'unavailable_reason','La métrica no cumple sus requisitos de datos o permiso.')
      ),
      'trace',jsonb_build_object('catalog_rpc','bi_get_metric_catalog','query_rpc','bi_explorer_query','server_side',true),
      'updated_at',c->'updated_at',
      'examples',jsonb_build_array(jsonb_build_object('metric_id',metric->>'code','period',jsonb_build_object('from','2026-01-01','to','2026-01-31'),'comparison','previous_period','granularity','total','dimensions',jsonb_build_array((coalesce(metric->'dimensions','[]'::jsonb)->>0)),'filters',jsonb_build_object(),'page',1,'limit',25))
    ) order by metric->>'code'
  ),'[]'::jsonb) into metrics from jsonb_array_elements(c->'metrics') metric;
  return c || jsonb_build_object(
    'contract',jsonb_build_object('name','satrapy.bi.metric','version','1.0.0','read_only',true,'arbitrary_sql',false,'updated_at',c->'updated_at'),
    'query_limits',jsonb_build_object('maximum_period_days',366,'maximum_page_size',100,'maximum_dimensions',1,'stable_order',jsonb_build_array('group_label','metric_code')),
    'metrics',metrics
  );
end$$;

create or replace function public.bi_query_metric(p_company_id uuid,p_request jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare started timestamptz:=clock_timestamp();catalog jsonb;metric jsonb;result jsonb;metric_id text;authorized boolean:=false;
  date_from date;date_to date;comparison text;granularity text;dimension text;filters jsonb;
  page_no integer;page_size integer;rows_returned integer;quality text;next_dimension text;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'view_bi')then raise exception'Consulta BI no disponible.';end if;authorized:=true;
  if p_request is null or jsonb_typeof(p_request)<>'object'then raise exception'Solicitud estructurada inválida.';end if;
  if exists(select 1 from jsonb_object_keys(p_request) key where key not in('metric_id','period','comparison','granularity','dimensions','filters','order','page','limit'))then raise exception'La solicitud contiene campos no permitidos.';end if;
  metric_id:=nullif(trim(p_request->>'metric_id'),'');date_from:=(p_request#>>'{period,from}')::date;date_to:=(p_request#>>'{period,to}')::date;
  comparison:=coalesce(p_request->>'comparison','previous_period');granularity:=coalesce(p_request->>'granularity','total');
  dimension:=coalesce(p_request#>>'{dimensions,0}','period');filters:=coalesce(p_request->'filters','{}'::jsonb);
  page_no:=greatest(coalesce((p_request->>'page')::integer,1),1);page_size:=least(greatest(coalesce((p_request->>'limit')::integer,25),1),100);
  if metric_id is null or date_from is null or date_to is null or date_from>date_to or date_to-date_from>365 then raise exception'Métrica o periodo inválido; el máximo es 366 días.';end if;
  if comparison not in('none','previous_period')then raise exception'Comparación no compatible.';end if;
  if granularity<>'total'then raise exception'Granularidad no compatible.';end if;
  if jsonb_array_length(coalesce(p_request->'dimensions','[]'::jsonb))>1 then raise exception'Sólo se admite una dimensión por consulta.';end if;
  if jsonb_typeof(filters)<>'object'or exists(select 1 from jsonb_object_keys(filters) key where key not in('location','product','customer','supplier'))then raise exception'Filtro no permitido.';end if;
  if coalesce(p_request->>'order','group_label_asc')not in('group_label_asc')then raise exception'Ordenamiento no permitido.';end if;
  catalog:=public.bi_get_metric_catalog(p_company_id);
  select value into metric from jsonb_array_elements(catalog->'metrics')where value->>'metric_id'=metric_id;
  if metric is null then raise exception'Métrica no disponible.';end if;
  if not coalesce((metric#>>'{availability,available}')::boolean,false)then raise exception'Métrica no disponible para este acceso.';end if;
  if not(coalesce(metric->'dimensions','[]'::jsonb)?dimension)then raise exception'Dimensión incompatible con la métrica.';end if;
  if exists(select 1 from jsonb_object_keys(filters) key where not(coalesce(metric->'compatible_filters','[]'::jsonb)?key))then raise exception'Filtro incompatible con la métrica.';end if;
  if not(coalesce(metric->'time_granularities','[]'::jsonb)?granularity)then raise exception'Granularidad incompatible con la métrica.';end if;
  result:=public.bi_explorer_query(p_company_id,array[metric_id],dimension,'bar',date_from,date_to,
    nullif(filters->>'location','')::uuid,nullif(filters->>'product','')::uuid,nullif(filters->>'customer','')::uuid,nullif(filters->>'supplier','')::uuid,
    comparison<>'none',page_no,page_size);
  rows_returned:=jsonb_array_length(coalesce(result->'items','[]'::jsonb));
  quality:=case when exists(select 1 from jsonb_array_elements(coalesce(result->'items','[]'::jsonb)) x where not coalesce((x->>'available')::boolean,false))then'partial' when rows_returned=0 then'empty'else'complete'end;
  select value into next_dimension from jsonb_array_elements_text(coalesce(metric->'dimensions','[]'::jsonb))where value<>dimension limit 1;
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)values(p_company_id,auth.uid(),'bi.agent_metric_queried','bi_metric',jsonb_build_object(
    'metric_id',metric_id,'contract_version',metric->>'contract_version','actor_type','agent','query_type','structured_metric','period',p_request->'period','granularity',granularity,
    'duration_ms',round(extract(epoch from(clock_timestamp()-started))*1000,2),'rows_returned',rows_returned,'status','completed','cache','miss'));
  return jsonb_build_object('metric',metric-'examples','definition_version',metric->>'contract_version','effective_period',result->'period','effective_comparison',comparison,
    'applied_filters',filters,'granularity',granularity,'value',case when rows_returned=1 then result#>'{items,0,current_value}'else null end,
    'series',case when dimension='period'then result->'items'else'[]'::jsonb end,'breakdown',case when dimension<>'period'then result->'items'else'[]'::jsonb end,
    'unit',metric->>'unit','availability',metric->'availability','quality',jsonb_build_object('state',quality,'missing_data',case when quality='partial'then metric->'limitations'else null end),
    'source',jsonb_build_object('rpc','bi_explorer_query','catalog_rpc','bi_get_metric_catalog'),'timestamp',now(),
    'trace',result->'trace'||jsonb_build_object('contract_version',metric->>'contract_version','duration_ms',round(extract(epoch from(clock_timestamp()-started))*1000,2),'rows',rows_returned),
    'explanation',jsonb_build_object('calculated',metric->>'formula','variation_sign',case metric->>'favorable_direction'when'up'then'Una variación positiva favorece la métrica.'when'down'then'Una variación negativa favorece la métrica.'else'El signo no implica por sí mismo una mejora.'end,'causal_inference',false),
    'next_drilldown',case when next_dimension is null then null else jsonb_build_object('dimension',next_dimension,'allowed',true)end,
    'pagination',result->'pagination');
exception when others then
  if authorized then insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)values(p_company_id,auth.uid(),'bi.agent_metric_query_failed','bi_metric',jsonb_build_object('metric_id',metric_id,'actor_type','agent','status','failed','error','invalid_request','duration_ms',round(extract(epoch from(clock_timestamp()-started))*1000,2)));end if;
  raise;
end$$;

revoke all on function public.bi_get_metric_catalog(uuid),public.bi_query_metric(uuid,jsonb) from public,anon;
grant execute on function public.bi_get_metric_catalog(uuid),public.bi_query_metric(uuid,jsonb) to authenticated;
notify pgrst,'reload schema';
