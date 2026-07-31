-- Mesa semanal de nómina: cuatro movimientos operativos, captura nativa y cálculo auditable.

alter table public.payroll_movements
  drop constraint if exists payroll_movements_movement_type_check;
alter table public.payroll_movements
  add constraint payroll_movements_movement_type_check
  check(movement_type in ('overtime','absence','commission','bonus','aguinaldo','vacation_premium','adjustment'));

alter table public.payroll_incidence_settings
  add column if not exists default_overtime_hourly_rate numeric(12,2) not null default 50
  check(default_overtime_hourly_rate>0);

create or replace function public.get_payroll_operational_settings(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_settings public.payroll_incidence_settings%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collaborators') then raise exception 'No autorizado.'; end if;
  select * into v_settings from public.payroll_incidence_settings where company_id=p_company_id;
  return jsonb_build_object(
    'payable_days_per_period',v_settings.payable_days_per_period,
    'hours_per_workday',v_settings.hours_per_workday,
    'default_overtime_hourly_rate',coalesce(v_settings.default_overtime_hourly_rate,50)
  );
end $$;

drop function if exists public.save_payroll_operational_configuration(uuid,text,numeric,numeric,numeric[]);
drop function if exists public.save_payroll_operational_configuration(uuid,text,numeric,numeric,numeric,numeric[]);
drop function if exists public.save_payroll_operational_configuration(uuid,text,numeric,numeric,numeric);
create function public.save_payroll_operational_configuration(
  p_company_id uuid,p_payment_frequency text,p_payable_days_per_period numeric,p_hours_per_workday numeric,
  p_default_overtime_hourly_rate numeric
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_frequency text:=lower(trim(coalesce(p_payment_frequency,'')));v_start date;v_end date;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_payroll_runs') then raise exception 'No autorizado para configurar la nómina.'; end if;
  if v_frequency not in ('weekly','biweekly','monthly') then raise exception 'Periodicidad de pago inválida.'; end if;
  if coalesce(p_payable_days_per_period,0)<=0 or coalesce(p_hours_per_workday,0)<=0 or coalesce(p_default_overtime_hourly_rate,0)<=0 then
    raise exception 'Define días de trabajo pagados, horas por día y una tarifa predeterminada de hora extra mayores a cero.';
  end if;
  select starts_on,ends_on into v_start,v_end from public.payroll_period_bounds(v_frequency,current_date);
  if exists(select 1 from public.payroll_periods where company_id=p_company_id and status in ('draft','reviewing','approved') and payment_frequency<>v_frequency and daterange(starts_on,ends_on,'[]') && daterange(v_start,v_end,'[]')) then raise exception 'Hay una nómina vigente abierta con otra periodicidad. Ciérrala antes de cambiar la configuración.'; end if;
  insert into public.payroll_schedules(company_id,payment_frequency,updated_by) values(p_company_id,v_frequency,auth.uid())
  on conflict(company_id) do update set payment_frequency=excluded.payment_frequency,updated_by=auth.uid(),updated_at=now();
  insert into public.payroll_incidence_settings(company_id,payable_days_per_period,hours_per_workday,default_overtime_hourly_rate,overtime_multipliers,updated_by)
  values(p_company_id,p_payable_days_per_period,p_hours_per_workday,p_default_overtime_hourly_rate,array[1::numeric],auth.uid())
  on conflict(company_id) do update set
    payable_days_per_period=excluded.payable_days_per_period,
    hours_per_workday=excluded.hours_per_workday,
    default_overtime_hourly_rate=excluded.default_overtime_hourly_rate,
    overtime_multipliers=array[1::numeric],
    updated_by=auth.uid(),updated_at=now();
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(
    p_company_id,auth.uid(),'payroll.operational_configuration_saved','payroll_schedule',p_company_id,
    jsonb_build_object(
      'payment_frequency',v_frequency,'payable_days_per_period',p_payable_days_per_period,
      'hours_per_workday',p_hours_per_workday,'default_overtime_hourly_rate',round(p_default_overtime_hourly_rate,2)
    )
  );
  return public.get_payroll_schedule(p_company_id)||public.get_payroll_operational_settings(p_company_id);
end $$;

create or replace function public.save_payroll_adjustments_batch(
  p_company_id uuid,p_kind text,p_rows jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_kind text:=lower(trim(coalesce(p_kind,'')));v_item jsonb;v_collaborator_id uuid;v_effective_on date;
  v_base numeric;v_daily_rate numeric;v_hourly_rate numeric;v_amount numeric;v_days numeric;v_hours numeric;
  v_default_hourly_rate numeric;v_manual_rate_override boolean;v_reported_minutes integer;
  v_description text;v_movement_id uuid;v_count integer:=0;
  v_settings public.payroll_incidence_settings%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_payroll_movements') then
    raise exception 'No autorizado para registrar movimientos de nómina.';
  end if;
  if v_kind not in ('overtime','absence','commission','bonus') then
    raise exception 'Selecciona un movimiento de nómina válido.';
  end if;
  if jsonb_typeof(coalesce(p_rows,'null'::jsonb))<>'array' or jsonb_array_length(p_rows) not between 1 and 100 then
    raise exception 'Agrega entre 1 y 100 colaboradores.';
  end if;
  select * into v_settings from public.payroll_incidence_settings where company_id=p_company_id;
  if not found then
    raise exception 'Configura los días de trabajo pagados y las horas por día antes de capturar movimientos.';
  end if;

  for v_item in select value from jsonb_array_elements(p_rows) loop
    v_collaborator_id:=nullif(v_item->>'collaborator_id','')::uuid;
    v_effective_on:=nullif(v_item->>'effective_on','')::date;
    v_description:=nullif(trim(v_item->>'description'),'');
    if v_collaborator_id is null or v_effective_on is null or not exists(
      select 1 from public.collaborators
      where id=v_collaborator_id and company_id=p_company_id and employment_status='active'
    ) then raise exception 'Una fila contiene un colaborador o fecha no disponible.'; end if;

    if v_kind='overtime' then
      v_reported_minutes:=nullif(v_item->>'reported_minutes','')::integer;
      v_hours:=nullif(v_item->>'payable_hours','')::numeric;
      v_hourly_rate:=nullif(v_item->>'hourly_rate','')::numeric;
      if coalesce(v_hours,0)<=0 or coalesce(v_hourly_rate,0)<=0 then
        raise exception 'Las horas extra y la tarifa por hora deben ser mayores a cero.';
      end if;
      v_reported_minutes:=coalesce(v_reported_minutes,round(v_hours*60)::integer);
      v_hourly_rate:=round(v_hourly_rate,2);
      v_default_hourly_rate:=round(v_settings.default_overtime_hourly_rate,2);
      v_manual_rate_override:=v_hourly_rate<>v_default_hourly_rate;
      v_amount:=round(v_hourly_rate*v_hours,2);
      insert into public.payroll_movements(
        company_id,collaborator_id,movement_type,direction,effective_on,units,amount,description,status,calculation_metadata
      ) values(
        p_company_id,v_collaborator_id,'overtime','addition',v_effective_on,v_hours,v_amount,v_description,'pending',
        jsonb_build_object(
          'hourly_rate',v_hourly_rate,'default_hourly_rate',v_default_hourly_rate,
          'manual_rate_override',v_manual_rate_override,'reported_minutes',v_reported_minutes,
          'payable_hours',v_hours,'manual_rounding',true,'formula','payable_hours × hourly_rate'
        )
      ) returning id into v_movement_id;
    elsif v_kind='absence' then
      select base_pay_amount into v_base
      from public.collaborator_compensation_history
      where collaborator_id=v_collaborator_id and effective_from<=v_effective_on
      order by effective_from desc limit 1;
      if v_base is null then raise exception 'Un colaborador no tiene sueldo vigente para la fecha capturada.'; end if;
      v_daily_rate:=round(v_base/v_settings.payable_days_per_period,4);
      v_hourly_rate:=round(v_daily_rate/v_settings.hours_per_workday,4);
      v_days:=coalesce(nullif(v_item->>'days','')::numeric,0);
      v_hours:=coalesce(nullif(v_item->>'hours','')::numeric,0);
      if v_days<0 or v_hours<0 or v_days+v_hours<=0 then
        raise exception 'La inasistencia requiere días, horas o ambos.';
      end if;
      v_amount:=round(v_daily_rate*v_days+v_hourly_rate*v_hours,2);
      insert into public.payroll_movements(
        company_id,collaborator_id,movement_type,direction,effective_on,units,amount,description,status,calculation_metadata
      ) values(
        p_company_id,v_collaborator_id,'absence','reduction',v_effective_on,
        case when v_days>0 then v_days else v_hours end,v_amount,v_description,'pending',
        jsonb_build_object(
          'daily_rate',v_daily_rate,'hourly_rate',v_hourly_rate,'days',v_days,'hours',v_hours,'paid',false,
          'formula','daily_rate × days + hourly_rate × hours'
        )
      ) returning id into v_movement_id;
      if v_days>0 then
        insert into public.collaborator_time_off(
          company_id,collaborator_id,kind,starts_on,ends_on,days,status,affects_payment,notes,payroll_movement_id
        ) values(
          p_company_id,v_collaborator_id,'absence',v_effective_on,
          v_effective_on+(greatest(ceil(v_days)::integer,1)-1),v_days,'pending',true,v_description,v_movement_id
        );
      end if;
    else
      v_amount:=nullif(v_item->>'amount','')::numeric;
      if coalesce(v_amount,0)<=0 then
        raise exception 'Las comisiones y bonificaciones requieren un importe mayor a cero.';
      end if;
      insert into public.payroll_movements(
        company_id,collaborator_id,movement_type,direction,effective_on,amount,description,status,calculation_metadata
      ) values(
        p_company_id,v_collaborator_id,v_kind,'addition',v_effective_on,round(v_amount,2),v_description,'pending',
        jsonb_build_object('entered_amount',round(v_amount,2),'formula','importe autorizado')
      ) returning id into v_movement_id;
    end if;
    v_count:=v_count+1;
  end loop;

  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)
  values(
    p_company_id,auth.uid(),'payroll.'||v_kind||'_batch_saved','payroll_movement_batch',
    jsonb_build_object('kind',v_kind,'count',v_count,'status','pending')
  );
  return jsonb_build_object('saved',v_count,'kind',v_kind,'status','pending');
end $$;

create or replace function public.get_payroll_workspace(
  p_company_id uuid,p_query text default null,p_page integer default 1,p_page_size integer default 50
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_frequency text;v_start date;v_end date;v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);v_query text:=nullif(trim(coalesce(p_query,'')),'');
  v_items jsonb;v_total bigint;v_summary jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collaborators') then raise exception 'No autorizado.'; end if;
  select coalesce((select payment_frequency from public.payroll_schedules where company_id=p_company_id),'weekly') into v_frequency;
  select starts_on,ends_on into v_start,v_end from public.payroll_period_bounds(v_frequency,current_date);

  with scope as materialized(
    select c.id,c.code,c.display_name,h.base_pay_amount,
      round(h.base_pay_amount*
        ((least(v_end,coalesce(c.terminated_at,v_end))-greatest(v_start,c.hired_at))+1)::numeric/
        ((v_end-v_start)+1)::numeric,2) base_pay
    from public.collaborators c
    join lateral(
      select base_pay_amount from public.collaborator_compensation_history h
      where h.collaborator_id=c.id and h.effective_from<=v_end
      order by h.effective_from desc limit 1
    ) h on true
    where c.company_id=p_company_id and c.payment_frequency=v_frequency
      and c.hired_at<=v_end and (c.terminated_at is null or c.terminated_at>=v_start)
      and (v_query is null or c.code ilike '%'||v_query||'%' or c.display_name ilike '%'||v_query||'%')
  ),rollup as materialized(
    select m.collaborator_id,
      coalesce(sum(m.amount) filter(where m.movement_type='overtime' and m.status<>'rejected'),0) overtime,
      coalesce(sum(m.amount) filter(where m.movement_type='absence' and m.status<>'rejected'),0) absences,
      coalesce(sum(m.amount) filter(where m.movement_type='commission' and m.status<>'rejected'),0) commissions,
      coalesce(sum(m.amount) filter(where m.movement_type='bonus' and m.status<>'rejected'),0) bonuses,
      count(*) filter(where m.status='pending' and m.movement_type in ('overtime','absence','commission','bonus')) pending_count
    from public.payroll_movements m
    where m.company_id=p_company_id and m.effective_on between v_start and v_end
    group by m.collaborator_id
  ),combined as materialized(
    select s.id,s.code,s.display_name,s.base_pay,
      coalesce(r.overtime,0) overtime,coalesce(r.absences,0) absences,
      coalesce(r.commissions,0) commissions,coalesce(r.bonuses,0) bonuses,
      coalesce(r.pending_count,0) pending_count,
      round(s.base_pay+coalesce(r.overtime,0)-coalesce(r.absences,0)+coalesce(r.commissions,0)+coalesce(r.bonuses,0),2) estimated_pay
    from scope s left join rollup r on r.collaborator_id=s.id
  ),paged as(
    select * from combined order by display_name,id limit v_size offset (v_page-1)*v_size
  )
  select
    (select count(*) from combined),
    coalesce((select jsonb_agg(to_jsonb(paged) order by display_name,id) from paged),'[]'::jsonb),
    jsonb_build_object(
      'base_pay',coalesce((select sum(base_pay) from combined),0),
      'overtime',coalesce((select sum(overtime) from combined),0),
      'absences',coalesce((select sum(absences) from combined),0),
      'commissions',coalesce((select sum(commissions) from combined),0),
      'bonuses',coalesce((select sum(bonuses) from combined),0),
      'estimated_pay',coalesce((select sum(estimated_pay) from combined),0),
      'pending_count',coalesce((select sum(pending_count) from combined),0)
    )
  into v_total,v_items,v_summary;
  return jsonb_build_object(
    'period',jsonb_build_object('payment_frequency',v_frequency,'starts_on',v_start,'ends_on',v_end),
    'items',v_items,'summary',v_summary,
    'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',coalesce(v_total,0))
  );
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
    where m.company_id=p_company_id and m.status='pending'
      and m.movement_type in ('overtime','absence','commission','bonus')
  ),paged as(
    select * from filtered order by effective_on asc,collaborator_name,id limit v_size offset (v_page-1)*v_size
  )
  select (select count(*) from filtered),coalesce(jsonb_agg(to_jsonb(paged) order by effective_on,collaborator_name,id),'[]'::jsonb)
  into v_total,v_items from paged;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',coalesce(v_total,0)));
