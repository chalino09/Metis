-- Captura operativa de incidencias: fórmulas auditables, no importes manuales.

alter table public.collaborators add column if not exists payment_method text not null default 'unspecified'
  check(payment_method in ('unspecified','transfer','cash','other'));
alter table public.payroll_movements add column if not exists calculation_metadata jsonb not null default '{}'::jsonb;

create table if not exists public.payroll_incidence_settings(
  company_id uuid primary key references public.companies(id) on delete cascade,
  payable_days_per_period numeric(8,2) not null check(payable_days_per_period>0),
  hours_per_workday numeric(8,2) not null check(hours_per_workday>0),
  overtime_multipliers numeric[] not null check(cardinality(overtime_multipliers)>0),
  updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_at timestamptz not null default now(),
  check(0 < all(overtime_multipliers))
);

drop trigger if exists payroll_incidence_settings_updated_at on public.payroll_incidence_settings;
create trigger payroll_incidence_settings_updated_at before update on public.payroll_incidence_settings for each row execute function public.set_updated_at();

create or replace function public.save_collaborator_payment_method(
  p_company_id uuid,p_collaborator_id uuid,p_payment_method text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_method text:=lower(trim(coalesce(p_payment_method,'')));v_collaborator public.collaborators%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_collaborators') then raise exception 'No autorizado para actualizar la forma de pago.'; end if;
  if v_method not in ('unspecified','transfer','cash','other') then raise exception 'Forma de pago inválida.'; end if;
  update public.collaborators set payment_method=v_method where id=p_collaborator_id and company_id=p_company_id returning * into v_collaborator;
  if not found then raise exception 'Colaborador no disponible.'; end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'collaborator.payment_method_saved','collaborator',v_collaborator.id,jsonb_build_object('payment_method',v_method));
  return public.get_collaborator_profile(p_company_id,v_collaborator.id);
end $$;

