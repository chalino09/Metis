-- Pago operativo: agrupación por forma de pago y referencias auditables por grupo.

create table if not exists public.payroll_payment_batches(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  payroll_period_id uuid not null references public.payroll_periods(id) on delete cascade,
  payment_method text not null check(payment_method in ('transfer','cash','other')),
  total_amount numeric(18,2) not null check(total_amount<>0),
  payment_date date not null,
  payment_reference text not null,
  recorded_by uuid references auth.users(id) on delete set null default auth.uid(),
  recorded_at timestamptz not null default now(),
  unique(payroll_period_id,payment_method)
);

alter table public.payroll_period_lines
  add column if not exists payment_method text not null default 'unspecified'
  check(payment_method in ('unspecified','transfer','cash','other'));
create index if not exists payroll_payment_batches_period_method_idx on public.payroll_payment_batches(payroll_period_id,payment_method);

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

create or replace function public.get_payroll_period(p_company_id uuid,p_period_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collaborators') then raise exception 'No autorizado.'; end if;
  select to_jsonb(p)||jsonb_build_object(
    'lines',coalesce((select jsonb_agg(to_jsonb(l)||jsonb_build_object('concepts',coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at) from public.payroll_period_line_concepts c where c.payroll_period_line_id=l.id),'[]'::jsonb)) order by l.collaborator_name_snapshot) from public.payroll_period_lines l where l.payroll_period_id=p.id),'[]'::jsonb),
    'payment_batches',coalesce((select jsonb_agg(to_jsonb(b) order by b.payment_method) from public.payroll_payment_batches b where b.payroll_period_id=p.id),'[]'::jsonb),
    'totals',jsonb_build_object('base_pay',coalesce((select sum(base_pay_snapshot) from public.payroll_period_lines where payroll_period_id=p.id),0),'additions',coalesce((select sum(additions_total) from public.payroll_period_lines where payroll_period_id=p.id),0),'reductions',coalesce((select sum(reductions_total) from public.payroll_period_lines where payroll_period_id=p.id),0),'total_pay',coalesce((select sum(total_pay) from public.payroll_period_lines where payroll_period_id=p.id),0))
  ) into v_result from public.payroll_periods p where p.id=p_period_id and p.company_id=p_company_id;
  if v_result is null then raise exception 'Periodo no encontrado.'; end if;return v_result;
end $$;

create or replace function public.set_payroll_line_payment_method(
  p_company_id uuid,p_period_line_id uuid,p_payment_method text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_method text:=lower(trim(coalesce(p_payment_method,'')));v_line record;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'mark_payroll_paid') then raise exception 'No autorizado para ajustar la forma de pago de la corrida.'; end if;
  if v_method not in ('transfer','cash','other') then raise exception 'Selecciona una forma de pago válida.'; end if;
  select l.*,p.status period_status into v_line from public.payroll_period_lines l join public.payroll_periods p on p.id=l.payroll_period_id where l.id=p_period_line_id and l.company_id=p_company_id for update;
  if not found or v_line.period_status<>'approved' then raise exception 'Sólo se ajustan líneas de una nómina aprobada.'; end if;
  if exists(select 1 from public.payroll_payment_batches where payroll_period_id=v_line.payroll_period_id and payment_method in (v_line.payment_method,v_method)) then raise exception 'La forma de pago no puede cambiarse después de registrar uno de sus grupos.'; end if;
  update public.payroll_period_lines set payment_method=v_method where id=v_line.id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'payroll.line_payment_method_saved','payroll_period_line',v_line.id,jsonb_build_object('payment_method',v_method));
  return public.get_payroll_period(p_company_id,v_line.payroll_period_id);
end $$;

