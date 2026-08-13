-- Satrapy BI · Fase 4: alertas operativas persistentes y deterministas.

insert into public.permissions(code,description) values
  ('view_bi_alerts','Consultar alertas operativas de BI dentro del alcance autorizado.'),
  ('manage_bi_alerts','Marcar alertas de BI como revisadas o resueltas.')
on conflict(code)do update set description=excluded.description;
insert into public.role_permissions(role_id,permission_id)
select role_data.id,permission_data.id from public.roles role_data cross join public.permissions permission_data
where role_data.code in('super_admin','direccion_admin') and permission_data.code in('view_bi_alerts','manage_bi_alerts')
on conflict do nothing;

create table public.bi_alert_rules(
  code text primary key,
  version integer not null check(version>0),
  metric_code text not null,
  favorable_direction text not null check(favorable_direction in('up','down','completeness')),
  comparison_type text not null check(comparison_type in('period','threshold','coverage','budget')),
  threshold jsonb not null,
  minimum_data jsonb not null,
  severity_policy jsonb not null,
  dimensions text[] not null default'{}',
  explanation_template text not null,
  suggested_action text not null,
  auto_resolve boolean not null default false,
  is_active boolean not null default true,
  updated_at timestamptz not null default now()
);

insert into public.bi_alert_rules(code,version,metric_code,favorable_direction,comparison_type,threshold,minimum_data,severity_policy,dimensions,explanation_template,suggested_action,auto_resolve)values
('sales_decline',1,'net_sales','up','period','{"warning_percent":-10,"critical_percent":-25}','{"previous_value_min":1,"tickets_min":20}','{"warning":"warning","critical":"critical"}','{}','Las ventas netas disminuyeron frente al periodo comparable.','Revisa las dimensiones con mayor contribución negativa.',true),
('location_sales_decline',1,'net_sales','up','period','{"warning_percent":-15,"critical_percent":-30,"contribution_abs_min":20}','{"previous_value_min":1}','{"warning":"warning","critical":"critical"}',array['location'],'Una sucursal concentra una parte relevante de la caída de ventas.','Revisa categorías, productos y operaciones de la sucursal.',true),
('gross_margin_unreliable',1,'gross_margin','completeness','coverage','{"required_coverage_percent":100}','{"net_sales_min":1}','{"warning":"warning"}','{}','El margen bruto no tiene cobertura de costo suficiente para una lectura confiable.','Completa o valida el costo reconocido de las partidas afectadas.',true),
('budget_behind_pace',1,'net_sales','up','budget','{"pace_gap_warning":10,"pace_gap_critical":25}','{"budget_value_min":1}','{"warning":"warning","critical":"critical"}','{}','El resultado comercial está por debajo del ritmo esperado de la meta aprobada.','Revisa el presupuesto aplicable y las dimensiones que explican la desviación.',true)
on conflict(code)do update set version=excluded.version,metric_code=excluded.metric_code,favorable_direction=excluded.favorable_direction,
comparison_type=excluded.comparison_type,threshold=excluded.threshold,minimum_data=excluded.minimum_data,severity_policy=excluded.severity_policy,
dimensions=excluded.dimensions,explanation_template=excluded.explanation_template,suggested_action=excluded.suggested_action,
auto_resolve=excluded.auto_resolve,is_active=true,updated_at=now();

create table public.bi_alert_evaluations(
  id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id)on delete cascade,
  period_from date not null,period_to date not null,comparison_mode text not null check(comparison_mode in('previous_period','previous_year')),
  status text not null check(status in('completed','failed')),rules_evaluated integer not null default 0,
  conditions_detected integer not null default 0,alerts_created integer not null default 0,alerts_updated integer not null default 0,
  alerts_resolved integer not null default 0,duration_ms numeric not null default 0,principal_user_id uuid references auth.users(id)on delete set null,
  error_message text,trace jsonb not null default'{}',created_at timestamptz not null default now(),completed_at timestamptz not null default now()
);

