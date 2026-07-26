-- Flujos operativos v2: baja explícita y prevalidación de nómina.

create or replace function public.terminate_collaborator(
  p_company_id uuid,p_collaborator_id uuid,p_terminated_at date,p_reason text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_collaborator public.collaborators%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_collaborators') then raise exception 'No autorizado para dar de baja colaboradores.'; end if;
  if p_terminated_at is null or nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'La fecha y el motivo de baja son obligatorios.'; end if;
  select * into v_collaborator from public.collaborators where id=p_collaborator_id and company_id=p_company_id for update;
  if not found then raise exception 'Colaborador no disponible.'; end if;
  if v_collaborator.employment_status<>'active' then raise exception 'El colaborador ya está dado de baja.'; end if;
  if p_terminated_at<v_collaborator.hired_at then raise exception 'La fecha de baja no puede ser anterior al ingreso.'; end if;
  update public.collaborators set employment_status='inactive',terminated_at=p_terminated_at where id=v_collaborator.id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'collaborator.terminated','collaborator',v_collaborator.id,jsonb_build_object('terminated_at',p_terminated_at,'reason',trim(p_reason)));
  return public.get_collaborator_profile(p_company_id,v_collaborator.id);
end $$;

create or replace function public.get_payroll_preflight(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_frequency text;v_start date;v_end date;v_period_days numeric;v_included integer;v_missing integer;v_pending integer;v_approved integer;v_total numeric;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collaborators') then raise exception 'No autorizado.'; end if;
  select coalesce((select payment_frequency from public.payroll_schedules where company_id=p_company_id),'weekly') into v_frequency;
  select starts_on,ends_on into v_start,v_end from public.payroll_period_bounds(v_frequency,current_date);
  v_period_days:=(v_end-v_start)+1;
  with candidates as materialized(
    select c.id,c.hired_at,c.terminated_at,h.base_pay_amount
    from public.collaborators c
    left join lateral(select base_pay_amount from public.collaborator_compensation_history h where h.collaborator_id=c.id and h.effective_from<=v_end order by h.effective_from desc limit 1) h on true
    where c.company_id=p_company_id and c.payment_frequency=v_frequency and c.hired_at<=v_end and (c.terminated_at is null or c.terminated_at>=v_start)
  )
  select count(*) filter(where base_pay_amount is not null),count(*) filter(where base_pay_amount is null),coalesce(sum(round(base_pay_amount*((least(v_end,coalesce(terminated_at,v_end))-greatest(v_start,hired_at)+1)::numeric)/v_period_days,2)),0)
    into v_included,v_missing,v_total from candidates;
  select count(*) filter(where m.status='pending'),count(*) filter(where m.status='approved'),v_total+coalesce(sum(case when m.status='approved' and m.direction='addition' then m.amount when m.status='approved' and m.direction='reduction' then -m.amount else 0 end),0)
    into v_pending,v_approved,v_total
    from public.payroll_movements m
    join public.collaborators c on c.id=m.collaborator_id and c.company_id=p_company_id and c.payment_frequency=v_frequency and c.hired_at<=v_end and (c.terminated_at is null or c.terminated_at>=v_start)
    join lateral(select base_pay_amount from public.collaborator_compensation_history h where h.collaborator_id=c.id and h.effective_from<=v_end order by h.effective_from desc limit 1) h on true
    where m.company_id=p_company_id and m.effective_on between v_start and v_end;
  return jsonb_build_object('included',coalesce(v_included,0),'missing_compensation',coalesce(v_missing,0),'pending_movements',coalesce(v_pending,0),'approved_movements',coalesce(v_approved,0),'estimated_total',coalesce(v_total,0));
end $$;

create or replace function public.start_current_payroll(p_company_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_frequency text;v_start date;v_end date;v_period public.payroll_periods%rowtype;v_preflight jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_payroll_runs') then raise exception 'No autorizado para preparar la nómina.'; end if;
  v_preflight:=public.get_payroll_preflight(p_company_id);
  if coalesce((v_preflight->>'missing_compensation')::integer,0)>0 then raise exception 'Hay colaboradores sin pago vigente. Corrige los expedientes antes de preparar la nómina.'; end if;
  select coalesce((select payment_frequency from public.payroll_schedules where company_id=p_company_id),'weekly') into v_frequency;
  select starts_on,ends_on into v_start,v_end from public.payroll_period_bounds(v_frequency,current_date);
  perform pg_advisory_xact_lock(hashtextextended(concat_ws('|',p_company_id::text,v_frequency,v_start::text,v_end::text),109));
  select * into v_period from public.payroll_periods where company_id=p_company_id and payment_frequency=v_frequency and starts_on=v_start and ends_on=v_end for update;
  if not found then
    if exists(select 1 from public.payroll_periods where company_id=p_company_id and status<>'paid' and daterange(starts_on,ends_on,'[]') && daterange(v_start,v_end,'[]')) then raise exception 'Ya existe una nómina abierta que se cruza con el periodo vigente.'; end if;
    insert into public.payroll_periods(company_id,payment_frequency,starts_on,ends_on,payment_date) values(p_company_id,v_frequency,v_start,v_end,v_end) returning * into v_period;
  end if;
  if v_period.status='draft' then return public.prepare_payroll_period(p_company_id,v_period.id); end if;
  return public.get_payroll_period(p_company_id,v_period.id);
end $$;

grant execute on function public.terminate_collaborator(uuid,uuid,date,text),public.get_payroll_preflight(uuid),public.start_current_payroll(uuid) to authenticated;
