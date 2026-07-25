-- Satrapy · Colaboradores y nómina interna.
-- El módulo conserva una fuente operativa única: movimientos aprobados alimentan
-- corridas cerrables. No calcula ni almacena conceptos fiscales.

insert into public.permissions(code,description) values
  ('view_collaborators','Consultar directorio de colaboradores y sus movimientos.'),
  ('manage_collaborators','Crear y actualizar colaboradores, sueldo e información laboral.'),
  ('manage_payroll_movements','Registrar, aprobar y corregir movimientos internos de nómina.'),
  ('manage_payroll_runs','Preparar y revisar periodos de nómina interna.'),
  ('approve_payroll_runs','Aprobar corridas internas de nómina.'),
  ('mark_payroll_paid','Registrar el pago de una corrida aprobada.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in ('super_admin','direccion_admin') and p.code in (
  'view_collaborators','manage_collaborators','manage_payroll_movements',
  'manage_payroll_runs','approve_payroll_runs','mark_payroll_paid'
) on conflict do nothing;

create table public.collaborators(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null,
  display_name text not null,
  job_title text,
  employment_status text not null default 'active' check(employment_status in ('active','inactive')),
  hired_at date not null,
  terminated_at date,
  payment_frequency text not null default 'weekly' check(payment_frequency in ('weekly','biweekly','monthly')),
  alpha_external_id text,
  source text not null default 'manual' check(source in ('manual','alpha_import')),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(company_id,code), unique(company_id,alpha_external_id),
  check(terminated_at is null or terminated_at >= hired_at)
);

create table public.collaborator_compensation_history(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  collaborator_id uuid not null references public.collaborators(id) on delete cascade,
  effective_from date not null,
  base_pay_amount numeric(18,2) not null check(base_pay_amount >= 0),
  reason text,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  unique(collaborator_id,effective_from)
);

create table public.collaborator_vacation_balances(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  collaborator_id uuid not null references public.collaborators(id) on delete cascade,
  calendar_year integer not null check(calendar_year between 2000 and 2200),
  granted_days numeric(8,2) not null default 0 check(granted_days >= 0),
  adjustment_days numeric(8,2) not null default 0,
  used_days numeric(8,2) not null default 0 check(used_days >= 0),
  notes text,
  updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_at timestamptz not null default now(),
  unique(collaborator_id,calendar_year)
);

create table public.collaborator_time_off(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  collaborator_id uuid not null references public.collaborators(id) on delete cascade,
  kind text not null check(kind in ('vacation','absence')),
  starts_on date not null, ends_on date not null,
  days numeric(8,2) not null check(days > 0),
  status text not null default 'pending' check(status in ('pending','approved','rejected')),
  affects_payment boolean not null default false,
  notes text,
  source text not null default 'manual' check(source in ('manual','alpha_import')),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  approved_by uuid references auth.users(id) on delete set null,
  approved_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check(ends_on >= starts_on),
  check((status='approved') = (approved_at is not null))
);

create table public.payroll_movements(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  collaborator_id uuid not null references public.collaborators(id) on delete cascade,
  movement_type text not null check(movement_type in ('overtime','bonus','aguinaldo','vacation_premium','adjustment','absence')),
  direction text not null check(direction in ('addition','reduction','informational')),
  effective_on date not null,
  units numeric(12,2),
  amount numeric(18,2) not null default 0,
  description text,
  status text not null default 'pending' check(status in ('pending','approved','rejected')),
  source text not null default 'manual' check(source in ('manual','alpha_import')),
  source_reference text,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  approved_by uuid references auth.users(id) on delete set null,
  approved_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check(amount >= 0),
  check((status='approved') = (approved_at is not null))
);

create table public.payroll_periods(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  payment_frequency text not null check(payment_frequency in ('weekly','biweekly','monthly')),
  starts_on date not null, ends_on date not null, payment_date date,
  status text not null default 'draft' check(status in ('draft','reviewing','approved','paid')),
  notes text,
  prepared_by uuid references auth.users(id) on delete set null,
  prepared_at timestamptz,
  approved_by uuid references auth.users(id) on delete set null,
  approved_at timestamptz,
  paid_by uuid references auth.users(id) on delete set null,
  paid_at timestamptz,
  payment_reference text,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(company_id,payment_frequency,starts_on,ends_on), check(ends_on >= starts_on),
  check((status in ('reviewing','approved','paid')) = (prepared_at is not null)),
  check((status in ('approved','paid')) = (approved_at is not null)),
  check((status='paid') = (paid_at is not null))
);