create table public.bi_alerts(
  id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id)on delete cascade,
  condition_key text not null,rule_code text not null references public.bi_alert_rules(code),rule_version integer not null,
  alert_type text not null,metric_code text not null,period_from date not null,period_to date not null,
  comparison_from date,comparison_to date,comparison_mode text not null check(comparison_mode in('previous_period','previous_year')),
  filters jsonb not null default'{}',dimension text,entity_id uuid,entity_label text,
  severity text not null check(severity in('critical','warning','informational')),
  observed_value numeric,comparison_value numeric,threshold_value numeric,impact_value numeric,impact_percent numeric,
  explanation text not null,suggested_action text not null,evidence jsonb not null default'{}',
  status text not null default'active' check(status in('active','reviewed','resolved')),
  first_detected_at timestamptz not null default now(),last_detected_at timestamptz not null default now(),last_evaluation_id uuid references public.bi_alert_evaluations(id)on delete set null,
  reviewed_by uuid references auth.users(id)on delete set null,reviewed_at timestamptz,
  resolved_by uuid references auth.users(id)on delete set null,resolved_at timestamptz,resolution_reason text,
  created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create unique index bi_alerts_open_condition_uidx on public.bi_alerts(company_id,condition_key)where status in('active','reviewed');
create index bi_alerts_priority_idx on public.bi_alerts(company_id,status,severity,last_detected_at desc);
create index bi_alerts_dimension_idx on public.bi_alerts(company_id,dimension,entity_id,status);
create index bi_alert_evaluations_company_idx on public.bi_alert_evaluations(company_id,created_at desc);

create table public.bi_alert_events(
  id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id)on delete cascade,
  alert_id uuid not null references public.bi_alerts(id)on delete cascade,event_type text not null check(event_type in('detected','updated','reviewed','resolved','reopened')),
  from_status text,to_status text,actor_id uuid references auth.users(id)on delete set null,reason text,
  snapshot jsonb not null default'{}',created_at timestamptz not null default now()
);
create index bi_alert_events_alert_idx on public.bi_alert_events(alert_id,created_at desc);

alter table public.bi_alert_rules enable row level security;
alter table public.bi_alert_evaluations enable row level security;
alter table public.bi_alerts enable row level security;
alter table public.bi_alert_events enable row level security;
create policy bi_alert_rules_read on public.bi_alert_rules for select to authenticated using(true);
create policy bi_alerts_read on public.bi_alerts for select to authenticated using(public.has_company_permission(company_id,'view_bi_alerts'));
create policy bi_alert_evaluations_read on public.bi_alert_evaluations for select to authenticated using(public.has_company_permission(company_id,'view_bi_alerts'));
create policy bi_alert_events_read on public.bi_alert_events for select to authenticated using(public.has_company_permission(company_id,'view_bi_alerts'));

create or replace function public.bi_store_detected_alert(p_evaluation_id uuid,p_company_id uuid,p_condition_key text,p_rule_code text,
  p_alert_type text,p_metric_code text,p_period_from date,p_period_to date,p_comparison_from date,p_comparison_to date,p_comparison_mode text,
  p_filters jsonb,p_dimension text,p_entity_id uuid,p_entity_label text,p_severity text,p_observed numeric,p_comparison numeric,
  p_threshold numeric,p_impact numeric,p_impact_percent numeric,p_explanation text,p_action text,p_evidence jsonb)
