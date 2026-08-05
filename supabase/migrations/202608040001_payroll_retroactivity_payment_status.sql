-- Incidencias retroactivas y estados operativos de pago.
-- Una corrección nunca reabre ni modifica una nómina aprobada o pagada.

alter table public.payroll_movements
  add column if not exists occurred_on date,
  add column if not exists retroactive_reason text,
  add column if not exists origin_payroll_period_id uuid references public.payroll_periods(id) on delete restrict;

-- `occurred_on` es una columna técnica nueva. Al completar el histórico no se
-- está corrigiendo el movimiento ni la nómina cerrada; por eso se evita de
-- forma acotada el trigger de inmutabilidad durante esta única normalización.
alter table public.payroll_movements disable trigger payroll_movements_immutable_when_closed;
update public.payroll_movements set occurred_on=effective_on where occurred_on is null;
alter table public.payroll_movements enable trigger payroll_movements_immutable_when_closed;
alter table public.payroll_movements alter column occurred_on set not null;
create index if not exists payroll_movements_origin_period_idx on public.payroll_movements(origin_payroll_period_id,company_id);

create or replace function public.payroll_payment_state(p_period_id uuid)
returns text language sql stable security definer set search_path=public as $$
  select case p.status
    when 'draft' then 'preparing'
    when 'reviewing' then 'reviewing'
    when 'paid' then 'paid'
    when 'approved' then case when exists(select 1 from public.payroll_payment_batches b where b.payroll_period_id=p.id) then 'partial' else 'due' end
    else p.status
  end
  from public.payroll_periods p where p.id=p_period_id;
$$;