create table public.payroll_period_lines(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  payroll_period_id uuid not null references public.payroll_periods(id) on delete cascade,
  collaborator_id uuid not null references public.collaborators(id) on delete restrict,
  collaborator_name_snapshot text not null,
  base_pay_snapshot numeric(18,2) not null default 0,
  additions_total numeric(18,2) not null default 0,
  reductions_total numeric(18,2) not null default 0,
  total_pay numeric(18,2) not null default 0,
  created_at timestamptz not null default now(),
  unique(payroll_period_id,collaborator_id)
);

create table public.payroll_period_line_concepts(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  payroll_period_line_id uuid not null references public.payroll_period_lines(id) on delete cascade,
  payroll_movement_id uuid references public.payroll_movements(id) on delete restrict,
  concept_code text not null,
  label text not null,
  direction text not null check(direction in ('addition','reduction','informational')),
  amount numeric(18,2) not null default 0,
  units numeric(12,2),
  source_date date,
  created_at timestamptz not null default now(),
  unique(payroll_period_line_id,payroll_movement_id)
);

create index collaborators_company_status_idx on public.collaborators(company_id,employment_status,display_name);
create index compensation_history_lookup_idx on public.collaborator_compensation_history(collaborator_id,effective_from desc);
create index time_off_company_collaborator_idx on public.collaborator_time_off(company_id,collaborator_id,starts_on desc);
create index payroll_movements_company_effective_idx on public.payroll_movements(company_id,effective_on,status,collaborator_id);
create index payroll_periods_company_date_idx on public.payroll_periods(company_id,starts_on desc);
create index payroll_period_lines_period_idx on public.payroll_period_lines(payroll_period_id,collaborator_name_snapshot);

drop trigger if exists collaborators_updated_at on public.collaborators;
create trigger collaborators_updated_at before update on public.collaborators for each row execute function public.set_updated_at();
drop trigger if exists collaborator_time_off_updated_at on public.collaborator_time_off;
create trigger collaborator_time_off_updated_at before update on public.collaborator_time_off for each row execute function public.set_updated_at();
drop trigger if exists payroll_movements_updated_at on public.payroll_movements;
create trigger payroll_movements_updated_at before update on public.payroll_movements for each row execute function public.set_updated_at();
drop trigger if exists payroll_periods_updated_at on public.payroll_periods;
create trigger payroll_periods_updated_at before update on public.payroll_periods for each row execute function public.set_updated_at();

create or replace function public.ensure_collaborator_payroll_editable()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_movement_id uuid:=coalesce(new.id,old.id);v_time_off_id uuid:=coalesce(new.id,old.id);
begin
  if tg_table_name='payroll_movements' and exists(
    select 1 from public.payroll_period_line_concepts c join public.payroll_period_lines l on l.id=c.payroll_period_line_id join public.payroll_periods p on p.id=l.payroll_period_id
    where c.payroll_movement_id=v_movement_id and p.status in ('approved','paid')
  ) then raise exception 'El movimiento pertenece a una nómina aprobada o pagada; registra un ajuste en otro periodo.'; end if;
  if tg_table_name='collaborator_time_off' and exists(
    select 1 from public.payroll_periods p where p.company_id=coalesce(new.company_id,old.company_id) and p.status in ('approved','paid')
      and daterange(p.starts_on,p.ends_on,'[]') && daterange(coalesce(new.starts_on,old.starts_on),coalesce(new.ends_on,old.ends_on),'[]')
  ) then raise exception 'La ausencia cruza una nómina aprobada o pagada; registra un ajuste en otro periodo.'; end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;

create trigger payroll_movements_immutable_when_closed before update or delete on public.payroll_movements for each row execute function public.ensure_collaborator_payroll_editable();
create trigger collaborator_time_off_immutable_when_closed before update or delete on public.collaborator_time_off for each row execute function public.ensure_collaborator_payroll_editable();