returns text language plpgsql security definer set search_path=public as $$
declare v_alert public.bi_alerts%rowtype;v_rule public.bi_alert_rules%rowtype;v_result text;
begin
  select*into v_rule from public.bi_alert_rules where code=p_rule_code and is_active;
  if not found then raise exception'Regla de alerta no disponible.';end if;
  select*into v_alert from public.bi_alerts where company_id=p_company_id and condition_key=p_condition_key and status in('active','reviewed') for update;
  if found then
    update public.bi_alerts set rule_version=v_rule.version,alert_type=p_alert_type,metric_code=p_metric_code,period_from=p_period_from,period_to=p_period_to,
      comparison_from=p_comparison_from,comparison_to=p_comparison_to,comparison_mode=p_comparison_mode,filters=coalesce(p_filters,'{}'),dimension=p_dimension,
      entity_id=p_entity_id,entity_label=p_entity_label,severity=p_severity,observed_value=p_observed,comparison_value=p_comparison,threshold_value=p_threshold,
      impact_value=p_impact,impact_percent=p_impact_percent,explanation=p_explanation,suggested_action=p_action,evidence=coalesce(p_evidence,'{}'),
      last_detected_at=now(),last_evaluation_id=p_evaluation_id,updated_at=now() where id=v_alert.id returning*into v_alert;v_result:='updated';
  else
    insert into public.bi_alerts(company_id,condition_key,rule_code,rule_version,alert_type,metric_code,period_from,period_to,comparison_from,comparison_to,
      comparison_mode,filters,dimension,entity_id,entity_label,severity,observed_value,comparison_value,threshold_value,impact_value,impact_percent,
      explanation,suggested_action,evidence,last_evaluation_id)
    values(p_company_id,p_condition_key,p_rule_code,v_rule.version,p_alert_type,p_metric_code,p_period_from,p_period_to,p_comparison_from,p_comparison_to,
      p_comparison_mode,coalesce(p_filters,'{}'),p_dimension,p_entity_id,p_entity_label,p_severity,p_observed,p_comparison,p_threshold,p_impact,p_impact_percent,
      p_explanation,p_action,coalesce(p_evidence,'{}'),p_evaluation_id)returning*into v_alert;v_result:='created';
  end if;
  insert into public.bi_alert_events(company_id,alert_id,event_type,from_status,to_status,snapshot)
  values(p_company_id,v_alert.id,case when v_result='created'then'detected'else'updated'end,v_alert.status,v_alert.status,
    jsonb_build_object('evaluation_id',p_evaluation_id,'severity',p_severity,'observed_value',p_observed,'comparison_value',p_comparison,'impact_value',p_impact));
  return v_result;
end$$;
revoke all on function public.bi_store_detected_alert(uuid,uuid,text,text,text,text,date,date,date,date,text,jsonb,text,uuid,text,text,numeric,numeric,numeric,numeric,numeric,text,text,jsonb)from public,anon,authenticated;

