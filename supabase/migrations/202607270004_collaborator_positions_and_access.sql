-- Satrapy · Puesto laboral, cuenta de acceso y responsable BI.
-- No se deriva ningún puesto ni vínculo desde nombres, notas o Alpha.

create table if not exists public.collaborator_positions(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null check(code ~ '^[a-z][a-z0-9_]{1,62}$'),
  name text not null check(nullif(trim(name),'') is not null),
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,code),
  unique(company_id,name)
);

drop trigger if exists collaborator_positions_updated_at on public.collaborator_positions;
create trigger collaborator_positions_updated_at before update on public.collaborator_positions
for each row execute function public.set_updated_at();

-- Catálogo inicial controlado. Las filas existentes siguen sin puesto hasta que
-- una persona autorizada las clasifique explícitamente.
insert into public.collaborator_positions(company_id,code,name)
select c.id,seed.code,seed.name
from public.companies c
cross join (values
  ('direccion','Dirección'),
  ('responsable_sucursal','Responsable de sucursal'),
  ('ingeniero_campo','Ingeniero de campo'),
  ('almacen','Almacén')
) as seed(code,name)
on conflict(company_id,code) do update set name=excluded.name;

alter table public.collaborators add column if not exists position_id uuid;
alter table public.collaborators drop constraint if exists collaborators_position_id_fkey;
alter table public.collaborators add constraint collaborators_position_id_fkey
  foreign key(position_id) references public.collaborator_positions(id) on delete restrict;
create index if not exists collaborators_company_position_idx
  on public.collaborators(company_id,position_id,employment_status,display_name);

alter table public.company_user_invitations add column if not exists collaborator_id uuid;
alter table public.company_user_invitations drop constraint if exists company_user_invitations_collaborator_id_fkey;
alter table public.company_user_invitations add constraint company_user_invitations_collaborator_id_fkey
  foreign key(collaborator_id) references public.collaborators(id) on delete restrict;
create unique index if not exists company_user_invitations_pending_collaborator_unique
  on public.company_user_invitations(company_id,collaborator_id)
  where status='pending' and collaborator_id is not null;

create or replace function public.get_collaborator_position_options(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collaborators') then
    raise exception 'No autorizado para consultar puestos.';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id',p.id,'code',p.code,'name',p.name) order by p.name,p.id)
    from public.collaborator_positions p
    where p.company_id=p_company_id and p.is_active
  ),'[]'::jsonb);
end $$;