create or replace function public.record_payroll_payment_batch(
  p_company_id uuid,p_period_id uuid,p_payment_method text,p_payment_date date,p_payment_reference text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_period public.payroll_periods%rowtype;v_method text:=lower(trim(coalesce(p_payment_method,'')));v_total numeric;v_count integer;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'mark_payroll_paid') then raise exception 'No autorizado para registrar pagos.'; end if;
  if v_method not in ('transfer','cash','other') or p_payment_date is null or nullif(trim(coalesce(p_payment_reference,'')),'') is null then raise exception 'Captura forma de pago, fecha y referencia.'; end if;
  select * into v_period from public.payroll_periods where id=p_period_id and company_id=p_company_id for update;
  if not found or v_period.status<>'approved' then raise exception 'Sólo se pagan corridas aprobadas.'; end if;
  if exists(select 1 from public.payroll_payment_batches where payroll_period_id=v_period.id and payment_method=v_method) then raise exception 'Este grupo de pago ya fue registrado.'; end if;
  select count(*),coalesce(sum(total_pay),0) into v_count,v_total from public.payroll_period_lines where payroll_period_id=v_period.id and payment_method=v_method and total_pay<>0;
  if v_count=0 or v_total=0 then raise exception 'No hay un importe pendiente para esta forma de pago.'; end if;
  insert into public.payroll_payment_batches(company_id,payroll_period_id,payment_method,total_amount,payment_date,payment_reference,recorded_by)
  values(p_company_id,v_period.id,v_method,v_total,p_payment_date,trim(p_payment_reference),auth.uid());
  if not exists(
    select 1 from public.payroll_period_lines l
    where l.payroll_period_id=v_period.id and l.total_pay<>0
      and (l.payment_method='unspecified' or not exists(select 1 from public.payroll_payment_batches b where b.payroll_period_id=v_period.id and b.payment_method=l.payment_method))
  ) then
    update public.payroll_periods set status='paid',paid_by=auth.uid(),paid_at=now(),payment_reference='Pagos registrados por método' where id=v_period.id;
  end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'payroll.payment_batch_recorded','payroll_payment_batch',v_period.id,jsonb_build_object('payment_method',v_method,'payment_date',p_payment_date,'payment_reference',trim(p_payment_reference),'total_amount',v_total));
  return public.get_payroll_period(p_company_id,v_period.id);
end $$;

create or replace function public.advance_payroll_period(p_company_id uuid,p_period_id uuid,p_action text,p_payment_reference text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_period public.payroll_periods%rowtype;v_action text:=lower(trim(coalesce(p_action,'')));
begin
  select * into v_period from public.payroll_periods where id=p_period_id and company_id=p_company_id for update;
  if not found or auth.uid() is null then raise exception 'Periodo no disponible.'; end if;
  if v_action='approve' then
    if not public.has_company_permission(p_company_id,'approve_payroll_runs') or v_period.status<>'reviewing' then raise exception 'Sólo una nómina en revisión puede aprobarse.'; end if;
    if not exists(select 1 from public.payroll_period_lines where payroll_period_id=v_period.id) then raise exception 'No hay colaboradores calculados en este periodo.'; end if;
    update public.payroll_periods set status='approved',approved_by=auth.uid(),approved_at=now() where id=v_period.id;
  elsif v_action='pay' then
    raise exception 'Registra los pagos por forma de pago antes de cerrar la nómina.';
  else raise exception 'Acción de nómina inválida.'; end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'payroll.period_'||v_action,'payroll_period',v_period.id,jsonb_build_object('payment_reference',null));
  return public.get_payroll_period(p_company_id,v_period.id);
end $$;

alter table public.payroll_payment_batches enable row level security;
drop policy if exists payroll_payment_batches_read on public.payroll_payment_batches;
create policy payroll_payment_batches_read on public.payroll_payment_batches for select to authenticated using(public.has_company_permission(company_id,'view_collaborators'));
revoke all on public.payroll_payment_batches from authenticated;
grant execute on function public.set_payroll_line_payment_method(uuid,uuid,text),public.record_payroll_payment_batch(uuid,uuid,text,date,text) to authenticated;