create or replace function public.bi_evaluate_company_alerts(p_company_id uuid,p_date_from date,p_date_to date,
  p_comparison_mode text default'previous_period',p_principal_user_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_started timestamptz:=clock_timestamp();v_principal uuid:=coalesce(p_principal_user_id,auth.uid());v_original_sub text:=current_setting('request.jwt.claim.sub',true);
  v_eval public.bi_alert_evaluations%rowtype;v_summary jsonb;v_budget jsonb;v_locations jsonb;v_metric jsonb;v_sales jsonb;v_margin jsonb;v_row jsonb;
  v_change numeric;v_percent numeric;v_gap numeric;v_result text;v_detected text[]:='{}';v_created integer:=0;v_updated integer:=0;v_resolved integer:=0;
  v_previous_from date;v_previous_to date;v_severity text;v_rule_count integer;
begin
  if p_date_from is null or p_date_to is null or p_date_from>p_date_to or p_date_to-p_date_from>365 then raise exception'Periodo de evaluación inválido.';end if;
  if p_comparison_mode not in('previous_period','previous_year')then raise exception'Comparación no permitida.';end if;
  if auth.role()<>'service_role'and(auth.uid()is null or not public.has_company_permission(p_company_id,'manage_bi_alerts'))then raise exception'No autorizado para evaluar alertas.';end if;
  if v_principal is null or not exists(select 1 from public.user_roles ur join public.role_permissions rp on rp.role_id=ur.role_id join public.permissions permission on permission.id=rp.permission_id
    where ur.user_id=v_principal and ur.company_id=p_company_id and permission.code='view_bi')then raise exception'No existe un principal autorizado para evaluar BI.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text,7414));
  select count(*)into v_rule_count from public.bi_alert_rules where is_active;
  insert into public.bi_alert_evaluations(company_id,period_from,period_to,comparison_mode,status,rules_evaluated,principal_user_id)
  values(p_company_id,p_date_from,p_date_to,p_comparison_mode,'completed',v_rule_count,v_principal)returning*into v_eval;
  perform set_config('request.jwt.claim.sub',v_principal::text,true);perform set_config('request.jwt.claim.role','authenticated',true);
  v_summary:=public.bi_get_executive_summary_compared(p_company_id,p_date_from,p_date_to,null,null,null,null,p_comparison_mode);
  v_previous_from:=(v_summary#>>'{period,previous_from}')::date;v_previous_to:=(v_summary#>>'{period,previous_to}')::date;
  select value into v_sales from jsonb_array_elements(v_summary->'metrics')where value->>'code'='net_sales';
  select value into v_margin from jsonb_array_elements(v_summary->'metrics')where value->>'code'='gross_margin';
  if coalesce((v_sales->>'available')::boolean,false)and(v_sales->>'previous_value')::numeric>0 and coalesce((select(value->>'value')::numeric from jsonb_array_elements(v_summary->'metrics')where value->>'code'='tickets'),0)>=20 then
    v_change:=(v_sales->>'value')::numeric-(v_sales->>'previous_value')::numeric;v_percent:=100*v_change/abs((v_sales->>'previous_value')::numeric);
    if v_percent<=-10 then v_severity:=case when v_percent<=-25 then'critical'else'warning'end;v_detected:=array_append(v_detected,'sales_decline:company:'||p_comparison_mode);
      v_result:=public.bi_store_detected_alert(v_eval.id,p_company_id,v_detected[array_length(v_detected,1)],'sales_decline','metric_decline','net_sales',p_date_from,p_date_to,v_previous_from,v_previous_to,p_comparison_mode,'{}',null,null,null,v_severity,
        (v_sales->>'value')::numeric,(v_sales->>'previous_value')::numeric,-10,abs(v_change),v_percent,'Las ventas netas disminuyeron '||round(abs(v_percent),1)||'% frente al periodo comparable.','Revisa las dimensiones con mayor contribución negativa.',
        jsonb_build_object('metric',v_sales,'period',v_summary->'period','trace',v_summary->'trace','rule','sales_decline','rule_version',1));
      if v_result='created'then v_created:=v_created+1;else v_updated:=v_updated+1;end if;end if;
  end if;
  v_locations:=public.bi_get_operational_table(p_company_id,'net_sales','location',p_date_from,p_date_to,null,null,null,null,null,'negative_impact','desc',1,100,p_comparison_mode);
  for v_row in select value from jsonb_array_elements(v_locations->'items')loop
    if coalesce((v_row->>'available')::boolean,false)and coalesce((v_row->>'previous_value')::numeric,0)>0 and coalesce((v_row->>'change_percent')::numeric,0)<=-15 and abs(coalesce((v_row->>'contribution_percent')::numeric,0))>=20 then
      v_severity:=case when(v_row->>'change_percent')::numeric<=-30 then'critical'else'warning'end;
      v_detected:=array_append(v_detected,'location_sales_decline:'||(v_row->>'group_key')||':'||p_comparison_mode);
      v_result:=public.bi_store_detected_alert(v_eval.id,p_company_id,v_detected[array_length(v_detected,1)],'location_sales_decline','negative_contribution','net_sales',p_date_from,p_date_to,v_previous_from,v_previous_to,p_comparison_mode,
        jsonb_build_object('location_id',v_row->>'group_key'),'location',(v_row->>'group_key')::uuid,v_row->>'group_label',v_severity,(v_row->>'current_value')::numeric,(v_row->>'previous_value')::numeric,-15,abs((v_row->>'change_value')::numeric),(v_row->>'change_percent')::numeric,
        (v_row->>'group_label')||' disminuyó '||round(abs((v_row->>'change_percent')::numeric),1)||'% y explica una parte relevante del cambio.','Revisa categorías, productos y operaciones de la sucursal.',jsonb_build_object('row',v_row,'period',v_locations->'period','trace',v_locations->'trace','rule','location_sales_decline','rule_version',1));
      if v_result='created'then v_created:=v_created+1;else v_updated:=v_updated+1;end if;
    end if;
  end loop;
  if coalesce((v_sales->>'value')::numeric,0)>0 and not coalesce((v_margin->>'available')::boolean,false)then
    v_detected:=array_append(v_detected,'gross_margin_unreliable:company:'||p_comparison_mode);
    v_result:=public.bi_store_detected_alert(v_eval.id,p_company_id,v_detected[array_length(v_detected,1)],'gross_margin_unreliable','data_quality','gross_margin',p_date_from,p_date_to,v_previous_from,v_previous_to,p_comparison_mode,'{}',null,null,null,'warning',null,null,100,null,null,
      'El margen bruto no tiene cobertura de costo suficiente para una lectura confiable.','Completa o valida el costo reconocido de las partidas afectadas.',jsonb_build_object('metric',v_margin,'period',v_summary->'period','trace',v_summary->'trace','rule','gross_margin_unreliable','rule_version',1));
    if v_result='created'then v_created:=v_created+1;else v_updated:=v_updated+1;end if;
  end if;
  if public.has_company_permission(p_company_id,'view_bi_budgets')then
    begin v_budget:=public.bi_get_executive_budget_summary(p_company_id,p_date_from,p_date_to,null,null,null,null);exception when others then v_budget:=null;end;
    if coalesce((v_budget->>'available')::boolean,false)then v_gap:=coalesce((v_budget->>'pace_percent')::numeric,0)-coalesce((v_budget->>'attainment_percent')::numeric,0);
      if v_gap>=10 then v_severity:=case when v_gap>=25 then'critical'else'warning'end;v_detected:=array_append(v_detected,'budget_behind_pace:company:'||p_comparison_mode);
        v_result:=public.bi_store_detected_alert(v_eval.id,p_company_id,v_detected[array_length(v_detected,1)],'budget_behind_pace','budget_deviation','net_sales',p_date_from,p_date_to,v_previous_from,v_previous_to,p_comparison_mode,'{}',null,null,null,v_severity,
          (v_budget->>'actual_value')::numeric,(v_budget->>'budget_value')::numeric,v_gap,abs(coalesce((v_budget->>'remaining_value')::numeric,0)),-v_gap,
          'El resultado comercial está '||round(v_gap,1)||' puntos por debajo del ritmo esperado.','Revisa el presupuesto aplicable y las dimensiones que explican la desviación.',jsonb_build_object('budget',v_budget,'rule','budget_behind_pace','rule_version',1));
        if v_result='created'then v_created:=v_created+1;else v_updated:=v_updated+1;end if;end if;
    end if;
  end if;
  update public.bi_alerts alert set status='resolved',resolved_at=now(),resolved_by=null,resolution_reason='La condición dejó de cumplirse en una evaluación verificable.',updated_at=now(),last_evaluation_id=v_eval.id
  from public.bi_alert_rules rule where alert.rule_code=rule.code and rule.auto_resolve and alert.company_id=p_company_id and alert.status in('active','reviewed')
    and alert.comparison_mode=p_comparison_mode and not(alert.condition_key=any(v_detected));get diagnostics v_resolved=row_count;
  insert into public.bi_alert_events(company_id,alert_id,event_type,from_status,to_status,reason,snapshot)
  select p_company_id,alert.id,'resolved','active','resolved',alert.resolution_reason,jsonb_build_object('evaluation_id',v_eval.id,'automatic',true)
  from public.bi_alerts alert where alert.last_evaluation_id=v_eval.id and alert.status='resolved' and alert.resolved_by is null;
  update public.bi_alert_evaluations set conditions_detected=coalesce(array_length(v_detected,1),0),alerts_created=v_created,alerts_updated=v_updated,alerts_resolved=v_resolved,
    duration_ms=extract(epoch from(clock_timestamp()-v_started))*1000,trace=jsonb_build_object('summary','bi_get_executive_summary_compared','locations','bi_get_operational_table','rule_versions',jsonb_build_object('sales_decline',1,'location_sales_decline',1,'gross_margin_unreliable',1,'budget_behind_pace',1)),completed_at=now()where id=v_eval.id;
  if v_original_sub is not null then perform set_config('request.jwt.claim.sub',v_original_sub,true);end if;
  return jsonb_build_object('evaluation_id',v_eval.id,'conditions_detected',coalesce(array_length(v_detected,1),0),'created',v_created,'updated',v_updated,'resolved',v_resolved,'duration_ms',round(extract(epoch from(clock_timestamp()-v_started))*1000,2));
exception when others then
  if v_eval.id is not null then update public.bi_alert_evaluations set status='failed',error_message=sqlerrm,duration_ms=extract(epoch from(clock_timestamp()-v_started))*1000,completed_at=now()where id=v_eval.id;end if;
  if v_original_sub is not null then perform set_config('request.jwt.claim.sub',v_original_sub,true);end if;raise;
end$$;

create or replace function public.bi_list_alerts(p_company_id uuid,p_status text default null,p_severity text default null,p_metric_code text default null,
  p_location_id uuid default null,p_date_from date default null,p_date_to date default null,p_search text default null,p_page integer default 1,p_page_size integer default 25)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);v_items jsonb;v_total bigint;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'view_bi_alerts')then raise exception'No autorizado para consultar alertas.';end if;
  if p_status is not null and p_status not in('active','reviewed','resolved')then raise exception'Estado no permitido.';end if;
  if p_severity is not null and p_severity not in('critical','warning','informational')then raise exception'Severidad no permitida.';end if;
  if length(coalesce(p_search,''))>120 then raise exception'La búsqueda admite hasta 120 caracteres.';end if;
  with filtered as materialized(select alert.*from public.bi_alerts alert where alert.company_id=p_company_id
    and(p_status is null or alert.status=p_status)and(p_severity is null or alert.severity=p_severity)and(p_metric_code is null or alert.metric_code=p_metric_code)
    and(p_location_id is null or(alert.dimension='location'and alert.entity_id=p_location_id))and(p_date_from is null or alert.period_to>=p_date_from)
    and(p_date_to is null or alert.period_from<=p_date_to)and(nullif(trim(coalesce(p_search,'')),'')is null or lower(concat_ws(' ',alert.explanation,alert.entity_label,alert.metric_code))like'%'||lower(trim(p_search))||'%')),
  paged as(select*from filtered order by case severity when'critical'then 0 when'warning'then 1 else 2 end,abs(coalesce(impact_value,0))desc,last_detected_at desc limit v_size offset(v_page-1)*v_size)
  select coalesce(jsonb_agg(to_jsonb(paged)order by case severity when'critical'then 0 when'warning'then 1 else 2 end,abs(coalesce(impact_value,0))desc,last_detected_at desc),'[]'),(select count(*)from filtered)into v_items,v_total from paged;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total),'updated_at',now());