create or replace function public.search_collaborators(
  p_company_id uuid,p_query text default null,p_status text default null,p_page integer default 1,p_page_size integer default 50
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);v_q text:=lower(trim(coalesce(p_query,'')));v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collaborators') then raise exception 'No autorizado para consultar colaboradores.'; end if;
  with filtered as materialized(
    select c.*,h.base_pay_amount,h.effective_from from public.collaborators c
    left join lateral(select base_pay_amount,effective_from from public.collaborator_compensation_history h where h.collaborator_id=c.id and h.effective_from<=current_date order by h.effective_from desc limit 1) h on true
    where c.company_id=p_company_id and (p_status is null or c.employment_status=p_status)
      and (v_q='' or lower(c.display_name) like '%'||v_q||'%' or lower(c.code) like '%'||v_q||'%' or lower(coalesce(c.job_title,'')) like '%'||v_q||'%')
  ), paged as (select * from filtered order by employment_status='active' desc,display_name,id limit v_size offset (v_page-1)*v_size)
  select (select count(*) from filtered),coalesce(jsonb_agg(to_jsonb(paged) order by employment_status='active' desc,display_name,id),'[]'::jsonb) into v_total,v_items from paged;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',coalesce(v_total,0)));
end $$;

create or replace function public.get_collaborator_profile(p_company_id uuid,p_collaborator_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collaborators') then raise exception 'No autorizado.'; end if;
  select to_jsonb(c)||jsonb_build_object(
    'compensation_history',coalesce((select jsonb_agg(to_jsonb(h) order by h.effective_from desc) from public.collaborator_compensation_history h where h.collaborator_id=c.id),'[]'::jsonb),
    'vacation_balances',coalesce((select jsonb_agg(to_jsonb(v) order by v.calendar_year desc) from public.collaborator_vacation_balances v where v.collaborator_id=c.id),'[]'::jsonb),
    'time_off',coalesce((select jsonb_agg(to_jsonb(t) order by t.starts_on desc) from public.collaborator_time_off t where t.collaborator_id=c.id),'[]'::jsonb),
    'movements',coalesce((select jsonb_agg(to_jsonb(m) order by m.effective_on desc,m.created_at desc) from public.payroll_movements m where m.collaborator_id=c.id),'[]'::jsonb),
    'payroll_history',coalesce((select jsonb_agg(to_jsonb(l)||jsonb_build_object('period_start',p.starts_on,'period_end',p.ends_on,'period_status',p.status,'payment_date',p.payment_date) order by p.starts_on desc) from public.payroll_period_lines l join public.payroll_periods p on p.id=l.payroll_period_id where l.collaborator_id=c.id),'[]'::jsonb)
  ) into v_result from public.collaborators c where c.id=p_collaborator_id and c.company_id=p_company_id;
  if v_result is null then raise exception 'Colaborador no encontrado.'; end if; return v_result;
end $$;

create or replace function public.save_collaborator(
  p_company_id uuid,p_collaborator_id uuid,p_code text,p_display_name text,p_job_title text,p_employment_status text,p_hired_at date,p_terminated_at date,p_payment_frequency text,p_base_pay_amount numeric,p_effective_from date,p_reason text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_collaborator public.collaborators%rowtype;v_frequency text:=lower(trim(coalesce(p_payment_frequency,'')));v_code text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_collaborators') then raise exception 'No autorizado para administrar colaboradores.'; end if;
  if nullif(trim(coalesce(p_display_name,'')),'') is null or p_hired_at is null then raise exception 'Nombre y fecha de ingreso son obligatorios.'; end if;
  if v_frequency not in ('weekly','biweekly','monthly') then raise exception 'Periodicidad de pago inválida.'; end if;
  if lower(trim(coalesce(p_employment_status,''))) not in ('active','inactive') then raise exception 'Estado de colaborador inválido.'; end if;
  if p_base_pay_amount is null or p_base_pay_amount<0 or p_effective_from is null then raise exception 'Captura el pago base y su vigencia.'; end if;
  if p_collaborator_id is null then
    perform pg_advisory_xact_lock(hashtextextended(p_company_id::text,97));
    select 'COL-'||lpad((coalesce(max(nullif(regexp_replace(code,'[^0-9]','','g'),'')::bigint),0)+1)::text,6,'0')
      into v_code from public.collaborators where company_id=p_company_id;
    insert into public.collaborators(company_id,code,display_name,job_title,employment_status,hired_at,terminated_at,payment_frequency)
    values(p_company_id,v_code,trim(p_display_name),nullif(trim(p_job_title),''),'active',p_hired_at,null,v_frequency) returning * into v_collaborator;
  else
    if lower(trim(p_employment_status))='inactive' and p_terminated_at is null then raise exception 'La fecha de baja es obligatoria al desactivar un colaborador.'; end if;
    update public.collaborators set display_name=trim(p_display_name),job_title=nullif(trim(p_job_title),''),employment_status=lower(trim(p_employment_status)),hired_at=p_hired_at,terminated_at=case when lower(trim(p_employment_status))='inactive' then p_terminated_at end,payment_frequency=v_frequency
    where id=p_collaborator_id and company_id=p_company_id returning * into v_collaborator;
    if not found then raise exception 'Colaborador no disponible.'; end if;
  end if;
  insert into public.collaborator_compensation_history(company_id,collaborator_id,effective_from,base_pay_amount,reason)
  values(p_company_id,v_collaborator.id,p_effective_from,p_base_pay_amount,nullif(trim(p_reason),''))
  on conflict(collaborator_id,effective_from) do update set base_pay_amount=excluded.base_pay_amount,reason=excluded.reason;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),case when p_collaborator_id is null then 'collaborator.created' else 'collaborator.updated' end,'collaborator',v_collaborator.id,jsonb_build_object('payment_frequency',v_frequency,'effective_from',p_effective_from));
  return public.get_collaborator_profile(p_company_id,v_collaborator.id);
