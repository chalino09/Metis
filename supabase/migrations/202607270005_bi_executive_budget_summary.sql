-- Integra Fase 5 al Resumen ejecutivo sin duplicar el motor analítico.
-- Selecciona una sola meta aplicable y calcula el resultado con bi_budget_actual.

create or replace function public.bi_get_executive_budget_summary(
  p_company_id uuid,
  p_date_from date,
  p_date_to date,
  p_location_id uuid default null,
  p_product_id uuid default null,
  p_customer_id uuid default null,
  p_supplier_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_target public.bi_budget_versions%rowtype;
  v_category_id uuid;
  v_candidate_count integer:=0;
  v_monitored_count integer:=0;
  v_late_count integer:=0;
  v_actual jsonb;
  v_actual_value numeric;
  v_as_of date;
  v_elapsed_days integer;
  v_period_days integer;
  v_attainment numeric;
  v_remaining numeric;
  v_projection numeric;
  v_pace numeric;
  v_scope_label text;
  v_fallback boolean:=false;
  v_reason text;
begin
  if auth.uid() is null
    or not public.has_company_permission(p_company_id,'view_bi')
    or not public.has_company_permission(p_company_id,'view_bi_budgets')
  then raise exception 'No autorizado para consultar el resumen presupuestal.'; end if;
  if p_date_from is null or p_date_to is null or p_date_from>p_date_to then
    raise exception 'Periodo inválido.';
  end if;
  if p_location_id is not null and not exists(
    select 1 from public.locations l
    where l.id=p_location_id and l.company_id=p_company_id and public.can_access_location(l.id)
  ) then raise exception 'Ubicación no disponible.'; end if;
  if p_product_id is not null then
    select p.category_id into v_category_id
    from public.products p
    where p.id=p_product_id and p.company_id=p_company_id;
    if not found then raise exception 'Producto no disponible.'; end if;
  end if;

  select count(*) into v_monitored_count
  from public.bi_budget_versions v
  where v.company_id=p_company_id and v.status='approved'
    and v.metric_code='net_sales' and v.budget_kind='independent'
    and p_date_to between v.period_start and v.period_end
    and public.bi_can_view_budget_version(v.id);

  if p_customer_id is not null or p_supplier_id is not null then
    v_reason:='Las metas comerciales no tienen alcance por cliente o proveedor. Retira esos filtros para comparar presupuesto contra resultado.';
  else
    select count(*) into v_candidate_count
    from public.bi_budget_versions v
    where v.company_id=p_company_id and v.status='approved'
      and v.metric_code='net_sales'
      and p_date_to between v.period_start and v.period_end
      and public.bi_can_view_budget_version(v.id)
      and case
        when p_product_id is not null and p_location_id is not null
          then v.scope_type='location_category' and v.location_id=p_location_id and v.category_id=v_category_id
        when p_product_id is not null
          then v.scope_type='category' and v.category_id=v_category_id
        when p_location_id is not null
          then v.scope_type='location' and v.location_id=p_location_id
        else v.scope_type='company'
      end;

    if v_candidate_count=1 then
      select v.* into v_target
      from public.bi_budget_versions v
      where v.company_id=p_company_id and v.status='approved'
        and v.metric_code='net_sales'
        and p_date_to between v.period_start and v.period_end
        and public.bi_can_view_budget_version(v.id)
        and case
          when p_product_id is not null and p_location_id is not null
            then v.scope_type='location_category' and v.location_id=p_location_id and v.category_id=v_category_id
          when p_product_id is not null
            then v.scope_type='category' and v.category_id=v_category_id
          when p_location_id is not null
            then v.scope_type='location' and v.location_id=p_location_id
          else v.scope_type='company'
        end;
    elsif v_candidate_count=0 and p_location_id is null and p_product_id is null and v_monitored_count=1 then
      select v.* into v_target
      from public.bi_budget_versions v
      where v.company_id=p_company_id and v.status='approved'
        and v.metric_code='net_sales' and v.budget_kind='independent'
        and p_date_to between v.period_start and v.period_end
        and public.bi_can_view_budget_version(v.id);
      v_fallback:=true;
    elsif v_candidate_count>1 then
      v_reason:='Existe más de una meta aprobada para el mismo alcance y periodo; no se agregan para evitar doble conteo.';
    else
      v_reason:=case
        when p_location_id is not null then 'No existe una meta de venta neta aprobada para esta ubicación y periodo.'
        when p_product_id is not null then 'No existe una meta de venta neta aprobada para la categoría de este producto y periodo.'
        when v_monitored_count>1 then 'Hay varias metas activas en alcances distintos. Selecciona una ubicación o consulta Metas y presupuestos.'
        else 'No existe una meta empresarial de venta neta aprobada para este periodo.'
      end;
    end if;
  end if;

  select count(*) into v_late_count
  from public.bi_budget_versions v
  cross join lateral(
    select least(p_date_to,current_date,v.period_end) as as_of
  ) d
  cross join lateral(
    select public.bi_budget_actual(v.id,v.period_start,d.as_of) as actual
  ) a
  where v.company_id=p_company_id and v.status='approved'
    and v.metric_code='net_sales' and v.budget_kind='independent'
    and p_date_to between v.period_start and v.period_end
    and public.bi_can_view_budget_version(v.id)
    and (a.actual->>'available')::boolean
    and v.value>0
    and round(
      (a.actual->>'value')::numeric
      / greatest(d.as_of-v.period_start+1,1)
      * (v.period_end-v.period_start+1),6
    )<v.value;

  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(
    p_company_id,auth.uid(),'bi.executive_budget_summary_queried','company',p_company_id,
    jsonb_build_object(
      'date_from',p_date_from,'date_to',p_date_to,'location_id',p_location_id,
      'product_id',p_product_id,'candidate_count',v_candidate_count,
      'monitored_count',v_monitored_count,'late_count',v_late_count
    )
  );

  if v_target.id is null then
    return jsonb_build_object(
      'available',false,'reason',v_reason,'monitored_count',v_monitored_count,
      'late_count',v_late_count,'updated_at',now(),
      'trace',jsonb_build_object('query','bi_get_executive_budget_summary','source','bi_budget_versions + bi_budget_actual')
    );
  end if;

  v_as_of:=least(p_date_to,current_date,v_target.period_end);
  v_actual:=public.bi_budget_actual(v_target.id,v_target.period_start,v_as_of);
  if not (v_actual->>'available')::boolean then
    return jsonb_build_object(
      'available',false,'reason',v_actual->>'reason','version_id',v_target.id,
      'monitored_count',v_monitored_count,'late_count',v_late_count,'updated_at',now(),
      'trace',jsonb_build_object('query','bi_get_executive_budget_summary','source','bi_budget_versions + bi_budget_actual')
    );
  end if;

  v_actual_value:=(v_actual->>'value')::numeric;
  v_elapsed_days:=greatest(v_as_of-v_target.period_start+1,1);
  v_period_days:=v_target.period_end-v_target.period_start+1;
  v_attainment:=case when v_target.value=0 then null else round(v_actual_value/v_target.value*100,2) end;
  v_remaining:=v_target.value-v_actual_value;
  v_projection:=case
    when v_as_of>=v_target.period_end then v_actual_value
    else round(v_actual_value/v_elapsed_days*v_period_days,6)
  end;
  v_pace:=round(v_elapsed_days::numeric/v_period_days*100,2);
  if v_target.location_id is not null then
    select l.name into v_scope_label from public.locations l where l.id=v_target.location_id;
  elsif v_target.collaborator_id is not null then
    select c.display_name into v_scope_label from public.collaborators c where c.id=v_target.collaborator_id;
  elsif v_target.category_id is not null then
    select pc.name into v_scope_label from public.product_categories pc where pc.id=v_target.category_id;
  else
    v_scope_label:='Empresa';
  end if;

  return jsonb_build_object(
    'available',true,'version_id',v_target.id,'name',v_target.name,
    'scope_type',v_target.scope_type,'scope_label',v_scope_label,
    'period_type',v_target.period_type,'period_start',v_target.period_start,'period_end',v_target.period_end,
    'unit_code',v_target.unit_code,'budget_value',v_target.value,'actual_value',v_actual_value,
    'attainment_percent',v_attainment,'remaining_value',v_remaining,'projection_value',v_projection,
    'pace_percent',v_pace,'status',case when v_projection>=v_target.value then 'on_track' else 'behind' end,
    'fallback_used',v_fallback,'monitored_count',v_monitored_count,'late_count',v_late_count,
    'updated_at',now(),
    'trace',jsonb_build_object('query','bi_get_executive_budget_summary','source','bi_budget_versions + bi_budget_actual')
  );
end
$$;

revoke all on function public.bi_get_executive_budget_summary(uuid,date,date,uuid,uuid,uuid,uuid) from public;
grant execute on function public.bi_get_executive_budget_summary(uuid,date,date,uuid,uuid,uuid,uuid) to authenticated;

notify pgrst,'reload schema';
