-- Revisión de incidencias: aprobación por lote y trazabilidad del cálculo en nómina.

alter table public.collaborator_time_off
  add column if not exists payroll_movement_id uuid references public.payroll_movements(id) on delete set null;
create unique index if not exists collaborator_time_off_payroll_movement_uidx
  on public.collaborator_time_off(payroll_movement_id) where payroll_movement_id is not null;

alter table public.payroll_period_line_concepts
  add column if not exists calculation_metadata jsonb not null default '{}'::jsonb;

create or replace function public.save_payroll_incidents_batch(
  p_company_id uuid,p_incidents jsonb,p_approve boolean default false
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_item jsonb;v_kind text;v_collaborator_id uuid;v_effective_on date;v_starts_on date;v_ends_on date;v_units numeric;v_multiplier numeric;v_paid boolean;v_base numeric;v_daily_rate numeric;v_hourly_rate numeric;v_amount numeric;v_direction text;v_count integer:=0;v_settings public.payroll_incidence_settings%rowtype;v_movement_id uuid;
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
      values(p_company_id,v_collaborator_id,'overtime','addition',v_effective_on,v_units,v_amount,nullif(trim(v_item->>'description'),''),case when p_approve then 'approved' else 'pending' end,case when p_approve then auth.uid() end,case when p_approve then now() end,jsonb_build_object('hourly_rate',v_hourly_rate,'hours',v_units,'multiplier',v_multiplier,'formula','hourly_rate × hours × multiplier'))
      returning id into v_movement_id;
    else
      v_starts_on:=nullif(v_item->>'starts_on','')::date;v_ends_on:=nullif(v_item->>'ends_on','')::date;v_units:=nullif(v_item->>'days','')::numeric;v_paid:=coalesce((v_item->>'paid')::boolean,false);
      if v_starts_on is null or v_ends_on is null or v_ends_on<v_starts_on or coalesce(v_units,0)<=0 then raise exception 'La inasistencia requiere rango y días válidos.'; end if;
      select base_pay_amount into v_base from public.collaborator_compensation_history where collaborator_id=v_collaborator_id and effective_from<=v_starts_on order by effective_from desc limit 1;
      if v_base is null then raise exception 'Un colaborador no tiene pago vigente para la fecha de inasistencia.'; end if;
      v_daily_rate:=round(v_base/v_settings.payable_days_per_period,4);v_amount:=case when v_paid then 0 else round(v_daily_rate*v_units,2) end;v_direction:=case when v_paid then 'informational' else 'reduction' end;
      insert into public.payroll_movements(company_id,collaborator_id,movement_type,direction,effective_on,units,amount,description,status,approved_by,approved_at,calculation_metadata)
      values(p_company_id,v_collaborator_id,'absence',v_direction,v_starts_on,v_units,v_amount,nullif(trim(v_item->>'description'),''),case when p_approve then 'approved' else 'pending' end,case when p_approve then auth.uid() end,case when p_approve then now() end,jsonb_build_object('daily_rate',v_daily_rate,'days',v_units,'paid',v_paid,'formula',case when v_paid then 'paid absence; no deduction' else 'daily_rate × days' end))
      returning id into v_movement_id;
      insert into public.collaborator_time_off(company_id,collaborator_id,kind,starts_on,ends_on,days,status,affects_payment,notes,approved_by,approved_at,payroll_movement_id)
      values(p_company_id,v_collaborator_id,'absence',v_starts_on,v_ends_on,v_units,case when p_approve then 'approved' else 'pending' end,not v_paid,nullif(trim(v_item->>'description'),''),case when p_approve then auth.uid() end,case when p_approve then now() end,v_movement_id);
    end if;
    v_count:=v_count+1;
  end loop;
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)
  values(p_company_id,auth.uid(),'payroll.incidents_saved','payroll_incident_batch',jsonb_build_object('count',v_count,'approved',p_approve));
  return jsonb_build_object('saved',v_count);
end $$;