end$$;

create or replace function public.bi_get_attention_alerts(p_company_id uuid,p_limit integer default 5)returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'view_bi_alerts')then raise exception'No autorizado para consultar alertas.';end if;
  return(select coalesce(jsonb_agg(to_jsonb(alert)order by case severity when'critical'then 0 when'warning'then 1 else 2 end,abs(coalesce(impact_value,0))desc,last_detected_at desc),'[]')from(
    select*from public.bi_alerts where company_id=p_company_id and status in('active','reviewed')order by case severity when'critical'then 0 when'warning'then 1 else 2 end,abs(coalesce(impact_value,0))desc,last_detected_at desc limit least(greatest(coalesce(p_limit,5),1),5))alert);
end$$;

create or replace function public.bi_transition_alert(p_company_id uuid,p_alert_id uuid,p_action text,p_reason text default null)returns jsonb language plpgsql security definer set search_path=public as $$
declare v_alert public.bi_alerts%rowtype;v_from text;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'manage_bi_alerts')then raise exception'No autorizado para actualizar alertas.';end if;
  select*into v_alert from public.bi_alerts where id=p_alert_id and company_id=p_company_id for update;if not found then raise exception'Alerta no disponible.';end if;v_from:=v_alert.status;
  if p_action='review'and v_alert.status='active'then update public.bi_alerts set status='reviewed',reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now()where id=p_alert_id returning*into v_alert;
  elsif p_action='resolve'and v_alert.status in('active','reviewed')then if length(trim(coalesce(p_reason,'')))<5 then raise exception'Indica un motivo de al menos 5 caracteres.';end if;
    update public.bi_alerts set status='resolved',resolved_by=auth.uid(),resolved_at=now(),resolution_reason=trim(p_reason),updated_at=now()where id=p_alert_id returning*into v_alert;
  else raise exception'Transición no permitida.';end if;
  insert into public.bi_alert_events(company_id,alert_id,event_type,from_status,to_status,actor_id,reason,snapshot)values(p_company_id,p_alert_id,case p_action when'review'then'reviewed'else'resolved'end,v_from,v_alert.status,auth.uid(),nullif(trim(coalesce(p_reason,'')),''),jsonb_build_object('severity',v_alert.severity,'last_evaluation_id',v_alert.last_evaluation_id));
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)values(p_company_id,auth.uid(),case p_action when'review'then'bi.alert_reviewed'else'bi.alert_resolved'end,'bi_alert',p_alert_id,jsonb_build_object('from',v_from,'to',v_alert.status,'reason',p_reason));
  return to_jsonb(v_alert);
