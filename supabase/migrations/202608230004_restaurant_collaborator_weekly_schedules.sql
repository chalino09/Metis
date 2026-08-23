-- Satrapy · Horario semanal individual de colaboradores.
-- Cada guardado crea una versión vigente desde una fecha; el historial no se sobrescribe.

create table if not exists public.collaborator_weekly_schedules(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  collaborator_id uuid not null references public.collaborators(id) on delete cascade,
  version_number integer not null check(version_number>0),
  effective_from date not null,
  reason text not null check(nullif(trim(reason),'') is not null),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default clock_timestamp(),
  unique(collaborator_id,version_number)
);

create table if not exists public.collaborator_weekly_schedule_days(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  schedule_id uuid not null references public.collaborator_weekly_schedules(id) on delete cascade,
  collaborator_id uuid not null references public.collaborators(id) on delete cascade,
  weekday smallint not null check(weekday between 1 and 7),
  starts_at time not null,
  ends_at time not null,
  break_minutes integer not null default 0 check(break_minutes between 0 and 720),
  unique(schedule_id,weekday),
  check(starts_at<>ends_at)
);

create index if not exists collaborator_weekly_schedules_lookup_idx
  on public.collaborator_weekly_schedules(company_id,collaborator_id,effective_from desc,version_number desc);
create index if not exists collaborator_weekly_schedule_days_lookup_idx
  on public.collaborator_weekly_schedule_days(company_id,collaborator_id,schedule_id,weekday);

alter table public.collaborator_weekly_schedules enable row level security;
alter table public.collaborator_weekly_schedule_days enable row level security;
revoke all on public.collaborator_weekly_schedules,public.collaborator_weekly_schedule_days from anon,authenticated;

create or replace function public.assert_collaborator_weekly_schedule_integrity()
returns trigger language plpgsql set search_path=public as $$
declare v_company_id uuid;v_collaborator_id uuid;
begin
  if tg_table_name='collaborator_weekly_schedules' then
    if not exists(select 1 from public.collaborators c where c.id=new.collaborator_id and c.company_id=new.company_id) then
      raise exception 'El colaborador no pertenece a la empresa del horario.';
    end if;
  else
    select s.company_id,s.collaborator_id into v_company_id,v_collaborator_id
    from public.collaborator_weekly_schedules s where s.id=new.schedule_id;
    if v_company_id is distinct from new.company_id or v_collaborator_id is distinct from new.collaborator_id then
      raise exception 'El día no coincide con el horario y colaborador indicados.';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists collaborator_weekly_schedule_integrity on public.collaborator_weekly_schedules;
create trigger collaborator_weekly_schedule_integrity before insert or update on public.collaborator_weekly_schedules
for each row execute function public.assert_collaborator_weekly_schedule_integrity();
drop trigger if exists collaborator_weekly_schedule_day_integrity on public.collaborator_weekly_schedule_days;
create trigger collaborator_weekly_schedule_day_integrity before insert or update on public.collaborator_weekly_schedule_days
for each row execute function public.assert_collaborator_weekly_schedule_integrity();

create or replace function public.collaborator_shift_minutes(p_starts_at time,p_ends_at time,p_break_minutes integer)
returns integer language sql immutable set search_path=public as $$
  select greatest(0,round(extract(epoch from(
    case when p_ends_at>p_starts_at then p_ends_at-p_starts_at
         else interval '24 hours'-(p_starts_at-p_ends_at) end
  ))/60)::integer-coalesce(p_break_minutes,0))
$$;