end $$;

create or replace function public.save_collaborator_time_off(
  p_company_id uuid,p_time_off_id uuid,p_collaborator_id uuid,p_kind text,p_starts_on date,p_ends_on date,p_days numeric,p_affects_payment boolean,p_notes text,p_approve boolean default false
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_row public.collaborator_time_off%rowtype;v_kind text:=lower(trim(coalesce(p_kind,'')));
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_payroll_movements') then raise exception 'No autorizado para registrar vacaciones o ausencias.'; end if;
  if v_kind not in ('vacation','absence') or p_starts_on is null or p_ends_on is null or p_ends_on<p_starts_on or p_days is null or p_days<=0 then raise exception 'Los datos de vacaciones o ausencia son inválidos.'; end if;
  if not exists(select 1 from public.collaborators where id=p_collaborator_id and company_id=p_company_id) then raise exception 'Colaborador no disponible.'; end if;
  if p_time_off_id is null then
    insert into public.collaborator_time_off(company_id,collaborator_id,kind,starts_on,ends_on,days,affects_payment,notes,status,approved_by,approved_at)
    values(p_company_id,p_collaborator_id,v_kind,p_starts_on,p_ends_on,p_days,coalesce(p_affects_payment,false),nullif(trim(p_notes),''),case when p_approve then 'approved' else 'pending' end,case when p_approve then auth.uid() end,case when p_approve then now() end) returning * into v_row;
  else
    update public.collaborator_time_off set kind=v_kind,starts_on=p_starts_on,ends_on=p_ends_on,days=p_days,affects_payment=coalesce(p_affects_payment,false),notes=nullif(trim(p_notes),''),status=case when p_approve then 'approved' else 'pending' end,approved_by=case when p_approve then auth.uid() else null end,approved_at=case when p_approve then now() else null end
    where id=p_time_off_id and company_id=p_company_id returning * into v_row;
    if not found then raise exception 'Movimiento de tiempo no disponible.'; end if;
  end if;
  if v_row.kind='vacation' and v_row.status='approved' then
    insert into public.collaborator_vacation_balances(company_id,collaborator_id,calendar_year,used_days,updated_by)
    values(p_company_id,p_collaborator_id,extract(year from p_starts_on)::integer,p_days,auth.uid())
    on conflict(collaborator_id,calendar_year) do update set
      used_days=(select coalesce(sum(days),0) from public.collaborator_time_off t where t.collaborator_id=excluded.collaborator_id and t.kind='vacation' and t.status='approved' and extract(year from t.starts_on)=excluded.calendar_year),
      updated_by=auth.uid(),updated_at=now();
  end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'collaborator.time_off_saved','collaborator_time_off',v_row.id,jsonb_build_object('kind',v_row.kind,'status',v_row.status));
  return to_jsonb(v_row);