end$$;

create or replace function public.bi_get_alert_history(p_company_id uuid,p_alert_id uuid,p_page integer default 1,p_page_size integer default 25)returns jsonb language plpgsql security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);v_items jsonb;v_total bigint;
begin if auth.uid()is null or not public.has_company_permission(p_company_id,'view_bi_alerts')then raise exception'No autorizado para consultar alertas.';end if;
  select coalesce(jsonb_agg(to_jsonb(event_data)order by event_data.created_at desc),'[]'),(select count(*)from public.bi_alert_events where company_id=p_company_id and alert_id=p_alert_id)
  into v_items,v_total from(select event.*,profile.full_name actor_name from public.bi_alert_events event left join public.profiles profile on profile.id=event.actor_id where event.company_id=p_company_id and event.alert_id=p_alert_id order by event.created_at desc limit v_size offset(v_page-1)*v_size)event_data;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));end$$;

create or replace function public.bi_evaluate_all_alerts()returns void language plpgsql security definer set search_path=public as $$
declare company_row record;v_principal uuid;begin
  for company_row in select id from public.companies loop
    select ur.user_id into v_principal from public.user_roles ur join public.roles role_data on role_data.id=ur.role_id where ur.company_id=company_row.id and role_data.code='direccion_admin'order by ur.created_at limit 1;
    if v_principal is not null then begin perform public.bi_evaluate_company_alerts(company_row.id,current_date-29,current_date,'previous_period',v_principal);exception when others then null;end;end if;
  end loop;end$$;