create or replace function public.get_collaborator_weekly_schedule(
  p_company_id uuid,p_collaborator_id uuid,p_on_date date default current_date
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_current jsonb;v_history jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collaborators') then
    raise exception 'No autorizado para consultar horarios.';
  end if;
  if not exists(select 1 from public.collaborators c where c.id=p_collaborator_id and c.company_id=p_company_id) then
    raise exception 'Colaborador no disponible.';
  end if;

  select to_jsonb(s)||jsonb_build_object(
    'weekly_minutes',coalesce((select sum(public.collaborator_shift_minutes(d.starts_at,d.ends_at,d.break_minutes)) from public.collaborator_weekly_schedule_days d where d.schedule_id=s.id),0),
    'days',coalesce((select jsonb_agg(jsonb_build_object('weekday',d.weekday,'starts_at',to_char(d.starts_at,'HH24:MI'),'ends_at',to_char(d.ends_at,'HH24:MI'),'break_minutes',d.break_minutes,'net_minutes',public.collaborator_shift_minutes(d.starts_at,d.ends_at,d.break_minutes)) order by d.weekday) from public.collaborator_weekly_schedule_days d where d.schedule_id=s.id),'[]'::jsonb)
  ) into v_current
  from public.collaborator_weekly_schedules s
  where s.company_id=p_company_id and s.collaborator_id=p_collaborator_id and s.effective_from<=coalesce(p_on_date,current_date)
  order by s.effective_from desc,s.version_number desc limit 1;

  select coalesce(jsonb_agg(item order by (item->>'effective_from')::date desc,(item->>'version_number')::integer desc),'[]'::jsonb) into v_history
  from(
    select to_jsonb(s)||jsonb_build_object(
      'weekly_minutes',coalesce((select sum(public.collaborator_shift_minutes(d.starts_at,d.ends_at,d.break_minutes)) from public.collaborator_weekly_schedule_days d where d.schedule_id=s.id),0),
      'day_count',(select count(*) from public.collaborator_weekly_schedule_days d where d.schedule_id=s.id)
    ) item
    from public.collaborator_weekly_schedules s
    where s.company_id=p_company_id and s.collaborator_id=p_collaborator_id
    order by s.effective_from desc,s.version_number desc limit 12
  ) history;

  return jsonb_build_object('current',v_current,'history',v_history);
end $$;

create or replace function public.save_collaborator_weekly_schedule(
  p_company_id uuid,p_collaborator_id uuid,p_effective_from date,p_days jsonb,p_reason text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_schedule_id uuid;v_version integer;v_day record;v_count integer;v_shift_minutes integer;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_collaborators') then
    raise exception 'No autorizado para administrar horarios.';
  end if;
  if p_effective_from is null or nullif(trim(coalesce(p_reason,'')),'') is null then
    raise exception 'La vigencia y el motivo son obligatorios.';
  end if;
  if jsonb_typeof(coalesce(p_days,'null'::jsonb))<>'array' then raise exception 'El horario semanal no es válido.';end if;
  v_count:=jsonb_array_length(p_days);
  if v_count=0 or v_count>7 then raise exception 'Selecciona entre uno y siete días laborables.';end if;
  if not exists(select 1 from public.collaborators c where c.id=p_collaborator_id and c.company_id=p_company_id and c.employment_status='active') then
    raise exception 'El colaborador debe estar activo.';
  end if;
  if exists(
    select 1 from jsonb_to_recordset(p_days) as x(weekday integer,start_time text,end_time text,break_minutes integer)
    group by weekday having weekday is null or weekday not between 1 and 7 or count(*)>1
  ) then raise exception 'Hay días repetidos o fuera de rango.';end if;

  for v_day in select weekday,start_time::time starts_at,end_time::time ends_at,coalesce(break_minutes,0) break_minutes
    from jsonb_to_recordset(p_days) as x(weekday integer,start_time text,end_time text,break_minutes integer)
  loop
    if v_day.starts_at=v_day.ends_at then raise exception 'La entrada y la salida deben ser distintas.';end if;
    if v_day.break_minutes<0 then raise exception 'El descanso no puede ser negativo.';end if;
    v_shift_minutes:=public.collaborator_shift_minutes(v_day.starts_at,v_day.ends_at,0);
    if v_day.break_minutes>=v_shift_minutes then raise exception 'El descanso debe ser menor que la jornada.';end if;
  end loop;

  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||':'||p_collaborator_id::text,41));
  select coalesce(max(version_number),0)+1 into v_version from public.collaborator_weekly_schedules where collaborator_id=p_collaborator_id;
  insert into public.collaborator_weekly_schedules(company_id,collaborator_id,version_number,effective_from,reason)
  values(p_company_id,p_collaborator_id,v_version,p_effective_from,trim(p_reason)) returning id into v_schedule_id;

  insert into public.collaborator_weekly_schedule_days(company_id,schedule_id,collaborator_id,weekday,starts_at,ends_at,break_minutes)
  select p_company_id,v_schedule_id,p_collaborator_id,weekday,start_time::time,end_time::time,coalesce(break_minutes,0)
  from jsonb_to_recordset(p_days) as x(weekday integer,start_time text,end_time text,break_minutes integer);

  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'collaborator.weekly_schedule_created','collaborator',p_collaborator_id,
    jsonb_build_object('schedule_id',v_schedule_id,'version_number',v_version,'effective_from',p_effective_from,'day_count',v_count,'reason',trim(p_reason)));
  return public.get_collaborator_weekly_schedule(p_company_id,p_collaborator_id,p_effective_from);
end $$;

create or replace function public.create_collaborator_position(p_company_id uuid,p_name text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_position public.collaborator_positions%rowtype;v_name text:=trim(coalesce(p_name,''));
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_collaborators') then
    raise exception 'No autorizado para administrar puestos.';
  end if;
  if nullif(v_name,'') is null or char_length(v_name)>120 then raise exception 'Captura un nombre de puesto válido.';end if;
  select * into v_position from public.collaborator_positions where company_id=p_company_id and lower(name)=lower(v_name) limit 1;
  if found then
    if not v_position.is_active then update public.collaborator_positions set is_active=true where id=v_position.id returning * into v_position;end if;
    return jsonb_build_object('id',v_position.id,'code',v_position.code,'name',v_position.name);
  end if;
  insert into public.collaborator_positions(company_id,code,name)
  values(p_company_id,'puesto_'||substr(replace(gen_random_uuid()::text,'-',''),1,12),v_name) returning * into v_position;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'collaborator.position_created','collaborator_position',v_position.id,jsonb_build_object('name',v_position.name,'code',v_position.code));
  return jsonb_build_object('id',v_position.id,'code',v_position.code,'name',v_position.name);
end $$;

revoke all on function public.collaborator_shift_minutes(time,time,integer) from public,anon,authenticated;
revoke all on function public.get_collaborator_weekly_schedule(uuid,uuid,date) from public,anon;
revoke all on function public.save_collaborator_weekly_schedule(uuid,uuid,date,jsonb,text) from public,anon;
revoke all on function public.create_collaborator_position(uuid,text) from public,anon;
grant execute on function public.get_collaborator_weekly_schedule(uuid,uuid,date) to authenticated;
grant execute on function public.save_collaborator_weekly_schedule(uuid,uuid,date,jsonb,text) to authenticated;
grant execute on function public.create_collaborator_position(uuid,text) to authenticated;

notify pgrst,'reload schema';