end $$;

create or replace function public.save_collaborator_vacation_balance(
  p_company_id uuid,p_collaborator_id uuid,p_calendar_year integer,p_granted_days numeric,p_adjustment_days numeric,p_notes text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_result public.collaborator_vacation_balances%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_payroll_movements') then raise exception 'No autorizado para administrar saldos de vacaciones.'; end if;
  if p_calendar_year not between 2000 and 2200 or coalesce(p_granted_days,-1)<0 then raise exception 'El año y los días otorgados son obligatorios.'; end if;
  if not exists(select 1 from public.collaborators where id=p_collaborator_id and company_id=p_company_id) then raise exception 'Colaborador no disponible.'; end if;
  insert into public.collaborator_vacation_balances(company_id,collaborator_id,calendar_year,granted_days,adjustment_days,used_days,notes,updated_by)
  values(p_company_id,p_collaborator_id,p_calendar_year,p_granted_days,coalesce(p_adjustment_days,0),(select coalesce(sum(days),0) from public.collaborator_time_off t where t.collaborator_id=p_collaborator_id and t.kind='vacation' and t.status='approved' and extract(year from t.starts_on)=p_calendar_year),nullif(trim(p_notes),''),auth.uid())
  on conflict(collaborator_id,calendar_year) do update set granted_days=excluded.granted_days,adjustment_days=excluded.adjustment_days,used_days=excluded.used_days,notes=excluded.notes,updated_by=auth.uid(),updated_at=now()
  returning * into v_result;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'collaborator.vacation_balance_saved','collaborator_vacation_balance',v_result.id,jsonb_build_object('calendar_year',p_calendar_year,'granted_days',p_granted_days,'adjustment_days',coalesce(p_adjustment_days,0)));
  return to_jsonb(v_result);
end $$;

create or replace function public.save_payroll_movements_batch(p_company_id uuid,p_movements jsonb,p_approve boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_item jsonb;v_count integer:=0;v_id uuid;v_type text;v_direction text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_payroll_movements') then raise exception 'No autorizado para registrar movimientos.'; end if;
  if jsonb_typeof(coalesce(p_movements,'null'::jsonb))<>'array' or jsonb_array_length(p_movements)=0 then raise exception 'Agrega al menos un movimiento.'; end if;
  for v_item in select value from jsonb_array_elements(p_movements) loop
    v_type:=lower(trim(coalesce(v_item->>'movement_type','')));v_direction:=lower(trim(coalesce(v_item->>'direction','')));
    if v_type not in ('overtime','bonus','aguinaldo','vacation_premium','adjustment','absence') or v_direction not in ('addition','reduction','informational') or nullif(v_item->>'collaborator_id','') is null or nullif(v_item->>'effective_on','') is null or coalesce((v_item->>'amount')::numeric,-1)<0 then raise exception 'Un movimiento contiene datos inválidos.'; end if;
    if not exists(select 1 from public.collaborators where id=(v_item->>'collaborator_id')::uuid and company_id=p_company_id) then raise exception 'Un colaborador del lote no está disponible.'; end if;
    v_id:=nullif(v_item->>'id','')::uuid;
    if v_id is null then
      insert into public.payroll_movements(company_id,collaborator_id,movement_type,direction,effective_on,units,amount,description,status,approved_by,approved_at)
      values(p_company_id,(v_item->>'collaborator_id')::uuid,v_type,v_direction,(v_item->>'effective_on')::date,nullif(v_item->>'units','')::numeric,coalesce((v_item->>'amount')::numeric,0),nullif(trim(v_item->>'description'),''),case when p_approve then 'approved' else 'pending' end,case when p_approve then auth.uid() end,case when p_approve then now() end);
    else
      update public.payroll_movements set movement_type=v_type,direction=v_direction,effective_on=(v_item->>'effective_on')::date,units=nullif(v_item->>'units','')::numeric,amount=coalesce((v_item->>'amount')::numeric,0),description=nullif(trim(v_item->>'description'),''),status=case when p_approve then 'approved' else 'pending' end,approved_by=case when p_approve then auth.uid() else null end,approved_at=case when p_approve then now() else null end where id=v_id and company_id=p_company_id;
      if not found then raise exception 'Un movimiento del lote no está disponible.'; end if;
    end if;
    v_count:=v_count+1;
  end loop;
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata) values(p_company_id,auth.uid(),'payroll.movements_saved','payroll_movement_batch',jsonb_build_object('count',v_count,'approved',p_approve));
  return jsonb_build_object('saved',v_count);