-- Firma nueva: position_id es la identidad laboral controlada; job_title se
-- conserva sólo como texto histórico importado y nunca se usa para permisos.
create or replace function public.save_collaborator(
  p_company_id uuid,p_collaborator_id uuid,p_code text,p_display_name text,p_job_title text,
  p_employment_status text,p_hired_at date,p_terminated_at date,p_payment_frequency text,
  p_base_pay_amount numeric,p_effective_from date,p_reason text,p_position_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_collaborator public.collaborators%rowtype;
  v_frequency text:=lower(trim(coalesce(p_payment_frequency,'')));
  v_code text;
  v_previous_position uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_collaborators') then
    raise exception 'No autorizado para administrar colaboradores.';
  end if;
  if nullif(trim(coalesce(p_display_name,'')),'') is null or p_hired_at is null then
    raise exception 'Nombre y fecha de ingreso son obligatorios.';
  end if;
  if v_frequency not in ('weekly','biweekly','monthly') then raise exception 'Periodicidad de pago inválida.'; end if;
  if lower(trim(coalesce(p_employment_status,''))) not in ('active','inactive') then raise exception 'Estado de colaborador inválido.'; end if;
  if p_base_pay_amount is null or p_base_pay_amount<0 or p_effective_from is null then raise exception 'Captura el pago base y su vigencia.'; end if;
  if p_position_id is not null and not exists(
    select 1 from public.collaborator_positions p where p.id=p_position_id and p.company_id=p_company_id and p.is_active
  ) then raise exception 'El puesto seleccionado no está disponible.'; end if;

  if p_collaborator_id is null then
    perform pg_advisory_xact_lock(hashtextextended(p_company_id::text,97));
    select 'COL-'||lpad((coalesce(max(nullif(regexp_replace(code,'[^0-9]','','g'),'')::bigint),0)+1)::text,6,'0')
      into v_code from public.collaborators where company_id=p_company_id;
    insert into public.collaborators(company_id,code,display_name,job_title,position_id,employment_status,hired_at,terminated_at,payment_frequency)
    values(p_company_id,v_code,trim(p_display_name),nullif(trim(p_job_title),''),p_position_id,lower(trim(p_employment_status)),p_hired_at,
      case when lower(trim(p_employment_status))='inactive' then p_terminated_at end,v_frequency)
    returning * into v_collaborator;
  else
    if lower(trim(p_employment_status))='inactive' and p_terminated_at is null then raise exception 'La fecha de baja es obligatoria al desactivar un colaborador.'; end if;
    select position_id into v_previous_position from public.collaborators where id=p_collaborator_id and company_id=p_company_id for update;
    if not found then raise exception 'Colaborador no disponible.'; end if;
    update public.collaborators set display_name=trim(p_display_name),job_title=nullif(trim(p_job_title),''),position_id=p_position_id,
      employment_status=lower(trim(p_employment_status)),hired_at=p_hired_at,
      terminated_at=case when lower(trim(p_employment_status))='inactive' then p_terminated_at else null end,payment_frequency=v_frequency
    where id=p_collaborator_id and company_id=p_company_id returning * into v_collaborator;
  end if;

  insert into public.collaborator_compensation_history(company_id,collaborator_id,effective_from,base_pay_amount,reason)
  values(p_company_id,v_collaborator.id,p_effective_from,p_base_pay_amount,nullif(trim(p_reason),''))
  on conflict(collaborator_id,effective_from) do update set base_pay_amount=excluded.base_pay_amount,reason=excluded.reason;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),case when p_collaborator_id is null then 'collaborator.created' else 'collaborator.updated' end,
    'collaborator',v_collaborator.id,jsonb_build_object('code',v_collaborator.code,'position_id',p_position_id,'previous_position_id',v_previous_position,'effective_from',p_effective_from));
  return public.get_collaborator_profile(p_company_id,v_collaborator.id);
end $$;

create or replace function public.search_collaborators(
  p_company_id uuid,p_query text default null,p_status text default null,p_page integer default 1,p_page_size integer default 50
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);v_q text:=lower(trim(coalesce(p_query,'')));v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collaborators') then raise exception 'No autorizado para consultar colaboradores.'; end if;
  with filtered as materialized(
    select c.*,p.code position_code,p.name position_name,h.base_pay_amount,h.effective_from
    from public.collaborators c
    left join public.collaborator_positions p on p.id=c.position_id
    left join lateral(select base_pay_amount,effective_from from public.collaborator_compensation_history h where h.collaborator_id=c.id and h.effective_from<=current_date order by h.effective_from desc limit 1) h on true
    where c.company_id=p_company_id and(p_status is null or c.employment_status=p_status)
      and(v_q=''or lower(c.display_name)like'%'||v_q||'%'or lower(c.code)like'%'||v_q||'%'or lower(coalesce(p.name,c.job_title,''))like'%'||v_q||'%')
  ),paged as(select * from filtered order by employment_status='active' desc,display_name,id limit v_size offset(v_page-1)*v_size)
  select(select count(*)from filtered),coalesce(jsonb_agg(to_jsonb(paged)order by employment_status='active' desc,display_name,id),'[]'::jsonb)into v_total,v_items from paged;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',coalesce(v_total,0)));
end $$;