create or replace function public.save_payroll_adjustments_batch(
  p_company_id uuid,p_kind text,p_rows jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_kind text:=lower(trim(coalesce(p_kind,'')));v_item jsonb;v_collaborator public.collaborators%rowtype;
  v_occurred_on date;v_apply_on date;v_origin_period public.payroll_periods%rowtype;v_origin_found boolean;
  v_current_start date;v_current_end date;v_frequency text;v_reason text;v_description text;v_movement_id uuid;
  v_base numeric;v_daily_rate numeric;v_hourly_rate numeric;v_amount numeric;v_days numeric;v_hours numeric;
  v_default_hourly_rate numeric;v_manual_rate_override boolean;v_reported_minutes integer;v_count integer:=0;
  v_settings public.payroll_incidence_settings%rowtype;v_movement_ids uuid[]:='{}';
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_payroll_movements') then raise exception 'No autorizado para registrar movimientos de nómina.'; end if;
  if v_kind not in ('overtime','absence','commission','bonus') then raise exception 'Selecciona un movimiento de nómina válido.'; end if;
  if jsonb_typeof(coalesce(p_rows,'null'::jsonb))<>'array' or jsonb_array_length(p_rows) not between 1 and 100 then raise exception 'Agrega entre 1 y 100 colaboradores.'; end if;
  select * into v_settings from public.payroll_incidence_settings where company_id=p_company_id;
  if not found then raise exception 'Configura los días de trabajo pagados y las horas por día antes de capturar movimientos.'; end if;
  select coalesce((select payment_frequency from public.payroll_schedules where company_id=p_company_id),'weekly') into v_frequency;
  select starts_on,ends_on into v_current_start,v_current_end from public.payroll_period_bounds(v_frequency,current_date);

  for v_item in select value from jsonb_array_elements(p_rows) loop
    v_hours:=null;
    v_amount:=null;
    v_hourly_rate:=null;
    v_reported_minutes:=null;
    select * into v_collaborator from public.collaborators where id=nullif(v_item->>'collaborator_id','')::uuid and company_id=p_company_id and employment_status='active';
    v_occurred_on:=nullif(v_item->>'effective_on','')::date;
    v_reason:=nullif(trim(v_item->>'retroactive_reason'),'');
    v_description:=nullif(trim(v_item->>'description'),'');
    if not found or v_occurred_on is null then raise exception 'Una fila contiene un colaborador o fecha no disponible.'; end if;
    if v_occurred_on<v_collaborator.hired_at then raise exception 'La fecha de una incidencia no puede ser anterior al ingreso del colaborador.'; end if;
    if v_occurred_on>v_current_end then raise exception 'La fecha de una incidencia no puede ser posterior al periodo vigente.'; end if;
    if v_occurred_on<v_current_start and v_reason is null then raise exception 'Indica el motivo de cada incidencia retroactiva.'; end if;
    select * into v_origin_period from public.payroll_periods p
      where p.company_id=p_company_id and p.payment_frequency=v_frequency and v_occurred_on between p.starts_on and p.ends_on
      order by p.starts_on desc limit 1;
    v_origin_found:=found;
    v_apply_on:=case when v_occurred_on<v_current_start and (not v_origin_found or v_origin_period.status in ('approved','paid')) then v_current_start else v_occurred_on end;

    if v_kind='overtime' then
      v_reported_minutes:=nullif(v_item->>'reported_minutes','')::integer;v_hours:=nullif(v_item->>'payable_hours','')::numeric;v_hourly_rate:=nullif(v_item->>'hourly_rate','')::numeric;
      if coalesce(v_hours,0)<=0 or coalesce(v_hourly_rate,0)<=0 then raise exception 'Las horas extra y la tarifa por hora deben ser mayores a cero.'; end if;
      v_reported_minutes:=coalesce(v_reported_minutes,round(v_hours*60)::integer);v_hourly_rate:=round(v_hourly_rate,2);v_default_hourly_rate:=round(v_settings.default_overtime_hourly_rate,2);v_manual_rate_override:=v_hourly_rate<>v_default_hourly_rate;v_amount:=round(v_hourly_rate*v_hours,2);
      insert into public.payroll_movements(company_id,collaborator_id,movement_type,direction,effective_on,occurred_on,origin_payroll_period_id,retroactive_reason,units,amount,description,status,calculation_metadata)
      values(p_company_id,v_collaborator.id,'overtime','addition',v_apply_on,v_occurred_on,case when v_origin_found then v_origin_period.id else null end,v_reason,v_hours,v_amount,v_description,'pending',jsonb_build_object('hourly_rate',v_hourly_rate,'default_hourly_rate',v_default_hourly_rate,'manual_rate_override',v_manual_rate_override,'reported_minutes',v_reported_minutes,'payable_hours',v_hours,'manual_rounding',true,'formula','payable_hours × hourly_rate','occurred_on',v_occurred_on,'applied_on',v_apply_on,'retroactive',v_occurred_on<v_current_start)) returning id into v_movement_id;
    elsif v_kind='absence' then
      select base_pay_amount into v_base from public.collaborator_compensation_history where collaborator_id=v_collaborator.id and effective_from<=v_occurred_on order by effective_from desc limit 1;
      if v_base is null then raise exception 'Un colaborador no tiene sueldo vigente para la fecha capturada.'; end if;
      v_daily_rate:=round(v_base/v_settings.payable_days_per_period,4);v_hourly_rate:=round(v_daily_rate/v_settings.hours_per_workday,4);v_days:=coalesce(nullif(v_item->>'days','')::numeric,0);v_hours:=coalesce(nullif(v_item->>'hours','')::numeric,0);
      if v_days<0 or v_hours<0 or v_days+v_hours<=0 then raise exception 'La inasistencia requiere días, horas o ambos.'; end if;
      v_amount:=round(v_daily_rate*v_days+v_hourly_rate*v_hours,2);
      insert into public.payroll_movements(company_id,collaborator_id,movement_type,direction,effective_on,occurred_on,origin_payroll_period_id,retroactive_reason,units,amount,description,status,calculation_metadata)
      values(p_company_id,v_collaborator.id,'absence','reduction',v_apply_on,v_occurred_on,case when v_origin_found then v_origin_period.id else null end,v_reason,case when v_days>0 then v_days else v_hours end,v_amount,v_description,'pending',jsonb_build_object('daily_rate',v_daily_rate,'hourly_rate',v_hourly_rate,'days',v_days,'hours',v_hours,'paid',false,'formula','daily_rate × days + hourly_rate × hours','occurred_on',v_occurred_on,'applied_on',v_apply_on,'retroactive',v_occurred_on<v_current_start)) returning id into v_movement_id;
      if v_days>0 then insert into public.collaborator_time_off(company_id,collaborator_id,kind,starts_on,ends_on,days,status,affects_payment,notes,payroll_movement_id) values(p_company_id,v_collaborator.id,'absence',v_occurred_on,v_occurred_on+(greatest(ceil(v_days)::integer,1)-1),v_days,'pending',true,v_description,v_movement_id); end if;
    else
      v_amount:=nullif(v_item->>'amount','')::numeric;if coalesce(v_amount,0)<=0 then raise exception 'Las comisiones y bonificaciones requieren un importe mayor a cero.'; end if;
      insert into public.payroll_movements(company_id,collaborator_id,movement_type,direction,effective_on,occurred_on,origin_payroll_period_id,retroactive_reason,amount,description,status,calculation_metadata)
      values(p_company_id,v_collaborator.id,v_kind,'addition',v_apply_on,v_occurred_on,case when v_origin_found then v_origin_period.id else null end,v_reason,round(v_amount,2),v_description,'pending',jsonb_build_object('entered_amount',round(v_amount,2),'formula','importe autorizado','occurred_on',v_occurred_on,'applied_on',v_apply_on,'retroactive',v_occurred_on<v_current_start)) returning id into v_movement_id;
    end if;
    v_count:=v_count+1;v_movement_ids:=array_append(v_movement_ids,v_movement_id);
    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'payroll.'||v_kind||'_saved','payroll_movement',v_movement_id,jsonb_build_object('kind',v_kind,'collaborator_id',v_collaborator.id,'occurred_on',v_occurred_on,'applied_on',v_apply_on,'origin_period_id',case when v_origin_found then v_origin_period.id else null end,'retroactive_reason',v_reason,'description',v_description,'amount',v_amount,'units',v_hours));
  end loop;
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata) values(p_company_id,auth.uid(),'payroll.'||v_kind||'_batch_saved','payroll_movement_batch',jsonb_build_object('kind',v_kind,'count',v_count,'status','pending','movement_ids',v_movement_ids));
  return jsonb_build_object('saved',v_count,'kind',v_kind,'status','pending','movement_ids',v_movement_ids);
