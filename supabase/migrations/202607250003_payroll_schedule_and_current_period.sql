-- La nómina se opera por el periodo vigente calculado desde un calendario de empresa.
-- Los periodos conservan el historial, pero no se capturan manualmente desde la aplicación.

create table if not exists public.payroll_schedules(
  company_id uuid primary key references public.companies(id) on delete cascade,
  payment_frequency text not null default 'weekly' check(payment_frequency in ('weekly','biweekly','monthly')),
  updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_at timestamptz not null default now()
);

drop trigger if exists payroll_schedules_updated_at on public.payroll_schedules;
create trigger payroll_schedules_updated_at before update on public.payroll_schedules for each row execute function public.set_updated_at();

create or replace function public.payroll_period_bounds(p_frequency text,p_on date default current_date)
returns table(starts_on date,ends_on date) language sql stable set search_path=public as $$
  select
    case lower(trim(p_frequency))
      when 'weekly' then date_trunc('week',p_on)::date
      when 'biweekly' then case when extract(day from p_on)<=15 then date_trunc('month',p_on)::date else (date_trunc('month',p_on)::date+interval '15 days')::date end
      when 'monthly' then date_trunc('month',p_on)::date
    end,
    case lower(trim(p_frequency))
      when 'weekly' then (date_trunc('week',p_on)::date+interval '6 days')::date
      when 'biweekly' then case when extract(day from p_on)<=15 then (date_trunc('month',p_on)::date+interval '14 days')::date else (date_trunc('month',p_on)::date+interval '1 month - 1 day')::date end
      when 'monthly' then (date_trunc('month',p_on)::date+interval '1 month - 1 day')::date
    end;
$$;

create or replace function public.get_payroll_schedule(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_frequency text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collaborators') then raise exception 'No autorizado.'; end if;
  select payment_frequency into v_frequency from public.payroll_schedules where company_id=p_company_id;
  return jsonb_build_object('payment_frequency',coalesce(v_frequency,'weekly'));
end $$;

create or replace function public.save_payroll_schedule(p_company_id uuid,p_payment_frequency text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_frequency text:=lower(trim(coalesce(p_payment_frequency,'')));v_start date;v_end date;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_payroll_runs') then raise exception 'No autorizado para configurar la nómina.'; end if;
  if v_frequency not in ('weekly','biweekly','monthly') then raise exception 'Periodicidad de pago inválida.'; end if;
  select starts_on,ends_on into v_start,v_end from public.payroll_period_bounds(v_frequency,current_date);
  if exists(
    select 1 from public.payroll_periods
    where company_id=p_company_id and status in ('draft','reviewing','approved')
      and payment_frequency<>v_frequency and daterange(starts_on,ends_on,'[]') && daterange(v_start,v_end,'[]')
  ) then raise exception 'Hay una nómina vigente abierta con otra periodicidad. Ciérrala antes de cambiar la configuración.'; end if;
  insert into public.payroll_schedules(company_id,payment_frequency,updated_by)
  values(p_company_id,v_frequency,auth.uid())
  on conflict(company_id) do update set payment_frequency=excluded.payment_frequency,updated_by=auth.uid(),updated_at=now();
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'payroll.schedule_saved','payroll_schedule',p_company_id,jsonb_build_object('payment_frequency',v_frequency));
  return public.get_payroll_schedule(p_company_id);
end $$;

create or replace function public.get_current_payroll_period(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_frequency text;v_start date;v_end date;v_period public.payroll_periods%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collaborators') then raise exception 'No autorizado.'; end if;
  select coalesce((select payment_frequency from public.payroll_schedules where company_id=p_company_id),'weekly') into v_frequency;
  select starts_on,ends_on into v_start,v_end from public.payroll_period_bounds(v_frequency,current_date);
  select * into v_period from public.payroll_periods
  where company_id=p_company_id and payment_frequency=v_frequency and starts_on=v_start and ends_on=v_end;
  return jsonb_build_object(
    'period',case when v_period.id is not null then to_jsonb(v_period) else null end,
    'proposed',jsonb_build_object('payment_frequency',v_frequency,'starts_on',v_start,'ends_on',v_end,'payment_date',v_end)
  );
end $$;

create or replace function public.start_current_payroll(p_company_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_frequency text;v_start date;v_end date;v_period public.payroll_periods%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_payroll_runs') then raise exception 'No autorizado para preparar la nómina.'; end if;
  select coalesce((select payment_frequency from public.payroll_schedules where company_id=p_company_id),'weekly') into v_frequency;
  select starts_on,ends_on into v_start,v_end from public.payroll_period_bounds(v_frequency,current_date);
  perform pg_advisory_xact_lock(hashtextextended(concat_ws('|',p_company_id::text,v_frequency,v_start::text,v_end::text),109));
  select * into v_period from public.payroll_periods
  where company_id=p_company_id and payment_frequency=v_frequency and starts_on=v_start and ends_on=v_end
  for update;
  if not found then
    if exists(
      select 1 from public.payroll_periods
      where company_id=p_company_id and status<>'paid' and daterange(starts_on,ends_on,'[]') && daterange(v_start,v_end,'[]')
    ) then raise exception 'Ya existe una nómina abierta que se cruza con el periodo vigente.'; end if;
    insert into public.payroll_periods(company_id,payment_frequency,starts_on,ends_on,payment_date)
    values(p_company_id,v_frequency,v_start,v_end,v_end)
    returning * into v_period;
  end if;
  if v_period.status='draft' then return public.prepare_payroll_period(p_company_id,v_period.id); end if;
  return public.get_payroll_period(p_company_id,v_period.id);
end $$;

alter table public.payroll_schedules enable row level security;
drop policy if exists payroll_schedules_read on public.payroll_schedules;
create policy payroll_schedules_read on public.payroll_schedules for select to authenticated using(public.has_company_permission(company_id,'view_collaborators'));

revoke all on public.payroll_schedules from authenticated;
revoke execute on function public.save_payroll_period(uuid,uuid,text,date,date,date,text) from authenticated;
grant execute on function public.get_payroll_schedule(uuid),public.save_payroll_schedule(uuid,text),public.get_current_payroll_period(uuid),public.start_current_payroll(uuid) to authenticated;