create or replace function public.get_payroll_operational_settings(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_settings public.payroll_incidence_settings%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collaborators') then raise exception 'No autorizado.'; end if;
  select * into v_settings from public.payroll_incidence_settings where company_id=p_company_id;
  return jsonb_build_object(
    'payable_days_per_period',v_settings.payable_days_per_period,
    'hours_per_workday',v_settings.hours_per_workday,
    'overtime_multipliers',coalesce(to_jsonb(v_settings.overtime_multipliers),'[]'::jsonb)
  );
end $$;

create or replace function public.save_payroll_operational_configuration(
  p_company_id uuid,p_payment_frequency text,p_payable_days_per_period numeric,p_hours_per_workday numeric,p_overtime_multipliers numeric[]
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_frequency text:=lower(trim(coalesce(p_payment_frequency,'')));v_start date;v_end date;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_payroll_runs') then raise exception 'No autorizado para configurar la nómina.'; end if;
  if v_frequency not in ('weekly','biweekly','monthly') then raise exception 'Periodicidad de pago inválida.'; end if;
  if coalesce(p_payable_days_per_period,0)<=0 or coalesce(p_hours_per_workday,0)<=0 or coalesce(cardinality(p_overtime_multipliers),0)=0 or exists(select 1 from unnest(p_overtime_multipliers) as multiplier where multiplier<=0) then raise exception 'Define días pagables, horas por jornada y multiplicadores válidos.'; end if;
  select starts_on,ends_on into v_start,v_end from public.payroll_period_bounds(v_frequency,current_date);
  if exists(select 1 from public.payroll_periods where company_id=p_company_id and status in ('draft','reviewing','approved') and payment_frequency<>v_frequency and daterange(starts_on,ends_on,'[]') && daterange(v_start,v_end,'[]')) then raise exception 'Hay una nómina vigente abierta con otra periodicidad. Ciérrala antes de cambiar la configuración.'; end if;
  insert into public.payroll_schedules(company_id,payment_frequency,updated_by) values(p_company_id,v_frequency,auth.uid())
  on conflict(company_id) do update set payment_frequency=excluded.payment_frequency,updated_by=auth.uid(),updated_at=now();
  insert into public.payroll_incidence_settings(company_id,payable_days_per_period,hours_per_workday,overtime_multipliers,updated_by)
  values(p_company_id,p_payable_days_per_period,p_hours_per_workday,p_overtime_multipliers,auth.uid())
  on conflict(company_id) do update set payable_days_per_period=excluded.payable_days_per_period,hours_per_workday=excluded.hours_per_workday,overtime_multipliers=excluded.overtime_multipliers,updated_by=auth.uid(),updated_at=now();
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'payroll.operational_configuration_saved','payroll_schedule',p_company_id,jsonb_build_object('payment_frequency',v_frequency,'payable_days_per_period',p_payable_days_per_period,'hours_per_workday',p_hours_per_workday,'overtime_multipliers',p_overtime_multipliers));
  return public.get_payroll_schedule(p_company_id)||public.get_payroll_operational_settings(p_company_id);
end $$;

create or replace function public.save_payroll_incidents_batch(
  p_company_id uuid,p_incidents jsonb,p_approve boolean default false
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_item jsonb;v_kind text;v_collaborator_id uuid;v_effective_on date;v_starts_on date;v_ends_on date;v_units numeric;v_multiplier numeric;v_paid boolean;v_base numeric;v_daily_rate numeric;v_hourly_rate numeric;v_amount numeric;v_direction text;v_count integer:=0;v_settings public.payroll_incidence_settings%rowtype;v_time_off_id uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_payroll_movements') then raise exception 'No autorizado para registrar incidencias.'; end if;
  if jsonb_typeof(coalesce(p_incidents,'null'::jsonb))<>'array' or jsonb_array_length(p_incidents) not between 1 and 100 then raise exception 'Agrega entre 1 y 100 incidencias.'; end if;
  select * into v_settings from public.payroll_incidence_settings where company_id=p_company_id;
  if not found then raise exception 'Configura los días pagables, horas por jornada y multiplicadores antes de capturar incidencias.'; end if;
  for v_item in select value from jsonb_array_elements(p_incidents) loop
    v_kind:=lower(trim(coalesce(v_item->>'kind','')));v_collaborator_id:=nullif(v_item->>'collaborator_id','')::uuid;
    if v_kind not in ('overtime','absence') or v_collaborator_id is null or not exists(select 1 from public.collaborators where id=v_collaborator_id and company_id=p_company_id) then raise exception 'Una incidencia contiene un colaborador o tipo inválido.'; end if;
    if v_kind='overtime' then
      v_effective_on:=nullif(v_item->>'effective_on','')::date;v_units:=nullif(v_item->>'hours','')::numeric;v_multiplier:=nullif(v_item->>'multiplier','')::numeric;
      if v_effective_on is null or coalesce(v_units,0)<=0 or v_multiplier is null or not v_multiplier=any(v_settings.overtime_multipliers) then raise exception 'Las horas extra requieren fecha, horas y un multiplicador autorizado.'; end if;
      select base_pay_amount into v_base from public.collaborator_compensation_history where collaborator_id=v_collaborator_id and effective_from<=v_effective_on order by effective_from desc limit 1;
      if v_base is null then raise exception 'Un colaborador no tiene pago vigente para la fecha de horas extra.'; end if;
      v_daily_rate:=round(v_base/v_settings.payable_days_per_period,4);v_hourly_rate:=round(v_daily_rate/v_settings.hours_per_workday,4);v_amount:=round(v_hourly_rate*v_units*v_multiplier,2);
      insert into public.payroll_movements(company_id,collaborator_id,movement_type,direction,effective_on,units,amount,description,status,approved_by,approved_at,calculation_metadata)
      values(p_company_id,v_collaborator_id,'overtime','addition',v_effective_on,v_units,v_amount,nullif(trim(v_item->>'description'),''),case when p_approve then 'approved' else 'pending' end,case when p_approve then auth.uid() end,case when p_approve then now() end,jsonb_build_object('hourly_rate',v_hourly_rate,'hours',v_units,'multiplier',v_multiplier,'formula','hourly_rate × hours × multiplier'));
    else
      v_starts_on:=nullif(v_item->>'starts_on','')::date;v_ends_on:=nullif(v_item->>'ends_on','')::date;v_units:=nullif(v_item->>'days','')::numeric;v_paid:=coalesce((v_item->>'paid')::boolean,false);
      if v_starts_on is null or v_ends_on is null or v_ends_on<v_starts_on or coalesce(v_units,0)<=0 then raise exception 'La inasistencia requiere rango y días válidos.'; end if;
      select base_pay_amount into v_base from public.collaborator_compensation_history where collaborator_id=v_collaborator_id and effective_from<=v_starts_on order by effective_from desc limit 1;
      if v_base is null then raise exception 'Un colaborador no tiene pago vigente para la fecha de inasistencia.'; end if;
      v_daily_rate:=round(v_base/v_settings.payable_days_per_period,4);v_amount:=case when v_paid then 0 else round(v_daily_rate*v_units,2) end;v_direction:=case when v_paid then 'informational' else 'reduction' end;
      insert into public.payroll_movements(company_id,collaborator_id,movement_type,direction,effective_on,units,amount,description,status,approved_by,approved_at,calculation_metadata)
      values(p_company_id,v_collaborator_id,'absence',v_direction,v_starts_on,v_units,v_amount,nullif(trim(v_item->>'description'),''),case when p_approve then 'approved' else 'pending' end,case when p_approve then auth.uid() end,case when p_approve then now() end,jsonb_build_object('daily_rate',v_daily_rate,'days',v_units,'paid',v_paid,'formula',case when v_paid then 'paid absence; no deduction' else 'daily_rate × days' end));
      insert into public.collaborator_time_off(company_id,collaborator_id,kind,starts_on,ends_on,days,status,affects_payment,notes,approved_by,approved_at)
      values(p_company_id,v_collaborator_id,'absence',v_starts_on,v_ends_on,v_units,case when p_approve then 'approved' else 'pending' end,not v_paid,nullif(trim(v_item->>'description'),''),case when p_approve then auth.uid() end,case when p_approve then now() end)
      returning id into v_time_off_id;
    end if;
    v_count:=v_count+1;
  end loop;
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)
  values(p_company_id,auth.uid(),'payroll.incidents_saved','payroll_incident_batch',jsonb_build_object('count',v_count,'approved',p_approve));
  return jsonb_build_object('saved',v_count);
end $$;

alter table public.payroll_incidence_settings enable row level security;
drop policy if exists payroll_incidence_settings_read on public.payroll_incidence_settings;
create policy payroll_incidence_settings_read on public.payroll_incidence_settings for select to authenticated using(public.has_company_permission(company_id,'view_collaborators'));
revoke all on public.payroll_incidence_settings from authenticated;
grant execute on function public.save_collaborator_payment_method(uuid,uuid,text),public.get_payroll_operational_settings(uuid),public.save_payroll_operational_configuration(uuid,text,numeric,numeric,numeric[]),public.save_payroll_incidents_batch(uuid,jsonb,boolean) to authenticated;