end $$;

create or replace function public.get_payroll_period(p_company_id uuid,p_period_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collaborators') then raise exception 'No autorizado.'; end if;
  select to_jsonb(p)||jsonb_build_object(
    'payment_state',public.payroll_payment_state(p.id),
    'has_adjustments',exists(select 1 from public.payroll_movements m where m.origin_payroll_period_id=p.id),
    'lines',coalesce((select jsonb_agg(to_jsonb(l)||jsonb_build_object('concepts',coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at) from public.payroll_period_line_concepts c where c.payroll_period_line_id=l.id),'[]'::jsonb)) order by l.collaborator_name_snapshot) from public.payroll_period_lines l where l.payroll_period_id=p.id),'[]'::jsonb),
    'payment_batches',coalesce((select jsonb_agg(to_jsonb(b) order by b.payment_date,b.payment_method) from public.payroll_payment_batches b where b.payroll_period_id=p.id),'[]'::jsonb),
    'totals',jsonb_build_object('base_pay',coalesce((select sum(base_pay_snapshot) from public.payroll_period_lines where payroll_period_id=p.id),0),'additions',coalesce((select sum(additions_total) from public.payroll_period_lines where payroll_period_id=p.id),0),'reductions',coalesce((select sum(reductions_total) from public.payroll_period_lines where payroll_period_id=p.id),0),'total_pay',coalesce((select sum(total_pay) from public.payroll_period_lines where payroll_period_id=p.id),0)),
    'approval',jsonb_build_object('available_on',p.ends_on-1,'date_open',current_date>=p.ends_on-1,'needs_recalculation',case when p.status='reviewing' then public.payroll_period_needs_recalculation(p.id) else false end,'pending_movements',(select count(*) from public.payroll_movements m where m.company_id=p.company_id and m.effective_on between p.starts_on and p.ends_on and m.movement_type in ('overtime','absence','commission','bonus') and m.status='pending'))
  ) into v_result from public.payroll_periods p where p.id=p_period_id and p.company_id=p_company_id;
  if v_result is null then raise exception 'Periodo no encontrado.'; end if;return v_result;
end $$;

create or replace function public.search_payroll_periods(p_company_id uuid,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);v_frequency text;v_start date;v_end date;v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collaborators') then raise exception 'No autorizado.'; end if;
  select coalesce((select payment_frequency from public.payroll_schedules where company_id=p_company_id),'weekly') into v_frequency;select starts_on,ends_on into v_start,v_end from public.payroll_period_bounds(v_frequency,current_date);
  with filtered as materialized(select p.*,coalesce((select sum(total_pay) from public.payroll_period_lines l where l.payroll_period_id=p.id),0) total_pay,coalesce((select count(*) from public.payroll_period_lines l where l.payroll_period_id=p.id),0) collaborator_count,public.payroll_payment_state(p.id) payment_state,exists(select 1 from public.payroll_movements m where m.origin_payroll_period_id=p.id) has_adjustments from public.payroll_periods p where p.company_id=p_company_id and not(p.payment_frequency=v_frequency and p.starts_on=v_start and p.ends_on=v_end)),paged as(select * from filtered order by starts_on desc,id desc limit v_size offset (v_page-1)*v_size)
  select (select count(*) from filtered),coalesce(jsonb_agg(to_jsonb(paged) order by starts_on desc,id desc),'[]'::jsonb) into v_total,v_items from paged;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',coalesce(v_total,0)));
end $$;

revoke execute on function public.payroll_payment_state(uuid) from public;
grant execute on function public.save_payroll_adjustments_batch(uuid,text,jsonb),public.get_payroll_period(uuid,uuid),public.search_payroll_periods(uuid,integer,integer) to authenticated;
