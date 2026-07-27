-- Desglose temporal de metas trimestrales y anuales.
-- El presupuesto principal sigue siendo la única meta acumulada; las partidas
-- mensuales sólo explican su distribución y nunca se agregan como otro presupuesto.

create table public.bi_budget_monthly_allocations(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  version_id uuid not null references public.bi_budget_versions(id) on delete cascade,
  month_start date not null check(month_start=date_trunc('month',month_start)::date),
  value numeric(20,6) not null check(value>=0),
  created_at timestamptz not null default now(),
  unique(version_id,month_start)
);
create index bi_budget_monthly_allocations_lookup_idx on public.bi_budget_monthly_allocations(version_id,month_start);
alter table public.bi_budget_monthly_allocations enable row level security;
create policy bi_budget_monthly_allocations_no_direct_access on public.bi_budget_monthly_allocations using(false);

create or replace function public.bi_get_budget_monthly_allocations(p_company_id uuid,p_version_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if not exists(select 1 from public.bi_budget_versions v where v.id=p_version_id and v.company_id=p_company_id and public.bi_can_view_budget_version(v.id))then
    raise exception'Presupuesto no disponible.';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('month_start',month_start,'value',value)order by month_start)
    from public.bi_budget_monthly_allocations where version_id=p_version_id),'[]'::jsonb);
end$$;

-- Se conserva la función Fase 5 como núcleo de versiones, permisos, solapamientos
-- y auditoría. Esta sobrecarga valida y persiste el desglose mensual en la misma transacción.
alter function public.bi_save_budget_draft(uuid,uuid,text,text,text,text,date,text,uuid,uuid,uuid,numeric,text,uuid,uuid,uuid,text)
  rename to bi_save_budget_draft_phase5;

create function public.bi_save_budget_draft(
  p_company_id uuid,p_version_id uuid,p_name text,p_description text,p_metric_code text,
  p_period_type text,p_period_start date,p_scope_type text,p_location_id uuid,p_collaborator_id uuid,
  p_category_id uuid,p_value numeric,p_unit_code text,p_owner_user_id uuid,p_parent_version_id uuid,
  p_replace_version_id uuid,p_reason text,p_monthly_allocations jsonb default '[]'::jsonb
)returns jsonb language plpgsql security definer set search_path=public as $$
declare v_start date;v_end date;expected_count integer;actual_count integer;allocation_total numeric;version_json jsonb;v_version_id uuid;
begin
  if p_period_type='monthly'then v_start:=date_trunc('month',p_period_start)::date;v_end:=(v_start+interval'1 month'-interval'1 day')::date;expected_count:=0;
  elsif p_period_type='quarterly'then v_start:=date_trunc('quarter',p_period_start)::date;v_end:=(v_start+interval'3 months'-interval'1 day')::date;expected_count:=3;
  elsif p_period_type='annual'then v_start:=date_trunc('year',p_period_start)::date;v_end:=(v_start+interval'1 year'-interval'1 day')::date;expected_count:=12;
  else raise exception'Tipo de periodo inválido.';end if;
  if jsonb_typeof(p_monthly_allocations)<>'array'then raise exception'La distribución mensual es inválida.';end if;
  if expected_count=0 and jsonb_array_length(p_monthly_allocations)<>0 then raise exception'Una meta mensual no requiere desglose adicional.';end if;
  if expected_count>0 then
    select count(*),coalesce(sum(x.value),0)into actual_count,allocation_total
    from jsonb_to_recordset(p_monthly_allocations)as x(month_start date,value numeric);
    if actual_count<>expected_count or abs(allocation_total-p_value)>0.005 then raise exception'La distribución mensual debe cubrir cada mes y sumar exactamente la meta total.';end if;
    if exists(
      select 1 from generate_series(v_start,(v_end-date_trunc('month',v_end)::date),'1 month')g(month_start)
      full join jsonb_to_recordset(p_monthly_allocations)as x(month_start date,value numeric)on x.month_start=g.month_start::date
      where x.month_start is null or g.month_start is null or x.month_start<>date_trunc('month',x.month_start)::date or x.value<0
    )then raise exception'Cada distribución debe usar exactamente un mes válido del periodo.';end if;
  end if;
  version_json:=public.bi_save_budget_draft_phase5(p_company_id,p_version_id,p_name,p_description,p_metric_code,p_period_type,p_period_start,p_scope_type,p_location_id,p_collaborator_id,p_category_id,p_value,p_unit_code,p_owner_user_id,p_parent_version_id,p_replace_version_id,p_reason);
  v_version_id:=(version_json->>'id')::uuid;
  delete from public.bi_budget_monthly_allocations a where a.version_id=v_version_id;
  insert into public.bi_budget_monthly_allocations(company_id,version_id,month_start,value)
  select p_company_id,v_version_id,x.month_start,x.value from jsonb_to_recordset(p_monthly_allocations)as x(month_start date,value numeric);
  update public.bi_budget_version_events set snapshot=jsonb_set(snapshot,'{monthly_allocations}',p_monthly_allocations,true)
  where version_id=v_version_id and action in('created','modified') and occurred_at=(select max(e.occurred_at)from public.bi_budget_version_events e where e.version_id=v_version_id);
  return version_json;
end$$;

grant execute on function public.bi_get_budget_monthly_allocations(uuid,uuid) to authenticated;
grant execute on function public.bi_save_budget_draft(uuid,uuid,text,text,text,text,date,text,uuid,uuid,uuid,numeric,text,uuid,uuid,uuid,text,jsonb) to authenticated;