create or replace function public.get_collaborator_profile(p_company_id uuid,p_collaborator_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,auth as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collaborators') then raise exception 'No autorizado.'; end if;
  select to_jsonb(c)||jsonb_build_object(
    'position_code',p.code,'position_name',p.name,
    'satrapy_access',coalesce(
      (select jsonb_build_object('kind','user','user_id',l.user_id,'email',u.email,'full_name',coalesce(pr.full_name,u.email),'profile_code',r.code,'profile_name',r.display_name,'effective_from',l.effective_from)
       from public.collaborator_user_links l join auth.users u on u.id=l.user_id left join public.profiles pr on pr.id=u.id
       left join lateral(select r.code,r.display_name from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.company_id=p_company_id and ur.user_id=l.user_id and ur.is_active order by ur.updated_at desc limit 1)r on true
       where l.company_id=p_company_id and l.collaborator_id=c.id and l.effective_from<=current_date and(l.effective_to is null or l.effective_to>=current_date)
       order by l.effective_from desc,l.id desc limit 1),
      (select jsonb_build_object('kind','invitation','invitation_id',i.id,'email',i.email,'profile_code',r.code,'profile_name',r.display_name,'created_at',i.created_at)
       from public.company_user_invitations i join public.roles r on r.id=i.role_id
       where i.company_id=p_company_id and i.collaborator_id=c.id and i.status='pending' order by i.created_at desc,i.id desc limit 1)
    ),
    'compensation_history',coalesce((select jsonb_agg(to_jsonb(h)order by h.effective_from desc)from public.collaborator_compensation_history h where h.collaborator_id=c.id),'[]'::jsonb),
    'vacation_balances',coalesce((select jsonb_agg(to_jsonb(v)order by v.calendar_year desc)from public.collaborator_vacation_balances v where v.collaborator_id=c.id),'[]'::jsonb),
    'time_off',coalesce((select jsonb_agg(to_jsonb(t)order by t.starts_on desc)from public.collaborator_time_off t where t.collaborator_id=c.id),'[]'::jsonb),
    'movements',coalesce((select jsonb_agg(to_jsonb(m)order by m.effective_on desc,m.created_at desc)from public.payroll_movements m where m.collaborator_id=c.id),'[]'::jsonb),
    'payroll_history',coalesce((select jsonb_agg(to_jsonb(l)||jsonb_build_object('period_start',pp.starts_on,'period_end',pp.ends_on,'period_status',pp.status,'payment_date',pp.payment_date)order by pp.starts_on desc)from public.payroll_period_lines l join public.payroll_periods pp on pp.id=l.payroll_period_id where l.collaborator_id=c.id),'[]'::jsonb)
  )into v_result
  from public.collaborators c left join public.collaborator_positions p on p.id=c.position_id
  where c.id=p_collaborator_id and c.company_id=p_company_id;
  if v_result is null then raise exception 'Colaborador no encontrado.'; end if;
  return v_result;
end $$;

create or replace function public.provision_collaborator_user_access(
  p_company_id uuid,p_collaborator_id uuid,p_email text,p_profile_code text,p_location_ids uuid[],p_reason text,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare
  v_email text:=lower(trim(p_email));v_user_id uuid;v_role public.roles%rowtype;v_result jsonb;v_expected timestamptz;v_invitation public.company_user_invitations%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_collaborators') or not public.has_company_permission(p_company_id,'manage_company_users') then raise exception 'No autorizado para dar acceso a colaboradores.'; end if;
  if nullif(v_email,'') is null or v_email not like '%@%' then raise exception 'Captura un correo válido.'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null or p_client_request_id is null then raise exception 'El motivo y la referencia idempotente son obligatorios.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||':'||p_collaborator_id::text,0));
  select metadata->'result' into v_result from public.audit_log where company_id=p_company_id and action='collaborator.access_provisioned' and metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_result is not null then return v_result||jsonb_build_object('idempotent',true); end if;
  if not exists(select 1 from public.collaborators where id=p_collaborator_id and company_id=p_company_id and employment_status='active') then raise exception 'El colaborador debe estar activo.'; end if;
  select * into v_role from public.roles where code=p_profile_code and is_assignable;
  if not found then raise exception 'Selecciona un perfil de acceso disponible.'; end if;
  if v_role.code='ingeniero_campo' and not exists(
    select 1 from public.collaborators c join public.collaborator_positions p on p.id=c.position_id
    where c.id=p_collaborator_id and c.company_id=p_company_id and p.code='ingeniero_campo'
  ) then raise exception 'Para dar el perfil de Ingeniero de Campo, asigna primero ese puesto en el expediente.'; end if;
  if exists(select 1 from public.collaborator_user_links l where l.company_id=p_company_id and l.collaborator_id=p_collaborator_id and l.effective_from<=current_date and(l.effective_to is null or l.effective_to>=current_date))
    or exists(select 1 from public.company_user_invitations i where i.company_id=p_company_id and i.collaborator_id=p_collaborator_id and i.status='pending')
  then raise exception 'Este colaborador ya tiene un acceso vigente o una invitación pendiente.'; end if;
  if v_role.code in('sucursal','ingeniero_campo') and coalesce(cardinality(p_location_ids),0)=0 then raise exception 'Selecciona al menos una sucursal para este perfil.'; end if;
  if exists(select 1 from unnest(coalesce(p_location_ids,'{}'::uuid[]))selected(id) left join public.locations l on l.id=selected.id and l.company_id=p_company_id and l.is_active where l.id is null) then raise exception 'Hay sucursales no disponibles en la selección.'; end if;
  select id into v_user_id from auth.users where lower(email)=v_email limit 1;
  if v_user_id is not null then
    if exists(select 1 from public.collaborator_user_links l where l.company_id=p_company_id and l.user_id=v_user_id and l.effective_from<=current_date and(l.effective_to is null or l.effective_to>=current_date)) then raise exception 'Esta cuenta ya está vinculada a otro colaborador.'; end if;
    select max(updated_at) into v_expected from public.user_roles where company_id=p_company_id and user_id=v_user_id;
    perform public.save_company_user_access(p_company_id,v_user_id,v_role.code,p_location_ids,'active',trim(p_reason),v_expected,p_client_request_id);
    insert into public.collaborator_user_links(company_id,collaborator_id,user_id,effective_from,reason,created_by)
    values(p_company_id,p_collaborator_id,v_user_id,current_date,trim(p_reason),auth.uid());
    v_result:=jsonb_build_object('kind','user','user_id',v_user_id,'email',v_email,'profile_code',v_role.code,'profile_name',v_role.display_name,'idempotent',false);
  else
    if exists(select 1 from public.company_user_invitations i where i.company_id=p_company_id and lower(i.email)=v_email and i.status='pending') then raise exception 'Este correo ya tiene un acceso pendiente.'; end if;
    insert into public.company_user_invitations(company_id,collaborator_id,email,role_id,status,reason,created_by)
    values(p_company_id,p_collaborator_id,v_email,v_role.id,'pending',trim(p_reason),auth.uid()) returning * into v_invitation;
    insert into public.company_user_invitation_locations(invitation_id,location_id)
    select v_invitation.id,id from unnest(coalesce(p_location_ids,'{}'::uuid[]))selected(id) on conflict do nothing;
    v_result:=jsonb_build_object('kind','invitation','invitation_id',v_invitation.id,'email',v_email,'profile_code',v_role.code,'profile_name',v_role.display_name,'idempotent',false);
  end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'collaborator.access_provisioned','collaborator',p_collaborator_id,jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'result',v_result));
  return v_result;