end $$;

create or replace function public.save_payroll_period(p_company_id uuid,p_period_id uuid,p_payment_frequency text,p_starts_on date,p_ends_on date,p_payment_date date,p_notes text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_period public.payroll_periods%rowtype;v_frequency text:=lower(trim(coalesce(p_payment_frequency,'')));
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_payroll_runs') then raise exception 'No autorizado para administrar periodos de nómina.'; end if;
  if v_frequency not in ('weekly','biweekly','monthly') or p_starts_on is null or p_ends_on is null or p_ends_on<p_starts_on then raise exception 'Define una periodicidad y un rango válido.'; end if;
  if p_period_id is null then
    if exists(select 1 from public.payroll_periods where company_id=p_company_id and status<>'paid' and daterange(starts_on,ends_on,'[]') && daterange(p_starts_on,p_ends_on,'[]')) then raise exception 'Ya existe un periodo de nómina que se cruza con este rango.'; end if;
    insert into public.payroll_periods(company_id,payment_frequency,starts_on,ends_on,payment_date,notes) values(p_company_id,v_frequency,p_starts_on,p_ends_on,p_payment_date,nullif(trim(p_notes),'')) returning * into v_period;
  else
    update public.payroll_periods set payment_frequency=v_frequency,starts_on=p_starts_on,ends_on=p_ends_on,payment_date=p_payment_date,notes=nullif(trim(p_notes),'') where id=p_period_id and company_id=p_company_id and status='draft' returning * into v_period;
    if not found then raise exception 'Sólo se pueden editar periodos en preparación.'; end if;
  end if;
  return to_jsonb(v_period);
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
    insert into public.payroll_period_line_concepts(company_id,payroll_period_line_id,payroll_movement_id,concept_code,label,direction,amount,units,source_date)
    select p_company_id,v_line_id,m.id,m.movement_type,
      case m.movement_type when 'overtime' then 'Horas extra' when 'bonus' then 'Bono' when 'aguinaldo' then 'Aguinaldo' when 'vacation_premium' then 'Prima vacacional' when 'absence' then 'Ausencia' else 'Ajuste' end,
      m.direction,m.amount,m.units,m.effective_on
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
  select to_jsonb(p)||jsonb_build_object('lines',coalesce((select jsonb_agg(to_jsonb(l)||jsonb_build_object('concepts',coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at) from public.payroll_period_line_concepts c where c.payroll_period_line_id=l.id),'[]'::jsonb)) order by l.collaborator_name_snapshot) from public.payroll_period_lines l where l.payroll_period_id=p.id),'[]'::jsonb),'totals',jsonb_build_object('base_pay',coalesce((select sum(base_pay_snapshot) from public.payroll_period_lines where payroll_period_id=p.id),0),'additions',coalesce((select sum(additions_total) from public.payroll_period_lines where payroll_period_id=p.id),0),'reductions',coalesce((select sum(reductions_total) from public.payroll_period_lines where payroll_period_id=p.id),0),'total_pay',coalesce((select sum(total_pay) from public.payroll_period_lines where payroll_period_id=p.id),0))) into v_result from public.payroll_periods p where p.id=p_period_id and p.company_id=p_company_id;
  if v_result is null then raise exception 'Periodo no encontrado.'; end if;return v_result;
end $$;

