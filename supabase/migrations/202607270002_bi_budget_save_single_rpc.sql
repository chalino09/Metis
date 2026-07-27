-- Reemplazo definitivo del guardado de presupuestos.
-- Integra periodo, versión y desglose mensual en una sola transacción y no
-- depende de la función interna creada por migraciones anteriores.

create or replace function public.bi_save_budget_draft(
  p_company_id uuid,p_version_id uuid,p_name text,p_description text,p_metric_code text,
  p_period_type text,p_period_start date,p_scope_type text,p_location_id uuid,p_collaborator_id uuid,
  p_category_id uuid,p_value numeric,p_unit_code text,p_owner_user_id uuid,p_parent_version_id uuid,
  p_replace_version_id uuid,p_reason text,p_monthly_allocations jsonb default '[]'::jsonb
)returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v public.bi_budget_versions%rowtype;
  old_v public.bi_budget_versions%rowtype;
  b uuid;
  v_start date;
  v_end date;
  v_kind text:='independent';
  v_number integer:=1;
  v_expected integer;
  v_allocations jsonb:=coalesce(p_monthly_allocations,'[]'::jsonb);
  v_item jsonb;
  v_month date;
  v_amount numeric;
  v_total numeric:=0;
  v_seen date[]:='{}'::date[];
  v_snapshot jsonb;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'create_bi_budget_drafts')then
    raise exception'No autorizado para crear borradores.';
  end if;
  if nullif(trim(coalesce(p_reason,'')),'')is null then
    raise exception'El motivo de creación o modificación es obligatorio.';
  end if;
  if p_parent_version_id is not null and not public.has_company_permission(p_company_id,'manage_bi_budget_distributions')then
    raise exception'No autorizado para distribuir presupuestos.';
  end if;
  if p_value is null or p_value<0 then raise exception'La meta total debe ser mayor o igual a cero.';end if;

  if p_period_type='monthly'then
    v_start:=date_trunc('month',p_period_start)::date;
    v_end:=(v_start+interval'1 month'-interval'1 day')::date;
    v_expected:=0;
  elsif p_period_type='quarterly'then
    v_start:=date_trunc('quarter',p_period_start)::date;
    v_end:=(v_start+interval'3 months'-interval'1 day')::date;
    v_expected:=3;
  elsif p_period_type='annual'then
    v_start:=date_trunc('year',p_period_start)::date;
    v_end:=(v_start+interval'1 year'-interval'1 day')::date;
    v_expected:=12;
  else
    raise exception'Tipo de periodo inválido.';
  end if;

  if jsonb_typeof(v_allocations)<>'array'then raise exception'La distribución mensual es inválida.';end if;
  if v_expected=0 and jsonb_array_length(v_allocations)<>0 then
    raise exception'Una meta mensual no requiere desglose adicional.';
  end if;
  if v_expected>0 then
    for v_item in select value from jsonb_array_elements(v_allocations)loop
      begin
        v_month:=(v_item->>'month_start')::date;
        v_amount:=(v_item->>'value')::numeric;
      exception when others then
        raise exception'Cada distribución debe contener un mes y un valor válidos.';
      end;
      if v_month<>date_trunc('month',v_month)::date or v_month<v_start or v_month>v_end or v_amount<0 then
        raise exception'Cada distribución debe usar exactamente un mes válido del periodo.';
      end if;
      if v_month=any(v_seen)then raise exception'No se puede repetir un mes en la distribución.';end if;
      v_seen:=array_append(v_seen,v_month);
      v_total:=v_total+v_amount;
    end loop;
    if cardinality(v_seen)<>v_expected or abs(v_total-p_value)>0.005 then
      raise exception'La distribución mensual debe cubrir cada mes y sumar exactamente la meta total.';
    end if;
    for v_month in select generate_series(v_start,date_trunc('month',v_end)::date,interval'1 month')::date loop
      if not(v_month=any(v_seen))then raise exception'Falta un mes en la distribución.';end if;
    end loop;
  end if;

  if p_version_id is null then
    if p_replace_version_id is not null then
      select*into old_v from public.bi_budget_versions
      where id=p_replace_version_id and company_id=p_company_id and status='approved';
      if not found then raise exception'La versión a sustituir no está aprobada.';end if;
      b:=old_v.budget_id;
      v_number:=old_v.version+1;
    else
      insert into public.bi_budgets(company_id)values(p_company_id)returning id into b;
    end if;

    if p_parent_version_id is not null then
      v_kind:='distribution';
      if not exists(
        select 1 from public.bi_budget_versions p
        where p.id=p_parent_version_id and p.company_id=p_company_id and p.status='approved'
          and p.metric_code=p_metric_code and p.period_start=v_start and p.period_end=v_end
          and((p.scope_type='company'and p_scope_type='location')
            or(p.scope_type='location'and p_scope_type in('location_category','responsible')))
          and(p.scope_type<>'location'or p.location_id=coalesce(p_location_id,p.location_id))
      )then raise exception'La distribución no corresponde a una jerarquía aprobada.';end if;
    end if;

    insert into public.bi_budget_versions(
      budget_id,company_id,version,name,description,metric_code,period_type,period_start,period_end,
      scope_type,location_id,collaborator_id,category_id,value,unit_code,owner_user_id,budget_kind,
      parent_version_id,replaces_version_id
    )values(
      b,p_company_id,v_number,trim(p_name),nullif(trim(coalesce(p_description,'')),''),p_metric_code,
      p_period_type,v_start,v_end,p_scope_type,p_location_id,p_collaborator_id,p_category_id,p_value,
      case when p_metric_code='units_sold'then'unit'else upper(p_unit_code)end,
      coalesce(p_owner_user_id,auth.uid()),v_kind,p_parent_version_id,p_replace_version_id
    )returning*into v;
  else
    select*into v from public.bi_budget_versions
    where id=p_version_id and company_id=p_company_id for update;
    if not found or v.status<>'draft'then
      raise exception'El borrador no está disponible para modificación.';
    end if;
    update public.bi_budget_versions set
      name=trim(p_name),description=nullif(trim(coalesce(p_description,'')),''),
      metric_code=p_metric_code,period_type=p_period_type,period_start=v_start,period_end=v_end,
      scope_type=p_scope_type,location_id=p_location_id,collaborator_id=p_collaborator_id,
      category_id=p_category_id,value=p_value,
      unit_code=case when p_metric_code='units_sold'then'unit'else upper(p_unit_code)end,
      owner_user_id=coalesce(p_owner_user_id,owner_user_id),updated_at=now()
    where id=v.id returning*into v;
  end if;

  delete from public.bi_budget_monthly_allocations a where a.version_id=v.id;
  insert into public.bi_budget_monthly_allocations(company_id,version_id,month_start,value)
  select p_company_id,v.id,x.month_start,x.value
  from jsonb_to_recordset(v_allocations)as x(month_start date,value numeric);

  v_snapshot:=jsonb_build_object('version',to_jsonb(v),'monthly_allocations',v_allocations);
  insert into public.bi_budget_version_events(company_id,version_id,action,reason,snapshot)
  values(p_company_id,v.id,case when p_version_id is null then'created'else'modified'end,trim(p_reason),v_snapshot);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'bi.budget_draft_saved','bi_budget_version',v.id,
    jsonb_build_object('version',v.version,'reason',trim(p_reason),'monthly_allocations',jsonb_array_length(v_allocations)));
  return to_jsonb(v);
end$$;

revoke all on function public.bi_save_budget_draft(uuid,uuid,text,text,text,text,date,text,uuid,uuid,uuid,numeric,text,uuid,uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.bi_save_budget_draft(uuid,uuid,text,text,text,text,date,text,uuid,uuid,uuid,numeric,text,uuid,uuid,uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';