end $$;

create or replace function public.complete_pending_user_registration(p_user_id uuid,p_email text,p_full_name text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare v_email text:=lower(trim(p_email));v_count integer;v_default_company uuid;v_invitation public.company_user_invitations%rowtype;
begin
  if auth.role()<>'service_role' then raise exception 'Operación reservada al servidor.'; end if;
  if p_user_id is null or nullif(trim(p_full_name),'') is null then raise exception 'Faltan datos para activar la cuenta.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('pending-registration:'||v_email,0));
  if not exists(select 1 from auth.users where id=p_user_id and lower(email)=v_email) then raise exception 'La identidad no coincide con el acceso pendiente.'; end if;
  select count(*)into v_count from public.company_user_invitations where lower(email)=v_email and status='pending';
  if v_count=0 then raise exception 'No existe un acceso pendiente para este correo.'; end if;
  select company_id into v_default_company from public.company_user_invitations where lower(email)=v_email and status='pending' order by created_at,id limit 1;
  insert into public.profiles(id,full_name,default_company_id)values(p_user_id,trim(p_full_name),v_default_company)
  on conflict(id)do update set full_name=excluded.full_name,default_company_id=coalesce(public.profiles.default_company_id,excluded.default_company_id),updated_at=clock_timestamp();
  update public.user_roles ur set is_active=false where ur.user_id=p_user_id and ur.company_id in(select company_id from public.company_user_invitations where lower(email)=v_email and status='pending');
  insert into public.user_roles(user_id,role_id,company_id,is_active,updated_at)
  select p_user_id,i.role_id,i.company_id,true,clock_timestamp()from public.company_user_invitations i where lower(i.email)=v_email and i.status='pending'
  on conflict(user_id,role_id,company_id)do update set is_active=true,updated_at=clock_timestamp();
  delete from public.user_location_access ula using public.locations l where ula.user_id=p_user_id and ula.location_id=l.id and l.company_id in(select company_id from public.company_user_invitations where lower(email)=v_email and status='pending');
  insert into public.user_location_access(user_id,location_id)
  select p_user_id,il.location_id from public.company_user_invitations i join public.company_user_invitation_locations il on il.invitation_id=i.id where lower(i.email)=v_email and i.status='pending' on conflict do nothing;
  for v_invitation in select * from public.company_user_invitations where lower(email)=v_email and status='pending' and collaborator_id is not null loop
    if exists(select 1 from public.collaborator_user_links l where l.company_id=v_invitation.company_id and(l.collaborator_id=v_invitation.collaborator_id or l.user_id=p_user_id)and l.effective_from<=current_date and(l.effective_to is null or l.effective_to>=current_date)) then
      raise exception 'El colaborador o la cuenta ya tiene un vínculo vigente.';
    end if;
    insert into public.collaborator_user_links(company_id,collaborator_id,user_id,effective_from,reason,created_by)
    values(v_invitation.company_id,v_invitation.collaborator_id,p_user_id,current_date,'Vínculo activado al completar el registro.',p_user_id);
  end loop;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  select i.company_id,p_user_id,'company.user_registration_completed','user',p_user_id,jsonb_build_object('invitation_id',i.id,'email',v_email,'role_id',i.role_id,'collaborator_id',i.collaborator_id)
  from public.company_user_invitations i where lower(i.email)=v_email and i.status='pending';
  update public.company_user_invitations set status='claimed',claimed_by=p_user_id,claimed_at=clock_timestamp() where lower(email)=v_email and status='pending';
  return jsonb_build_object('activated',true,'company_count',v_count);
end $$;

create or replace function public.list_company_users(
  p_company_id uuid,p_query text default null,p_role_code text default null,
  p_status text default null,p_page integer default 1,p_page_size integer default 25
) returns jsonb language plpgsql stable security definer set search_path=public,auth as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_company_users') then raise exception 'No autorizado para administrar usuarios.';end if;
  if p_status is not null and p_status not in('active','invited','suspended') then raise exception 'Estado de usuario inválido.';end if;
  with members as(
    select ur.user_id,bool_or(ur.is_active)active,max(ur.updated_at)updated_at from public.user_roles ur where ur.company_id=p_company_id group by ur.user_id
  ),user_details as(
    select 'user'::text record_type,m.user_id,null::uuid invitation_id,u.email,coalesce(nullif(trim(pr.full_name),''),split_part(u.email,'@',1))full_name,
      role_data.code role_code,role_data.display_name role_name,role_data.is_assignable role_assignable,
      case when not m.active then 'suspended' when u.last_sign_in_at is null then 'invited' else 'active' end status,u.created_at invited_at,u.last_sign_in_at,m.updated_at,
      coalesce(location_data.locations,'[]'::jsonb)locations,collaborator_data.collaborator
    from members m join auth.users u on u.id=m.user_id left join public.profiles pr on pr.id=m.user_id
    left join lateral(select r.code,r.display_name,r.is_assignable from public.user_roles ur2 join public.roles r on r.id=ur2.role_id where ur2.company_id=p_company_id and ur2.user_id=m.user_id order by ur2.is_active desc,ur2.updated_at desc,ur2.created_at desc limit 1)role_data on true
    left join lateral(select coalesce(jsonb_agg(jsonb_build_object('id',l.id,'code',l.external_code,'name',l.name)order by l.name,l.id),'[]'::jsonb)locations from public.user_location_access ula join public.locations l on l.id=ula.location_id where ula.user_id=m.user_id and l.company_id=p_company_id)location_data on true
    left join lateral(select jsonb_build_object('id',c.id,'code',c.code,'name',c.display_name)collaborator from public.collaborator_user_links link join public.collaborators c on c.id=link.collaborator_id where link.company_id=p_company_id and link.user_id=m.user_id and link.effective_from<=current_date and(link.effective_to is null or link.effective_to>=current_date)order by link.effective_from desc,link.id desc limit 1)collaborator_data on true
  ),invitation_details as(
    select 'invitation'::text record_type,null::uuid user_id,i.id invitation_id,i.email,'Pendiente de registro'::text full_name,r.code role_code,r.display_name role_name,r.is_assignable role_assignable,
      case when i.status='pending' then 'invited' else 'suspended' end status,i.created_at invited_at,null::timestamptz last_sign_in_at,i.updated_at,
      coalesce(location_data.locations,'[]'::jsonb)locations,case when c.id is null then null::jsonb else jsonb_build_object('id',c.id,'code',c.code,'name',c.display_name)end collaborator
    from public.company_user_invitations i join public.roles r on r.id=i.role_id left join public.collaborators c on c.id=i.collaborator_id
    left join lateral(select coalesce(jsonb_agg(jsonb_build_object('id',l.id,'code',l.external_code,'name',l.name)order by l.name,l.id),'[]'::jsonb)locations from public.company_user_invitation_locations il join public.locations l on l.id=il.location_id where il.invitation_id=i.id)location_data on true
    where i.company_id=p_company_id and i.status in('pending','cancelled')
  ),filtered as(
    select * from(select * from user_details union all select * from invitation_details)s where(nullif(trim(p_query),'')is null or email ilike'%'||trim(p_query)||'%'or full_name ilike'%'||trim(p_query)||'%')and(p_role_code is null or role_code=p_role_code)and(p_status is null or status=p_status)
  )
  select count(*),coalesce((select jsonb_agg(to_jsonb(x)order by x.full_name,x.email)from(select * from filtered order by full_name,email limit v_size offset(v_page-1)*v_size)x),'[]'::jsonb)into v_total,v_items from filtered;
  return jsonb_build_object('items',v_items,'total',v_total,'page',v_page,'page_size',v_size);
end $$;

create or replace function public.bi_search_budget_scope_options(
  p_company_id uuid,p_scope text,p_query text default null,p_page integer default 1,p_page_size integer default 20
)returns jsonb language plpgsql stable security definer set search_path=public as $$
declare q text:=lower(trim(coalesce(p_query,'')));v_page integer:=greatest(p_page,1);v_size integer:=least(greatest(p_page_size,1),50);v_total bigint;items jsonb;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'create_bi_budget_drafts')then raise exception'No autorizado para consultar alcances.';end if;
  if p_scope='location'then
    select count(*)into v_total from public.locations l where l.company_id=p_company_id and l.is_active and public.can_access_location(l.id)and(q=''or lower(l.name)like'%'||q||'%'or lower(l.external_code)like'%'||q||'%');
    select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'label',x.name,'secondary',x.external_code)order by x.name,x.id),'[]'::jsonb)into items from(select l.id,l.name,l.external_code from public.locations l where l.company_id=p_company_id and l.is_active and public.can_access_location(l.id)and(q=''or lower(l.name)like'%'||q||'%'or lower(l.external_code)like'%'||q||'%')order by l.name,l.id limit v_size offset(v_page-1)*v_size)x;
  elsif p_scope='responsible'then
    select count(*)into v_total from public.collaborators c join public.collaborator_positions p on p.id=c.position_id and p.code='ingeniero_campo'
    where c.company_id=p_company_id and c.employment_status='active'and exists(select 1 from public.collaborator_user_links l join public.user_roles ur on ur.company_id=l.company_id and ur.user_id=l.user_id and ur.is_active join public.roles r on r.id=ur.role_id and r.code='ingeniero_campo' where l.company_id=p_company_id and l.collaborator_id=c.id and l.effective_from<=current_date and(l.effective_to is null or l.effective_to>=current_date))and(q=''or lower(c.display_name)like'%'||q||'%'or lower(c.code)like'%'||q||'%');
    select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'label',x.display_name,'secondary',x.code)order by x.display_name,x.id),'[]'::jsonb)into items from(select c.id,c.display_name,c.code from public.collaborators c join public.collaborator_positions p on p.id=c.position_id and p.code='ingeniero_campo' where c.company_id=p_company_id and c.employment_status='active'and exists(select 1 from public.collaborator_user_links l join public.user_roles ur on ur.company_id=l.company_id and ur.user_id=l.user_id and ur.is_active join public.roles r on r.id=ur.role_id and r.code='ingeniero_campo' where l.company_id=p_company_id and l.collaborator_id=c.id and l.effective_from<=current_date and(l.effective_to is null or l.effective_to>=current_date))and(q=''or lower(c.display_name)like'%'||q||'%'or lower(c.code)like'%'||q||'%')order by c.display_name,c.id limit v_size offset(v_page-1)*v_size)x;
  elsif p_scope='category'then
    select count(*)into v_total from public.product_categories c where c.company_id=p_company_id and(q=''or lower(c.name)like'%'||q||'%'or lower(c.external_code)like'%'||q||'%');
    select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'label',x.name,'secondary',x.external_code)order by x.name,x.id),'[]'::jsonb)into items from(select c.id,c.name,c.external_code from public.product_categories c where c.company_id=p_company_id and(q=''or lower(c.name)like'%'||q||'%'or lower(c.external_code)like'%'||q||'%')order by c.name,c.id limit v_size offset(v_page-1)*v_size)x;
  else raise exception'Tipo de alcance inválido.';end if;
  return jsonb_build_object('items',items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end $$;

create or replace function public.bi_validate_budget_version()
returns trigger language plpgsql set search_path=public as $$
declare v_company uuid;v_start date;v_end date;v_as_of date;
begin
  select company_id into v_company from public.bi_budgets where id=new.budget_id;
  if v_company is null or v_company<>new.company_id then raise exception 'El presupuesto no pertenece a la empresa.';end if;
  if new.location_id is not null and not exists(select 1 from public.locations where id=new.location_id and company_id=new.company_id)then raise exception'Ubicación canónica inválida.';end if;
  if new.collaborator_id is not null and not exists(select 1 from public.collaborators where id=new.collaborator_id and company_id=new.company_id)then raise exception'Responsable canónico inválido.';end if;
  if new.category_id is not null and not exists(select 1 from public.product_categories where id=new.category_id and company_id=new.company_id)then raise exception'Categoría canónica inválida.';end if;
  if new.period_type='monthly'then v_start:=date_trunc('month',new.period_start)::date;v_end:=(v_start+interval'1 month'-interval'1 day')::date;elsif new.period_type='quarterly'then v_start:=date_trunc('quarter',new.period_start)::date;v_end:=(v_start+interval'3 months'-interval'1 day')::date;else v_start:=date_trunc('year',new.period_start)::date;v_end:=(v_start+interval'1 year'-interval'1 day')::date;end if;
  if new.period_start<>v_start or new.period_end<>v_end then raise exception'El periodo no coincide con el tipo seleccionado.';end if;
  v_as_of:=least(current_date,new.period_end);
  if new.scope_type in('responsible','responsible_category')and not exists(
    select 1 from public.collaborators c join public.collaborator_positions p on p.id=c.position_id and p.code='ingeniero_campo'
    join public.collaborator_user_links l on l.company_id=c.company_id and l.collaborator_id=c.id and l.effective_from<=v_as_of and(l.effective_to is null or l.effective_to>=v_as_of)
    join public.user_roles ur on ur.company_id=l.company_id and ur.user_id=l.user_id and ur.is_active join public.roles r on r.id=ur.role_id and r.code='ingeniero_campo'
    where c.id=new.collaborator_id and c.company_id=new.company_id and c.employment_status='active'
  )then raise exception'El responsable debe ser un Ingeniero de Campo activo con cuenta y perfil vigentes.';end if;
  if tg_op='UPDATE'and old.status in('approved','superseded')and not(old.status='approved'and new.status='superseded'and(to_jsonb(new)-'status'-'updated_at')=(to_jsonb(old)-'status'-'updated_at'))and to_jsonb(new)is distinct from to_jsonb(old)then raise exception'Una versión aprobada no puede modificarse destructivamente.';end if;
  return new;
end $$;

revoke all on function public.get_collaborator_position_options(uuid),public.save_collaborator(uuid,uuid,text,text,text,text,date,date,text,numeric,date,text,uuid),public.provision_collaborator_user_access(uuid,uuid,text,text,uuid[],text,uuid) from public;
grant execute on function public.get_collaborator_position_options(uuid),public.save_collaborator(uuid,uuid,text,text,text,text,date,date,text,numeric,date,text,uuid),public.provision_collaborator_user_access(uuid,uuid,text,text,uuid[],text,uuid) to authenticated;

notify pgrst, 'reload schema';