end $$;

create or replace function public.resolve_payroll_incidents_batch(
  p_company_id uuid,p_movement_ids uuid[],p_action text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_action text:=lower(trim(coalesce(p_action,'')));v_movement public.payroll_movements%rowtype;
  v_count integer:=0;v_expected integer:=coalesce(cardinality(p_movement_ids),0);v_found integer;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_payroll_movements') then raise exception 'No autorizado para resolver movimientos.'; end if;
  if v_action not in ('approve','reject') or v_expected not between 1 and 100 then raise exception 'Selecciona entre 1 y 100 movimientos y una acción válida.'; end if;
  select count(*) into v_found from public.payroll_movements
  where company_id=p_company_id and id=any(p_movement_ids)
    and movement_type in ('overtime','absence','commission','bonus') and status='pending';
  if v_found<>v_expected then raise exception 'Uno o más movimientos ya no están pendientes.'; end if;
  for v_movement in select * from public.payroll_movements
    where company_id=p_company_id and id=any(p_movement_ids)
      and movement_type in ('overtime','absence','commission','bonus') and status='pending' for update
  loop
    update public.payroll_movements set
      status=case when v_action='approve' then 'approved' else 'rejected' end,
      approved_by=case when v_action='approve' then auth.uid() else null end,
      approved_at=case when v_action='approve' then now() else null end
    where id=v_movement.id;
    if v_movement.movement_type='absence' then
      update public.collaborator_time_off set
        status=case when v_action='approve' then 'approved' else 'rejected' end,
        approved_by=case when v_action='approve' then auth.uid() else null end,
        approved_at=case when v_action='approve' then now() else null end
      where payroll_movement_id=v_movement.id;
    end if;
    v_count:=v_count+1;
  end loop;
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)
  values(p_company_id,auth.uid(),'payroll.movements_'||v_action||'d','payroll_movement_batch',jsonb_build_object('count',v_count,'movement_ids',p_movement_ids));
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
    insert into public.payroll_period_lines(company_id,payroll_period_id,collaborator_id,collaborator_name_snapshot,base_pay_snapshot,additions_total,reductions_total,total_pay,payment_method)
    values(p_company_id,v_period.id,v_line.id,v_line.display_name,v_base,0,0,v_base,coalesce(v_line.payment_method,'unspecified')) returning id into v_line_id;
    insert into public.payroll_period_line_concepts(company_id,payroll_period_line_id,concept_code,label,direction,amount,source_date)
    values(p_company_id,v_line_id,'base_pay','Sueldo base','addition',v_base,v_period.ends_on);
    insert into public.payroll_period_line_concepts(company_id,payroll_period_line_id,payroll_movement_id,concept_code,label,direction,amount,units,source_date,calculation_metadata)
    select p_company_id,v_line_id,m.id,m.movement_type,
      case m.movement_type when 'overtime' then 'Horas extra' when 'absence' then 'Inasistencias' when 'commission' then 'Comisiones' when 'bonus' then 'Bonificaciones' when 'aguinaldo' then 'Aguinaldo' when 'vacation_premium' then 'Prima vacacional' else 'Ajuste' end,
      m.direction,m.amount,m.units,m.effective_on,coalesce(m.calculation_metadata,'{}'::jsonb)
    from public.payroll_movements m where m.company_id=p_company_id and m.collaborator_id=v_line.id and m.status='approved' and m.effective_on between v_period.starts_on and v_period.ends_on;
    update public.payroll_period_lines l set
      additions_total=coalesce((select sum(amount) from public.payroll_period_line_concepts c where c.payroll_period_line_id=l.id and c.direction='addition' and c.concept_code<>'base_pay'),0),
      reductions_total=coalesce((select sum(amount) from public.payroll_period_line_concepts c where c.payroll_period_line_id=l.id and c.direction='reduction'),0),
      total_pay=l.base_pay_snapshot+coalesce((select sum(amount) from public.payroll_period_line_concepts c where c.payroll_period_line_id=l.id and c.direction='addition' and c.concept_code<>'base_pay'),0)-coalesce((select sum(amount) from public.payroll_period_line_concepts c where c.payroll_period_line_id=l.id and c.direction='reduction'),0)
    where l.id=v_line_id;
  end loop;
  update public.payroll_periods set status='reviewing',prepared_by=auth.uid(),prepared_at=now() where id=v_period.id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'payroll.period_prepared','payroll_period',v_period.id,jsonb_build_object('starts_on',v_period.starts_on,'ends_on',v_period.ends_on));
  return public.get_payroll_period(p_company_id,v_period.id);
end $$;

revoke execute on function public.save_payroll_adjustments_batch(uuid,text,jsonb),public.get_payroll_workspace(uuid,text,integer,integer),public.save_payroll_operational_configuration(uuid,text,numeric,numeric,numeric) from public;
grant execute on function public.save_payroll_adjustments_batch(uuid,text,jsonb),public.get_payroll_workspace(uuid,text,integer,integer),public.get_payroll_operational_settings(uuid),public.save_payroll_operational_configuration(uuid,text,numeric,numeric,numeric) to authenticated;