create or replace function public.get_pending_payroll_incidents(
  p_company_id uuid,p_page integer default 1,p_page_size integer default 50
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collaborators') then raise exception 'No autorizado.'; end if;
  with filtered as materialized(
    select m.id,m.collaborator_id,c.code collaborator_code,c.display_name collaborator_name,m.movement_type,m.effective_on,m.amount,m.units,m.description,m.calculation_metadata,t.starts_on,t.ends_on,t.days,
      case when m.movement_type='absence' then coalesce((m.calculation_metadata->>'paid')::boolean,false) else null end paid
    from public.payroll_movements m
    join public.collaborators c on c.id=m.collaborator_id and c.company_id=p_company_id
    left join public.collaborator_time_off t on t.payroll_movement_id=m.id
    where m.company_id=p_company_id and m.status='pending' and m.movement_type in ('overtime','absence')
  ),paged as (
    select * from filtered order by effective_on asc,collaborator_name,id limit v_size offset (v_page-1)*v_size
  )
  select (select count(*) from filtered),coalesce(jsonb_agg(to_jsonb(paged) order by effective_on,collaborator_name,id),'[]'::jsonb) into v_total,v_items from paged;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',coalesce(v_total,0)));
end $$;

create or replace function public.resolve_payroll_incidents_batch(
  p_company_id uuid,p_movement_ids uuid[],p_action text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_action text:=lower(trim(coalesce(p_action,'')));v_movement public.payroll_movements%rowtype;v_count integer:=0;v_expected integer:=coalesce(cardinality(p_movement_ids),0);v_found integer;v_time_off_matches integer;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_payroll_movements') then raise exception 'No autorizado para resolver incidencias.'; end if;
  if v_action not in ('approve','reject') or v_expected not between 1 and 100 then raise exception 'Selecciona entre 1 y 100 incidencias y una acción válida.'; end if;
  select count(*) into v_found from public.payroll_movements where company_id=p_company_id and id=any(p_movement_ids) and movement_type in ('overtime','absence') and status='pending';
  if v_found<>v_expected then raise exception 'Una o más incidencias ya no están pendientes o no están disponibles.'; end if;
  for v_movement in select * from public.payroll_movements where company_id=p_company_id and id=any(p_movement_ids) and movement_type in ('overtime','absence') and status='pending' for update loop
    update public.payroll_movements set status=case when v_action='approve' then 'approved' else 'rejected' end,approved_by=case when v_action='approve' then auth.uid() else null end,approved_at=case when v_action='approve' then now() else null end where id=v_movement.id;
    if v_movement.movement_type='absence' then
      update public.collaborator_time_off set status=case when v_action='approve' then 'approved' else 'rejected' end,approved_by=case when v_action='approve' then auth.uid() else null end,approved_at=case when v_action='approve' then now() else null end where payroll_movement_id=v_movement.id;
      if not found then
        select count(*) into v_time_off_matches from public.collaborator_time_off where company_id=p_company_id and collaborator_id=v_movement.collaborator_id and kind='absence' and status='pending' and starts_on=v_movement.effective_on and days=v_movement.units;
        if v_time_off_matches=1 then
          update public.collaborator_time_off set status=case when v_action='approve' then 'approved' else 'rejected' end,approved_by=case when v_action='approve' then auth.uid() else null end,approved_at=case when v_action='approve' then now() else null end,payroll_movement_id=v_movement.id
          where id=(select id from public.collaborator_time_off where company_id=p_company_id and collaborator_id=v_movement.collaborator_id and kind='absence' and status='pending' and starts_on=v_movement.effective_on and days=v_movement.units limit 1);
        end if;
      end if;
    end if;
    v_count:=v_count+1;
  end loop;
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)
  values(p_company_id,auth.uid(),'payroll.incidents_'||v_action||'d','payroll_incident_batch',jsonb_build_object('count',v_count,'movement_ids',p_movement_ids));
  return jsonb_build_object('resolved',v_count,'action',v_action);
end $$;

create or replace function public.prepare_payroll_period(p_company_id uuid,p_period_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_period public.payroll_periods%rowtype;v_period_days numeric;v_line record;v_base numeric;v_active_start date;v_active_end date;v_active_days numeric;v_line_id uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_payroll_runs') then raise exception 'No autorizado para preparar la nómina.'; end if;
  select * into v_period from public.payroll_periods where id=p_period_id and company_id=p_company_id for update;
  if not found or v_period.status<>'draft' then raise exception 'El periodo debe estar en preparación.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_period.id::text,93));
  delete from public.payroll_period_lines where payroll_period_id=v_period.id;
  v_period_days:=(v_period.ends_on-v_period.starts_on)+1;
  for v_line in select c.*,h.base_pay_amount from public.collaborators c join lateral(select base_pay_amount from public.collaborator_compensation_history h where h.collaborator_id=c.id and h.effective_from<=v_period.ends_on order by h.effective_from desc limit 1) h on true where c.company_id=p_company_id and c.payment_frequency=v_period.payment_frequency and c.hired_at<=v_period.ends_on and (c.terminated_at is null or c.terminated_at>=v_period.starts_on) loop
    v_active_start:=greatest(v_period.starts_on,v_line.hired_at);v_active_end:=least(v_period.ends_on,coalesce(v_line.terminated_at,v_period.ends_on));v_active_days:=(v_active_end-v_active_start)+1;
    v_base:=round(v_line.base_pay_amount*v_active_days/v_period_days,2);
    insert into public.payroll_period_lines(company_id,payroll_period_id,collaborator_id,collaborator_name_snapshot,base_pay_snapshot,additions_total,reductions_total,total_pay)
    values(p_company_id,v_period.id,v_line.id,v_line.display_name,v_base,0,0,v_base) returning id into v_line_id;
    insert into public.payroll_period_line_concepts(company_id,payroll_period_line_id,concept_code,label,direction,amount,source_date)
    values(p_company_id,v_line_id,'base_pay','Pago base','addition',v_base,v_period.ends_on);
    insert into public.payroll_period_line_concepts(company_id,payroll_period_line_id,payroll_movement_id,concept_code,label,direction,amount,units,source_date,calculation_metadata)
    select p_company_id,v_line_id,m.id,m.movement_type,
      case m.movement_type when 'overtime' then 'Horas extra' when 'bonus' then 'Bono' when 'aguinaldo' then 'Aguinaldo' when 'vacation_premium' then 'Prima vacacional' when 'absence' then 'Ausencia' else 'Ajuste' end,
      m.direction,m.amount,m.units,m.effective_on,coalesce(m.calculation_metadata,'{}'::jsonb)
    from public.payroll_movements m where m.company_id=p_company_id and m.collaborator_id=v_line.id and m.status='approved' and m.effective_on between v_period.starts_on and v_period.ends_on;
    update public.payroll_period_lines l set additions_total=coalesce((select sum(amount) from public.payroll_period_line_concepts c where c.payroll_period_line_id=l.id and c.direction='addition' and c.concept_code<>'base_pay'),0),reductions_total=coalesce((select sum(amount) from public.payroll_period_line_concepts c where c.payroll_period_line_id=l.id and c.direction='reduction'),0),total_pay=l.base_pay_snapshot+coalesce((select sum(amount) from public.payroll_period_line_concepts c where c.payroll_period_line_id=l.id and c.direction='addition' and c.concept_code<>'base_pay'),0)-coalesce((select sum(amount) from public.payroll_period_line_concepts c where c.payroll_period_line_id=l.id and c.direction='reduction'),0) where l.id=v_line_id;
  end loop;
  update public.payroll_periods set status='reviewing',prepared_by=auth.uid(),prepared_at=now() where id=v_period.id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'payroll.period_prepared','payroll_period',v_period.id,jsonb_build_object('starts_on',v_period.starts_on,'ends_on',v_period.ends_on));
  return public.get_payroll_period(p_company_id,v_period.id);
end $$;

grant execute on function public.get_pending_payroll_incidents(uuid,integer,integer),public.resolve_payroll_incidents_batch(uuid,uuid[],text) to authenticated;