create or replace function public.search_payroll_periods(p_company_id uuid,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collaborators') then raise exception 'No autorizado.'; end if;
  with filtered as materialized(select p.*,coalesce((select sum(total_pay) from public.payroll_period_lines l where l.payroll_period_id=p.id),0) total_pay,coalesce((select count(*) from public.payroll_period_lines l where l.payroll_period_id=p.id),0) collaborator_count from public.payroll_periods p where p.company_id=p_company_id),paged as(select * from filtered order by starts_on desc,id desc limit v_size offset (v_page-1)*v_size)
  select (select count(*) from filtered),coalesce(jsonb_agg(to_jsonb(paged) order by starts_on desc,id desc),'[]'::jsonb) into v_total,v_items from paged;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',coalesce(v_total,0)));
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
    if not public.has_company_permission(p_company_id,'mark_payroll_paid') or v_period.status<>'approved' then raise exception 'Sólo una nómina aprobada puede marcarse como pagada.'; end if;
    if nullif(trim(coalesce(p_payment_reference,'')),'') is null then raise exception 'Registra la referencia o comprobante del pago.'; end if;
    update public.payroll_periods set status='paid',paid_by=auth.uid(),paid_at=now(),payment_reference=trim(p_payment_reference) where id=v_period.id;
  else raise exception 'Acción de nómina inválida.'; end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'payroll.period_'||v_action,'payroll_period',v_period.id,jsonb_build_object('payment_reference',nullif(trim(coalesce(p_payment_reference,'')),'')));
  return public.get_payroll_period(p_company_id,v_period.id);
end $$;

