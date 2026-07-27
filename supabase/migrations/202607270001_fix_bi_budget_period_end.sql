-- Corrige el cálculo de cierre de periodo en instalaciones donde Fase 5
-- ya se aplicó antes de la corrección de intervalos.
create or replace function public.bi_save_budget_draft_phase5(
  p_company_id uuid,p_version_id uuid,p_name text,p_description text,p_metric_code text,
  p_period_type text,p_period_start date,p_scope_type text,p_location_id uuid,p_collaborator_id uuid,
  p_category_id uuid,p_value numeric,p_unit_code text,p_owner_user_id uuid,p_parent_version_id uuid,
  p_replace_version_id uuid,p_reason text
)returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.bi_budget_versions%rowtype;b uuid;v_end date;v_kind text:='independent';v_number integer:=1;old_v public.bi_budget_versions%rowtype;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'create_bi_budget_drafts')then raise exception'No autorizado para crear borradores.';end if;
  if nullif(trim(coalesce(p_reason,'')),'')is null then raise exception'El motivo de creación o modificación es obligatorio.';end if;
  if p_parent_version_id is not null and not public.has_company_permission(p_company_id,'manage_bi_budget_distributions')then raise exception'No autorizado para distribuir presupuestos.';end if;
  if p_period_type='monthly'then v_end:=(date_trunc('month',p_period_start)+interval'1 month'-interval'1 day')::date;
  elsif p_period_type='quarterly'then v_end:=(date_trunc('quarter',p_period_start)+interval'3 months'-interval'1 day')::date;
  elsif p_period_type='annual'then v_end:=(date_trunc('year',p_period_start)+interval'1 year'-interval'1 day')::date;
  else raise exception'Tipo de periodo inválido.';end if;
  if p_version_id is null then
    if p_replace_version_id is not null then
      select*into old_v from public.bi_budget_versions where id=p_replace_version_id and company_id=p_company_id and status='approved';
      if not found then raise exception'La versión a sustituir no está aprobada.';end if;
      b:=old_v.budget_id;v_number:=old_v.version+1;
    else insert into public.bi_budgets(company_id)values(p_company_id)returning id into b;end if;
    if p_parent_version_id is not null then
      v_kind:='distribution';
      if not exists(select 1 from public.bi_budget_versions p where p.id=p_parent_version_id and p.company_id=p_company_id and p.status='approved'
        and p.metric_code=p_metric_code and p.period_start=date_trunc(case p_period_type when'monthly'then'month'when'quarterly'then'quarter'else'year'end,p_period_start)::date
        and p.period_end=v_end and((p.scope_type='company'and p_scope_type='location')or(p.scope_type='location'and p_scope_type in('location_category','responsible')))
        and(p.scope_type<>'location'or p.location_id=coalesce(p_location_id,p.location_id)))
      then raise exception'La distribución no corresponde a una jerarquía aprobada.';end if;
    end if;
    insert into public.bi_budget_versions(budget_id,company_id,version,name,description,metric_code,period_type,period_start,period_end,
      scope_type,location_id,collaborator_id,category_id,value,unit_code,owner_user_id,budget_kind,parent_version_id,replaces_version_id)
    values(b,p_company_id,v_number,trim(p_name),nullif(trim(coalesce(p_description,'')),''),p_metric_code,p_period_type,
      date_trunc(case p_period_type when'monthly'then'month'when'quarterly'then'quarter'else'year'end,p_period_start)::date,v_end,
      p_scope_type,p_location_id,p_collaborator_id,p_category_id,p_value,case when p_metric_code='units_sold'then'unit'else upper(p_unit_code)end,coalesce(p_owner_user_id,auth.uid()),v_kind,p_parent_version_id,p_replace_version_id)
    returning*into v;
    insert into public.bi_budget_version_events(company_id,version_id,action,reason,snapshot)values(p_company_id,v.id,'created',trim(p_reason),to_jsonb(v));
  else
    select*into v from public.bi_budget_versions where id=p_version_id and company_id=p_company_id for update;
    if not found or v.status<>'draft'then raise exception'El borrador no está disponible para modificación.';end if;
    update public.bi_budget_versions set name=trim(p_name),description=nullif(trim(coalesce(p_description,'')),''),metric_code=p_metric_code,
      period_type=p_period_type,period_start=date_trunc(case p_period_type when'monthly'then'month'when'quarterly'then'quarter'else'year'end,p_period_start)::date,
      period_end=v_end,scope_type=p_scope_type,location_id=p_location_id,collaborator_id=p_collaborator_id,category_id=p_category_id,
      value=p_value,unit_code=case when p_metric_code='units_sold'then'unit'else upper(p_unit_code)end,owner_user_id=coalesce(p_owner_user_id,owner_user_id),updated_at=now()
    where id=v.id returning*into v;
    insert into public.bi_budget_version_events(company_id,version_id,action,reason,snapshot)values(p_company_id,v.id,'modified',trim(p_reason),to_jsonb(v));
  end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'bi.budget_draft_saved','bi_budget_version',v.id,jsonb_build_object('version',v.version,'reason',trim(p_reason)));
  return to_jsonb(v);
end$$;