revoke all on function public.bi_evaluate_company_alerts(uuid,date,date,text,uuid)from public,anon;
revoke all on function public.bi_list_alerts(uuid,text,text,text,uuid,date,date,text,integer,integer)from public,anon;
revoke all on function public.bi_get_attention_alerts(uuid,integer)from public,anon;
revoke all on function public.bi_transition_alert(uuid,uuid,text,text)from public,anon;
revoke all on function public.bi_get_alert_history(uuid,uuid,integer,integer)from public,anon;
revoke all on function public.bi_evaluate_all_alerts()from public,anon,authenticated;
grant execute on function public.bi_evaluate_company_alerts(uuid,date,date,text,uuid)to authenticated,service_role;
grant execute on function public.bi_list_alerts(uuid,text,text,text,uuid,date,date,text,integer,integer)to authenticated;
grant execute on function public.bi_get_attention_alerts(uuid,integer)to authenticated;
grant execute on function public.bi_transition_alert(uuid,uuid,text,text)to authenticated;
grant execute on function public.bi_get_alert_history(uuid,uuid,integer,integer)to authenticated;
grant execute on function public.bi_evaluate_all_alerts()to service_role;

create extension if not exists pg_cron with schema pg_catalog;
do $$declare v_job_id bigint;begin select jobid into v_job_id from cron.job where jobname='satrapy-bi-operational-alerts'limit 1;if v_job_id is not null then perform cron.unschedule(v_job_id);end if;
perform cron.schedule('satrapy-bi-operational-alerts','*/30 * * * *','select public.bi_evaluate_all_alerts();');end$$;
notify pgrst,'reload schema';