create or replace function public.get_initial_migration_readiness(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_modules jsonb;v_ready integer;v_total integer;v_files bigint;
begin
  if auth.uid() is null or not public.has_company_access(p_company_id) then raise exception 'Empresa no disponible.';end if;
  select count(*) into v_files from public.import_batches where company_id=p_company_id;
  v_modules:=jsonb_build_array(
    jsonb_build_object('code','company','label','Empresa y acceso','description','Estructura y personas que pueden operar.','href','/satrapy/configuracion/empresa/sucursales','checks',jsonb_build_array(
      public.coverage_check('locations','Sucursales activas',(select count(*) from public.locations where company_id=p_company_id and is_active)),
      public.coverage_check('users','Usuarios vinculados',(select count(distinct user_id) from public.user_roles where company_id=p_company_id)
    ))),
    jsonb_build_object('code','inventory','label','Productos e inventario','description','Catálogo, precios y existencias de origen.','href','/satrapy/configuracion/importaciones','checks',jsonb_build_array(
      public.coverage_check('products','Productos canónicos',(select count(*) from public.products where company_id=p_company_id)),
      public.coverage_check('prices','Precios registrados',(select count(*) from public.product_prices pp join public.products p on p.id=pp.product_id where p.company_id=p_company_id)),
      public.coverage_check('snapshots','Cortes de inventario promovidos',(select count(*) from public.inventory_snapshots where company_id=p_company_id and status='completed'))
    )),
    jsonb_build_object('code','collaborators','label','Colaboradores y nómina','description','Directorio, sueldos, movimientos y cortes internos.','href','/satrapy/colaboradores/directorio','checks',jsonb_build_array(
      public.coverage_check('collaborators','Colaboradores canónicos',(select count(*) from public.collaborators where company_id=p_company_id)),
      public.coverage_check('compensation','Sueldos con vigencia',(select count(*) from public.collaborator_compensation_history where company_id=p_company_id)),
      public.coverage_check('payroll_periods','Periodos de nómina',(select count(*) from public.payroll_periods where company_id=p_company_id))
    )),
    jsonb_build_object('code','sales','label','Ventas y cuentas por cobrar','description','Configuración comercial e historia de clientes.','href','/satrapy/configuracion/ventas','checks',jsonb_build_array(
      public.coverage_check('customers','Clientes',(select count(*) from public.customers where company_id=p_company_id)),
      public.coverage_check('sales','Ventas confirmadas',(select count(*) from public.sales where company_id=p_company_id and status='confirmed'))
    )),
    jsonb_build_object('code','purchasing','label','Compras y cuentas por pagar','description','Proveedores, documentos, cuentas y pagos.','href','/satrapy/configuracion/importaciones','checks',jsonb_build_array(
      public.coverage_check('suppliers','Proveedores',(select count(*) from public.suppliers where company_id=p_company_id)),
      public.coverage_check('purchase_orders','Órdenes de compra',(select count(*) from public.purchase_orders where company_id=p_company_id)),
      public.coverage_check('payables','Documentos por pagar',(select count(*) from public.accounts_payable where company_id=p_company_id))
    )),
    jsonb_build_object('code','accounting','label','Contabilidad','description','Configuración, catálogo, periodos y automatización.','href','/satrapy/contabilidad/configuracion','checks',jsonb_build_array(
      public.coverage_check('accounting_config','Configuración aprobada',(select count(*) from public.accounting_config_versions where company_id=p_company_id and status='approved')),
      public.coverage_check('accounts','Cuentas contables',(select count(*) from public.accounting_accounts where company_id=p_company_id and is_active)),
      public.coverage_check('periods','Periodos creados',(select count(*) from public.accounting_periods where company_id=p_company_id))
    )),
    jsonb_build_object('code','banking','label','Bancos y conciliación','description','Cuentas, estados, movimientos y evidencia conciliada.','href','/satrapy/contabilidad/bancos','checks',jsonb_build_array(
      public.coverage_check('financial_accounts','Cuentas financieras activas',(select count(*) from public.financial_accounts where company_id=p_company_id and is_active)),
      public.coverage_check('statements','Estados bancarios promovidos',(select count(*) from public.bank_statement_batches where company_id=p_company_id and status='promoted'))
    ))
  );
  select count(*) filter(where c->>'status'='ready'),count(*) into v_ready,v_total from jsonb_array_elements(v_modules) m cross join lateral jsonb_array_elements(m->'checks') c;
  return jsonb_build_object('observed_at',now(),'files',v_files,'ready_checks',v_ready,'total_checks',v_total,'modules',v_modules,'steps',(select jsonb_agg(jsonb_build_object('code',m->>'code','label',m->>'label','description',m->>'description','href',m->>'href','count',(select count(*) from jsonb_array_elements(m->'checks') c where c->>'status'='ready'),'ready',not exists(select 1 from jsonb_array_elements(m->'checks') c where c->>'status'<>'ready'))) from jsonb_array_elements(v_modules)m));
end $$;

alter table public.collaborators enable row level security;
alter table public.collaborator_compensation_history enable row level security;
alter table public.collaborator_vacation_balances enable row level security;
alter table public.collaborator_time_off enable row level security;
alter table public.payroll_movements enable row level security;
alter table public.payroll_periods enable row level security;
alter table public.payroll_period_lines enable row level security;
alter table public.payroll_period_line_concepts enable row level security;

create policy collaborators_read on public.collaborators for select to authenticated using(public.has_company_permission(company_id,'view_collaborators'));
create policy collaborator_compensation_history_read on public.collaborator_compensation_history for select to authenticated using(public.has_company_permission(company_id,'view_collaborators'));
create policy collaborator_vacation_balances_read on public.collaborator_vacation_balances for select to authenticated using(public.has_company_permission(company_id,'view_collaborators'));
create policy collaborator_time_off_read on public.collaborator_time_off for select to authenticated using(public.has_company_permission(company_id,'view_collaborators'));
create policy payroll_movements_read on public.payroll_movements for select to authenticated using(public.has_company_permission(company_id,'view_collaborators'));
create policy payroll_periods_read on public.payroll_periods for select to authenticated using(public.has_company_permission(company_id,'view_collaborators'));
create policy payroll_period_lines_read on public.payroll_period_lines for select to authenticated using(public.has_company_permission(company_id,'view_collaborators'));
create policy payroll_period_line_concepts_read on public.payroll_period_line_concepts for select to authenticated using(public.has_company_permission(company_id,'view_collaborators'));

revoke all on public.collaborators,public.collaborator_compensation_history,public.collaborator_vacation_balances,public.collaborator_time_off,public.payroll_movements,public.payroll_periods,public.payroll_period_lines,public.payroll_period_line_concepts from authenticated;
grant execute on function public.search_collaborators(uuid,text,text,integer,integer),public.get_collaborator_profile(uuid,uuid),public.save_collaborator(uuid,uuid,text,text,text,text,date,date,text,numeric,date,text),public.save_collaborator_time_off(uuid,uuid,uuid,text,date,date,numeric,boolean,text,boolean),public.save_collaborator_vacation_balance(uuid,uuid,integer,numeric,numeric,text),public.save_payroll_movements_batch(uuid,jsonb,boolean),public.save_payroll_period(uuid,uuid,text,date,date,date,text),public.prepare_payroll_period(uuid,uuid),public.get_payroll_period(uuid,uuid),public.search_payroll_periods(uuid,integer,integer),public.advance_payroll_period(uuid,uuid,text,text) to authenticated;
