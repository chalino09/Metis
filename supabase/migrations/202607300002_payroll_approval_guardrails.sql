-- Protege la aprobación de nómina: ventana de cierre y snapshot vigente.

create or replace function public.payroll_period_needs_recalculation(p_period_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(
    select 1
    from public.payroll_periods p
    join public.payroll_movements m
      on m.company_id=p.company_id
     and m.effective_on between p.starts_on and p.ends_on
     and m.movement_type in ('overtime','absence','commission','bonus')
     and m.status='approved'
    where p.id=p_period_id
      and not exists(
        select 1
        from public.payroll_period_lines l
        join public.payroll_period_line_concepts c on c.payroll_period_line_id=l.id
        where l.payroll_period_id=p.id
          and c.payroll_movement_id=m.id
          and c.amount=m.amount
          and c.direction=m.direction
          and c.units is not distinct from m.units
          and coalesce(c.calculation_metadata,'{}'::jsonb)=coalesce(m.calculation_metadata,'{}'::jsonb)
      )
  ) or exists(
    select 1
    from public.payroll_periods p
    join public.payroll_period_lines l on l.payroll_period_id=p.id
    join public.payroll_period_line_concepts c
      on c.payroll_period_line_id=l.id
     and c.payroll_movement_id is not null
    left join public.payroll_movements m on m.id=c.payroll_movement_id
    where p.id=p_period_id
      and (
        m.id is null
        or m.company_id<>p.company_id
        or m.status<>'approved'
        or m.effective_on not between p.starts_on and p.ends_on
        or m.amount<>c.amount
        or m.direction<>c.direction
        or m.units is distinct from c.units
        or coalesce(m.calculation_metadata,'{}'::jsonb)<>coalesce(c.calculation_metadata,'{}'::jsonb)
      )
  );
$$;

create or replace function public.get_payroll_period(p_company_id uuid,p_period_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collaborators') then
    raise exception 'No autorizado.';
  end if;
  select to_jsonb(p)||jsonb_build_object(
    'lines',coalesce((
      select jsonb_agg(
        to_jsonb(l)||jsonb_build_object(
          'concepts',coalesce((
            select jsonb_agg(to_jsonb(c) order by c.created_at)
            from public.payroll_period_line_concepts c
            where c.payroll_period_line_id=l.id
          ),'[]'::jsonb)
        ) order by l.collaborator_name_snapshot
      )
      from public.payroll_period_lines l
      where l.payroll_period_id=p.id
    ),'[]'::jsonb),
    'payment_batches',coalesce((
      select jsonb_agg(to_jsonb(b) order by b.payment_method)
      from public.payroll_payment_batches b
      where b.payroll_period_id=p.id
    ),'[]'::jsonb),
    'totals',jsonb_build_object(
      'base_pay',coalesce((select sum(base_pay_snapshot) from public.payroll_period_lines where payroll_period_id=p.id),0),
      'additions',coalesce((select sum(additions_total) from public.payroll_period_lines where payroll_period_id=p.id),0),
      'reductions',coalesce((select sum(reductions_total) from public.payroll_period_lines where payroll_period_id=p.id),0),
      'total_pay',coalesce((select sum(total_pay) from public.payroll_period_lines where payroll_period_id=p.id),0)
    ),
    'approval',jsonb_build_object(
      'available_on',p.ends_on-1,
      'date_open',current_date>=p.ends_on-1,
      'needs_recalculation',case when p.status='reviewing' then public.payroll_period_needs_recalculation(p.id) else false end,
      'pending_movements',(
        select count(*)
        from public.payroll_movements m
        where m.company_id=p.company_id
          and m.effective_on between p.starts_on and p.ends_on
          and m.movement_type in ('overtime','absence','commission','bonus')
          and m.status='pending'
      )
    )
  ) into v_result
  from public.payroll_periods p
  where p.id=p_period_id and p.company_id=p_company_id;
  if v_result is null then raise exception 'Periodo no encontrado.'; end if;
  return v_result;
end $$;

create or replace function public.prepare_payroll_period(p_company_id uuid,p_period_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_period public.payroll_periods%rowtype;v_period_days numeric;v_line record;v_base numeric;
  v_active_start date;v_active_end date;v_active_days numeric;v_line_id uuid;v_was_reviewing boolean;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_payroll_runs') then
    raise exception 'No autorizado para preparar la nómina.';
  end if;
  select * into v_period
  from public.payroll_periods
  where id=p_period_id and company_id=p_company_id
  for update;
  if not found or v_period.status not in ('draft','reviewing') then
    raise exception 'Sólo una nómina en preparación o revisión puede recalcularse.';
  end if;
  v_was_reviewing:=v_period.status='reviewing';
  perform pg_advisory_xact_lock(hashtextextended(v_period.id::text,93));
  delete from public.payroll_period_lines where payroll_period_id=v_period.id;
  v_period_days:=(v_period.ends_on-v_period.starts_on)+1;
  for v_line in
    select c.*,h.base_pay_amount
    from public.collaborators c
    join lateral(
      select base_pay_amount
      from public.collaborator_compensation_history h
      where h.collaborator_id=c.id and h.effective_from<=v_period.ends_on
      order by h.effective_from desc limit 1
    ) h on true
    where c.company_id=p_company_id
      and c.payment_frequency=v_period.payment_frequency
      and c.hired_at<=v_period.ends_on
      and (c.terminated_at is null or c.terminated_at>=v_period.starts_on)
  loop
    v_active_start:=greatest(v_period.starts_on,v_line.hired_at);
    v_active_end:=least(v_period.ends_on,coalesce(v_line.terminated_at,v_period.ends_on));
    v_active_days:=(v_active_end-v_active_start)+1;
    v_base:=round(v_line.base_pay_amount*v_active_days/v_period_days,2);
    insert into public.payroll_period_lines(
      company_id,payroll_period_id,collaborator_id,collaborator_name_snapshot,base_pay_snapshot,
      additions_total,reductions_total,total_pay,payment_method
    ) values(
      p_company_id,v_period.id,v_line.id,v_line.display_name,v_base,0,0,v_base,
      coalesce(v_line.payment_method,'unspecified')
    ) returning id into v_line_id;
    insert into public.payroll_period_line_concepts(
      company_id,payroll_period_line_id,concept_code,label,direction,amount,source_date
    ) values(p_company_id,v_line_id,'base_pay','Sueldo base','addition',v_base,v_period.ends_on);
    insert into public.payroll_period_line_concepts(
      company_id,payroll_period_line_id,payroll_movement_id,concept_code,label,direction,
      amount,units,source_date,calculation_metadata
    )
    select p_company_id,v_line_id,m.id,m.movement_type,
      case m.movement_type
        when 'overtime' then 'Horas extra'
        when 'absence' then 'Inasistencias'
        when 'commission' then 'Comisiones'
        when 'bonus' then 'Bonificaciones'
        when 'aguinaldo' then 'Aguinaldo'
        when 'vacation_premium' then 'Prima vacacional'
        else 'Ajuste'
      end,
      m.direction,m.amount,m.units,m.effective_on,coalesce(m.calculation_metadata,'{}'::jsonb)
    from public.payroll_movements m
    where m.company_id=p_company_id
      and m.collaborator_id=v_line.id
      and m.status='approved'
      and m.effective_on between v_period.starts_on and v_period.ends_on;
    update public.payroll_period_lines l set
      additions_total=coalesce((
        select sum(amount)
        from public.payroll_period_line_concepts c
        where c.payroll_period_line_id=l.id and c.direction='addition' and c.concept_code<>'base_pay'
      ),0),
      reductions_total=coalesce((
        select sum(amount)
        from public.payroll_period_line_concepts c
        where c.payroll_period_line_id=l.id and c.direction='reduction'
      ),0),
      total_pay=l.base_pay_snapshot
        +coalesce((
          select sum(amount)
          from public.payroll_period_line_concepts c
          where c.payroll_period_line_id=l.id and c.direction='addition' and c.concept_code<>'base_pay'
        ),0)
        -coalesce((
          select sum(amount)
          from public.payroll_period_line_concepts c
          where c.payroll_period_line_id=l.id and c.direction='reduction'
        ),0)
    where l.id=v_line_id;
  end loop;
  update public.payroll_periods set
    status='reviewing',prepared_by=auth.uid(),prepared_at=now(),
    approved_by=null,approved_at=null
  where id=v_period.id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(
    p_company_id,auth.uid(),
    case when v_was_reviewing then 'payroll.period_recalculated' else 'payroll.period_prepared' end,
    'payroll_period',v_period.id,
    jsonb_build_object('starts_on',v_period.starts_on,'ends_on',v_period.ends_on)
  );
  return public.get_payroll_period(p_company_id,v_period.id);
end $$;

create or replace function public.advance_payroll_period(
  p_company_id uuid,p_period_id uuid,p_action text,p_payment_reference text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_period public.payroll_periods%rowtype;
  v_action text:=lower(trim(coalesce(p_action,'')));
  v_pending integer;
begin
  select * into v_period
  from public.payroll_periods
  where id=p_period_id and company_id=p_company_id
  for update;
  if not found or auth.uid() is null then raise exception 'Periodo no disponible.'; end if;
  if v_action='approve' then
    if not public.has_company_permission(p_company_id,'approve_payroll_runs') or v_period.status<>'reviewing' then
      raise exception 'Sólo una nómina en revisión puede aprobarse.';
    end if;
    if current_date<v_period.ends_on-1 then
      raise exception 'La nómina podrá aprobarse a partir del %, un día antes de cerrar el periodo.',to_char(v_period.ends_on-1,'DD/MM/YYYY');
    end if;
    select count(*) into v_pending
    from public.payroll_movements m
    where m.company_id=p_company_id
      and m.effective_on between v_period.starts_on and v_period.ends_on
      and m.movement_type in ('overtime','absence','commission','bonus')
      and m.status='pending';
    if v_pending>0 then
      raise exception 'Revisa los movimientos pendientes antes de aprobar la nómina.';
    end if;
    if public.payroll_period_needs_recalculation(v_period.id) then
      raise exception 'Hay movimientos aprobados que todavía no aparecen en el cálculo. Recalcula la nómina antes de aprobar.';
    end if;
    if not exists(select 1 from public.payroll_period_lines where payroll_period_id=v_period.id) then
      raise exception 'No hay colaboradores calculados en este periodo.';
    end if;
    update public.payroll_periods
    set status='approved',approved_by=auth.uid(),approved_at=now()
    where id=v_period.id;
  elsif v_action='pay' then
    raise exception 'Registra los pagos por forma de pago antes de cerrar la nómina.';
  else
    raise exception 'Acción de nómina inválida.';
  end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(
    p_company_id,auth.uid(),'payroll.period_'||v_action,'payroll_period',v_period.id,
    jsonb_build_object('payment_reference',null)
  );
  return public.get_payroll_period(p_company_id,v_period.id);
end $$;

revoke execute on function public.payroll_period_needs_recalculation(uuid) from public,authenticated;
