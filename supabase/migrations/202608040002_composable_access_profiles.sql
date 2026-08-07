-- Satrapy · Perfiles de acceso combinables.
-- Reutiliza roles y permisos como fuente única. Los perfiles existentes conservan
-- exactamente sus permisos; esta migración solo habilita composición y perfiles
-- especializados para separar operación, aprobación y pago.

alter table public.roles drop constraint if exists roles_code_check;
alter table public.roles add column if not exists company_id uuid references public.companies(id) on delete cascade;
alter table public.roles add column if not exists category text not null default 'general';
alter table public.roles add column if not exists scope_kind text not null default 'company';
alter table public.roles add column if not exists is_system boolean not null default true;
alter table public.roles add column if not exists updated_at timestamptz not null default now();

do $$ begin
  alter table public.roles add constraint roles_scope_kind_check check(scope_kind in('company','locations'));
exception when duplicate_object then null; end $$;

create unique index if not exists roles_company_display_name_uidx
  on public.roles(company_id,lower(display_name)) where company_id is not null;
create index if not exists roles_company_assignable_idx
  on public.roles(company_id,is_assignable,category,display_name);

update public.roles set category=case
  when code in('direccion_admin','super_admin') then 'administration'
  when code in('sucursal','punto_venta','supervisor_sucursal') then 'sales'
  when code='almacen' then 'inventory'
  when code='ingeniero_campo' then 'field_service'
  else category end,
  scope_kind=case when code in('sucursal','ingeniero_campo','punto_venta','supervisor_sucursal') then 'locations' else 'company' end,
  is_system=true
where company_id is null;

update public.roles set description='Administra toda la información de la empresa.',updated_at=clock_timestamp()
where code='direccion_admin' and company_id is null;

insert into public.roles(code,display_name,description,is_assignable,category,scope_kind,is_system) values
  ('payroll_capture_review','Captura de nómina','Registra y revisa incidencias de nómina sin preparar, aprobar ni pagar corridas.',true,'payroll','company',true),
  ('payroll_preparation','Preparación de nómina','Prepara y revisa periodos de nómina sin aprobarlos ni registrar su pago.',true,'payroll','company',true),
  ('payroll_approval','Aprobación de nómina','Aprueba corridas de nómina ya preparadas.',true,'payroll','company',true),
  ('payroll_payment','Pago de nómina','Registra el pago de corridas previamente aprobadas.',true,'payroll','company',true),
  ('procurement_operations','Operación de compras','Captura necesidades, cotizaciones y recomendaciones; no aprueba adjudicaciones.',true,'procurement','company',true),
  ('procurement_approval','Aprobación de compras','Revisa y aprueba adjudicaciones y órdenes de compra.',true,'procurement','company',true)
on conflict(code) do update set display_name=excluded.display_name,description=excluded.description,
  is_assignable=excluded.is_assignable,category=excluded.category,scope_kind=excluded.scope_kind,is_system=true,updated_at=clock_timestamp();

with profile_permissions(profile_code,permission_code) as(values
  ('payroll_capture_review','view_collaborators'),
  ('payroll_capture_review','manage_payroll_movements'),
  ('payroll_preparation','view_collaborators'),
  ('payroll_preparation','manage_payroll_runs'),
  ('payroll_approval','view_collaborators'),
  ('payroll_approval','approve_payroll_runs'),
  ('payroll_payment','view_collaborators'),
  ('payroll_payment','mark_payroll_paid'),
  ('procurement_operations','view_procurement'),
  ('procurement_operations','create_procurement_requisitions'),
  ('procurement_operations','manage_procurement_quotes'),
  ('procurement_operations','recommend_procurement_awards'),
  ('procurement_operations','view_purchase_orders'),
  ('procurement_operations','create_purchase_orders'),
  ('procurement_operations','edit_purchase_orders'),
  ('procurement_operations','submit_purchase_orders'),
  ('procurement_approval','view_procurement'),
  ('procurement_approval','approve_procurement_awards'),
  ('procurement_approval','view_purchase_orders'),
  ('procurement_approval','approve_purchase_orders'),
  ('procurement_approval','reject_purchase_orders')
)
insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from profile_permissions x join public.roles r on r.code=x.profile_code
join public.permissions p on p.code=x.permission_code on conflict do nothing;

create table if not exists public.company_user_invitation_roles(
  invitation_id uuid not null references public.company_user_invitations(id) on delete cascade,
  role_id uuid not null references public.roles(id),
  primary key(invitation_id,role_id)
);
alter table public.company_user_invitation_roles enable row level security;
insert into public.company_user_invitation_roles(invitation_id,role_id)
select id,role_id from public.company_user_invitations on conflict do nothing;

create or replace function public.access_profile_warnings(p_role_codes text[])
returns jsonb language sql immutable set search_path=public as $$
  with selected(code) as(select distinct unnest(coalesce(p_role_codes,'{}'::text[]))), warnings(message) as(
    select 'La misma persona podrá capturar incidencias y aprobar nómina.' where exists(select 1 from selected where code='payroll_capture_review') and exists(select 1 from selected where code='payroll_approval')
    union all
    select 'La misma persona podrá preparar y aprobar la nómina.' where exists(select 1 from selected where code='payroll_preparation') and exists(select 1 from selected where code='payroll_approval')
    union all
    select 'La misma persona podrá operar y aprobar compras.' where exists(select 1 from selected where code='procurement_operations') and exists(select 1 from selected where code='procurement_approval')
  ) select coalesce(jsonb_agg(message),'[]'::jsonb) from warnings;
$$;

create or replace function public.can_access_location(target_location_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_super_admin()
    or exists(
      select 1 from public.locations l join public.user_roles ur on ur.company_id=l.company_id and ur.user_id=auth.uid() and ur.is_active
      join public.roles r on r.id=ur.role_id where l.id=target_location_id and r.scope_kind='company'
    )
    or exists(
      select 1 from public.user_location_access ula join public.locations l on l.id=ula.location_id
      join public.user_roles ur on ur.company_id=l.company_id and ur.user_id=ula.user_id and ur.is_active
      join public.roles r on r.id=ur.role_id and r.scope_kind='locations'
      where ula.user_id=auth.uid() and ula.location_id=target_location_id
    );
$$;

-- Administrar usuarios es una capacidad reservada: no puede heredarse desde
-- perfiles personalizados aunque se inserte manualmente en role_permissions.
create or replace function public.has_company_permission(target_company_id uuid,requested_permission text)
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_super_admin()
    or (requested_permission='manage_company_users' and exists(
      select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id
      where ur.user_id=auth.uid() and ur.company_id=target_company_id and ur.is_active and r.code='direccion_admin'
    ))
    or (requested_permission<>'manage_company_users' and exists(
      select 1 from public.user_roles ur join public.role_permissions rp on rp.role_id=ur.role_id
      join public.permissions p on p.id=rp.permission_id
      where ur.user_id=auth.uid() and ur.company_id=target_company_id and ur.is_active and p.code=requested_permission
    ));
$$;

create or replace function public.get_company_user_access_options(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_roles jsonb;v_locations jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_company_users') then raise exception 'No autorizado para administrar usuarios.';end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'code',r.code,'name',r.display_name,'description',r.description,'category',r.category,
    'scope_kind',r.scope_kind,'is_system',r.is_system,'permission_count',coalesce(pc.permission_count,0)
  ) order by case r.category when 'administration' then 1 when 'sales' then 2 when 'inventory' then 3 when 'payroll' then 4 when 'procurement' then 5 else 9 end,r.display_name),'[]'::jsonb)
  into v_roles from public.roles r left join lateral(select count(*) permission_count from public.role_permissions rp where rp.role_id=r.id)pc on true
  where r.is_assignable and (r.company_id is null or r.company_id=p_company_id);
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'code',external_code,'name',name,'type',location_type) order by name,id),'[]'::jsonb)
  into v_locations from public.locations where company_id=p_company_id and is_active;
  return jsonb_build_object('roles',v_roles,'locations',v_locations);
end $$;

create or replace function public.list_access_profiles(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_profiles jsonb;v_permissions jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_company_users') then raise exception 'No autorizado para administrar usuarios.';end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'code',r.code,'name',r.display_name,'description',r.description,'category',r.category,'scope_kind',r.scope_kind,
    'is_system',r.is_system,'updated_at',r.updated_at,'permission_count',coalesce(x.permission_count,0),
    'assignee_count',coalesce(a.assignee_count,0),'permissions',coalesce(x.permissions,'[]'::jsonb)
  ) order by r.category,r.display_name),'[]'::jsonb) into v_profiles
  from public.roles r
  left join lateral(select count(*) permission_count,jsonb_agg(p.code order by p.code) permissions from public.role_permissions rp join public.permissions p on p.id=rp.permission_id where rp.role_id=r.id)x on true
  left join lateral(select count(distinct ur.user_id) assignee_count from public.user_roles ur where ur.role_id=r.id and ur.company_id=p_company_id and ur.is_active)a on true
  where r.is_assignable and (r.company_id is null or r.company_id=p_company_id);
  select coalesce(jsonb_agg(jsonb_build_object('code',code,'description',description,'category',
    case when code like '%payroll%' or code in('view_collaborators','manage_collaborators') then 'payroll'
      when code like '%purchase%' or code like '%procurement%' or code like '%supplier%' then 'procurement'
      when code like '%inventory%' or code like '%product%' or code like '%location%' then 'inventory'
      when code like '%sale%' or code like '%customer%' or code like '%quote%' or code like '%pos%' then 'sales'
      when code like '%account%' or code like '%journal%' or code like '%financial%' or code like '%close%' then 'accounting'
      else 'general' end) order by code),'[]'::jsonb) into v_permissions from public.permissions;
  return jsonb_build_object('profiles',v_profiles,'permissions',v_permissions);
end $$;

create or replace function public.save_access_profile(
  p_company_id uuid,p_profile_id uuid,p_name text,p_description text,p_permission_codes text[],p_scope_kind text,
  p_reason text,p_expected_updated_at timestamptz,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_profile public.roles%rowtype;v_code text;v_result jsonb;v_permission_codes text[];
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_company_users') then raise exception 'No autorizado para administrar usuarios.';end if;
  if nullif(trim(p_name),'') is null or nullif(trim(p_description),'') is null then raise exception 'Captura nombre y descripción del perfil.';end if;
  if p_scope_kind not in('company','locations') then raise exception 'Selecciona un alcance válido.';end if;
  if nullif(trim(p_reason),'') is null or p_client_request_id is null then raise exception 'El motivo y la referencia son obligatorios.';end if;
  select array_agg(distinct code order by code) into v_permission_codes from unnest(coalesce(p_permission_codes,'{}'::text[])) code;
  if coalesce(cardinality(v_permission_codes),0)=0 then raise exception 'Selecciona al menos un permiso.';end if;
  if exists(select 1 from unnest(v_permission_codes) x(code) left join public.permissions p using(code) where p.id is null) then raise exception 'La selección contiene permisos no disponibles.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||':access-profiles',0));
  select metadata->'result' into v_result from public.audit_log where company_id=p_company_id and action='access.profile_saved' and metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_result is not null then return v_result||jsonb_build_object('idempotent',true);end if;
  if p_profile_id is null then
    v_code:='custom_'||replace(gen_random_uuid()::text,'-','');
    insert into public.roles(code,display_name,description,is_assignable,company_id,category,scope_kind,is_system)
    values(v_code,trim(p_name),trim(p_description),true,p_company_id,'custom',p_scope_kind,false) returning * into v_profile;
  else
    select * into v_profile from public.roles where id=p_profile_id and company_id=p_company_id and not is_system for update;
    if not found then raise exception 'Solo puedes editar perfiles personalizados de esta empresa.';end if;
    if p_expected_updated_at is null or v_profile.updated_at<>p_expected_updated_at then raise exception 'El perfil cambió mientras lo editabas. Actualiza y vuelve a intentarlo.';end if;
    update public.roles set display_name=trim(p_name),description=trim(p_description),scope_kind=p_scope_kind,updated_at=clock_timestamp() where id=v_profile.id returning * into v_profile;
  end if;
  delete from public.role_permissions where role_id=v_profile.id;
  insert into public.role_permissions(role_id,permission_id) select v_profile.id,p.id from public.permissions p where p.code=any(v_permission_codes);
  v_result:=jsonb_build_object('profile_id',v_profile.id,'code',v_profile.code,'name',v_profile.display_name,'updated_at',v_profile.updated_at,'permission_count',cardinality(v_permission_codes),'idempotent',false);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values
    (p_company_id,auth.uid(),'access.profile_saved','role',v_profile.id,jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'permissions',v_permission_codes,'result',v_result));
  return v_result;
end $$;

create unique index if not exists audit_access_profile_request_uidx on public.audit_log(company_id,(metadata->>'request_id'))
where action='access.profile_saved' and metadata ? 'request_id';

create or replace function public.save_company_user_access_profiles(
  p_company_id uuid,p_user_id uuid,p_role_codes text[],p_location_ids uuid[],p_status text,
  p_reason text,p_expected_updated_at timestamptz,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare v_current_updated timestamptz;v_existing boolean;v_was_admin boolean;v_has_admin boolean;v_result jsonb;v_email text;
  v_status text:=coalesce(p_status,'active');v_role_codes text[];v_has_scoped boolean;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_company_users') then raise exception 'No autorizado para administrar usuarios.';end if;
  if p_user_id is null or p_user_id=auth.uid() then raise exception 'No puedes modificar tu propio acceso.';end if;
  if v_status not in('active','suspended') then raise exception 'Estado de usuario inválido.';end if;
  if nullif(trim(p_reason),'') is null or p_client_request_id is null then raise exception 'El motivo y la referencia son obligatorios.';end if;
  select array_agg(distinct code order by code) into v_role_codes from unnest(coalesce(p_role_codes,'{}'::text[])) code;
  if v_status='active' and coalesce(cardinality(v_role_codes),0)=0 then raise exception 'Selecciona al menos un perfil.';end if;
  if exists(select 1 from unnest(coalesce(v_role_codes,'{}'::text[])) x(code) left join public.roles r on r.code=x.code and r.is_assignable and (r.company_id is null or r.company_id=p_company_id) where r.id is null) then raise exception 'La selección contiene perfiles no disponibles.';end if;
  select exists(select 1 from public.roles where code=any(coalesce(v_role_codes,'{}'::text[])) and scope_kind='locations'),
    'direccion_admin'=any(coalesce(v_role_codes,'{}'::text[])) into v_has_scoped,v_has_admin;
  if v_status='active' and v_has_scoped and coalesce(cardinality(p_location_ids),0)=0 then raise exception 'Selecciona al menos una sucursal para los perfiles con alcance local.';end if;
  if exists(select 1 from unnest(coalesce(p_location_ids,'{}'::uuid[])) x(id) left join public.locations l on l.id=x.id and l.company_id=p_company_id and l.is_active where l.id is null) then raise exception 'Hay sucursales no disponibles en la selección.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||':'||p_user_id::text,0));
  select metadata->'result' into v_result from public.audit_log where company_id=p_company_id and action='company.user_access_saved' and metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_result is not null then return v_result||jsonb_build_object('idempotent',true);end if;
  select email into v_email from auth.users where id=p_user_id;if not found then raise exception 'El usuario ya no está disponible.';end if;
  select max(ur.updated_at),count(*)>0,bool_or(ur.is_active and r.code='direccion_admin') into v_current_updated,v_existing,v_was_admin
  from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.company_id=p_company_id and ur.user_id=p_user_id;
  if v_existing and(p_expected_updated_at is null or v_current_updated<>p_expected_updated_at) then raise exception 'El acceso cambió mientras lo editabas. Actualiza y vuelve a intentarlo.';end if;
  if v_was_admin and(v_status='suspended' or not v_has_admin) and(select count(distinct ur.user_id) from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.company_id=p_company_id and ur.is_active and r.code='direccion_admin')<=1 then raise exception 'La empresa debe conservar al menos un Administrador general activo.';end if;
  update public.user_roles set is_active=false where company_id=p_company_id and user_id=p_user_id and is_active;
  delete from public.user_location_access ula using public.locations l where ula.location_id=l.id and l.company_id=p_company_id and ula.user_id=p_user_id;
  if v_status='active' then
    insert into public.user_roles(user_id,role_id,company_id,is_active,updated_at)
    select p_user_id,r.id,p_company_id,true,clock_timestamp() from public.roles r where r.code=any(v_role_codes)
    on conflict(user_id,role_id,company_id) do update set is_active=true,updated_at=clock_timestamp();
    if v_has_scoped then insert into public.user_location_access(user_id,location_id) select p_user_id,id from unnest(p_location_ids)x(id) on conflict do nothing;end if;
  end if;
  select jsonb_build_object('user_id',p_user_id,'email',v_email,'role_codes',coalesce(to_jsonb(v_role_codes),'[]'::jsonb),'status',v_status,
    'location_ids',case when v_status='active' and v_has_scoped then to_jsonb(p_location_ids) else '[]'::jsonb end,
    'warnings',public.access_profile_warnings(v_role_codes),'updated_at',max(ur.updated_at),'idempotent',false) into v_result
  from public.user_roles ur where ur.company_id=p_company_id and ur.user_id=p_user_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values
    (p_company_id,auth.uid(),'company.user_access_saved','user',p_user_id,jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'result',v_result));
  return v_result;
end $$;

create or replace function public.save_company_user_invitation_profiles(
  p_company_id uuid,p_invitation_id uuid,p_email text,p_role_codes text[],p_location_ids uuid[],p_status text,
  p_reason text,p_expected_updated_at timestamptz,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare v_invitation public.company_user_invitations%rowtype;v_email text:=lower(trim(p_email));v_role_codes text[];v_primary_role uuid;
  v_target_status text:=case when coalesce(p_status,'active')='suspended' then 'cancelled' else 'pending' end;v_has_scoped boolean;v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_company_users') then raise exception 'No autorizado para administrar usuarios.';end if;
  if v_email is null or v_email='' or v_email not like '%@%' then raise exception 'Captura un correo válido.';end if;
  if nullif(trim(p_reason),'') is null or p_client_request_id is null then raise exception 'El motivo y la referencia son obligatorios.';end if;
  select array_agg(distinct code order by code) into v_role_codes from unnest(coalesce(p_role_codes,'{}'::text[])) code;
  if coalesce(cardinality(v_role_codes),0)=0 then raise exception 'Selecciona al menos un perfil.';end if;
  if exists(select 1 from unnest(v_role_codes)x(code) left join public.roles r on r.code=x.code and r.is_assignable and(r.company_id is null or r.company_id=p_company_id) where r.id is null) then raise exception 'La selección contiene perfiles no disponibles.';end if;
  select min(id),bool_or(scope_kind='locations') into v_primary_role,v_has_scoped from public.roles where code=any(v_role_codes);
  if v_has_scoped and coalesce(cardinality(p_location_ids),0)=0 then raise exception 'Selecciona al menos una sucursal para los perfiles con alcance local.';end if;
  if exists(select 1 from unnest(coalesce(p_location_ids,'{}'::uuid[]))x(id) left join public.locations l on l.id=x.id and l.company_id=p_company_id and l.is_active where l.id is null) then raise exception 'Hay sucursales no disponibles en la selección.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||':'||v_email,0));
  select metadata->'result' into v_result from public.audit_log where company_id=p_company_id and action='company.user_invitation_saved' and metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_result is not null then return v_result||jsonb_build_object('idempotent',true);end if;
  if exists(select 1 from auth.users where lower(email)=v_email) and p_invitation_id is null then raise exception 'El correo ya tiene cuenta. Agrégalo como usuario existente.';end if;
  if p_invitation_id is null then
    if exists(select 1 from public.company_user_invitations where company_id=p_company_id and lower(email)=v_email and status='pending') then raise exception 'Este correo ya tiene un acceso pendiente.';end if;
    insert into public.company_user_invitations(company_id,email,role_id,status,reason,created_by) values(p_company_id,v_email,v_primary_role,v_target_status,trim(p_reason),auth.uid()) returning * into v_invitation;
  else
    select * into v_invitation from public.company_user_invitations where id=p_invitation_id and company_id=p_company_id and status in('pending','cancelled') for update;
    if not found then raise exception 'El acceso pendiente ya no está disponible.';end if;
    if p_expected_updated_at is null or v_invitation.updated_at<>p_expected_updated_at then raise exception 'El acceso cambió mientras lo editabas. Actualiza y vuelve a intentarlo.';end if;
    update public.company_user_invitations set email=v_email,role_id=v_primary_role,status=v_target_status,reason=trim(p_reason) where id=v_invitation.id returning * into v_invitation;
  end if;
  delete from public.company_user_invitation_roles where invitation_id=v_invitation.id;
  insert into public.company_user_invitation_roles(invitation_id,role_id) select v_invitation.id,r.id from public.roles r where r.code=any(v_role_codes);
  delete from public.company_user_invitation_locations where invitation_id=v_invitation.id;
  if v_has_scoped then insert into public.company_user_invitation_locations(invitation_id,location_id) select v_invitation.id,id from unnest(p_location_ids)x(id) on conflict do nothing;end if;
  v_result:=jsonb_build_object('invitation_id',v_invitation.id,'email',v_email,'role_codes',to_jsonb(v_role_codes),'status',case when v_invitation.status='pending' then 'invited' else 'suspended' end,'location_ids',case when v_has_scoped then to_jsonb(p_location_ids) else '[]'::jsonb end,'warnings',public.access_profile_warnings(v_role_codes),'updated_at',v_invitation.updated_at,'idempotent',false);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'company.user_invitation_saved','company_user_invitation',v_invitation.id,jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'result',v_result));
  return v_result;
end $$;

create or replace function public.complete_pending_user_registration(p_user_id uuid,p_email text,p_full_name text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare v_email text:=lower(trim(p_email));v_count integer;v_default_company uuid;
begin
  if auth.role()<>'service_role' then raise exception 'Operación reservada al servidor.';end if;
  if p_user_id is null or nullif(trim(p_full_name),'') is null then raise exception 'Faltan datos para activar la cuenta.';end if;
  perform pg_advisory_xact_lock(hashtextextended('pending-registration:'||v_email,0));
  if not exists(select 1 from auth.users where id=p_user_id and lower(email)=v_email) then raise exception 'La identidad no coincide con el acceso pendiente.';end if;
  select count(*) into v_count from public.company_user_invitations where lower(email)=v_email and status='pending';
  if v_count=0 then raise exception 'No existe un acceso pendiente para este correo.';end if;
  select company_id into v_default_company from public.company_user_invitations where lower(email)=v_email and status='pending' order by created_at,id limit 1;
  insert into public.profiles(id,full_name,default_company_id) values(p_user_id,trim(p_full_name),v_default_company)
  on conflict(id) do update set full_name=excluded.full_name,default_company_id=coalesce(public.profiles.default_company_id,excluded.default_company_id),updated_at=clock_timestamp();
  update public.user_roles ur set is_active=false where ur.user_id=p_user_id and ur.company_id in(select company_id from public.company_user_invitations where lower(email)=v_email and status='pending');
  insert into public.user_roles(user_id,role_id,company_id,is_active,updated_at)
  select p_user_id,ir.role_id,i.company_id,true,clock_timestamp() from public.company_user_invitations i join public.company_user_invitation_roles ir on ir.invitation_id=i.id where lower(i.email)=v_email and i.status='pending'
  on conflict(user_id,role_id,company_id) do update set is_active=true,updated_at=clock_timestamp();
  delete from public.user_location_access ula using public.locations l where ula.user_id=p_user_id and ula.location_id=l.id and l.company_id in(select company_id from public.company_user_invitations where lower(email)=v_email and status='pending');
  insert into public.user_location_access(user_id,location_id) select p_user_id,il.location_id from public.company_user_invitations i join public.company_user_invitation_locations il on il.invitation_id=i.id where lower(i.email)=v_email and i.status='pending' on conflict do nothing;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  select i.company_id,p_user_id,'company.user_registration_completed','user',p_user_id,jsonb_build_object('invitation_id',i.id,'email',v_email,'role_ids',(select jsonb_agg(ir.role_id) from public.company_user_invitation_roles ir where ir.invitation_id=i.id)) from public.company_user_invitations i where lower(i.email)=v_email and i.status='pending';
  update public.company_user_invitations set status='claimed',claimed_by=p_user_id,claimed_at=clock_timestamp() where lower(email)=v_email and status='pending';
  return jsonb_build_object('activated',true,'company_count',v_count);
end $$;

create or replace function public.list_company_users(
  p_company_id uuid,p_query text default null,p_role_code text default null,p_status text default null,p_page integer default 1,p_page_size integer default 25
) returns jsonb language plpgsql stable security definer set search_path=public,auth as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_company_users') then raise exception 'No autorizado para administrar usuarios.';end if;
  if p_status is not null and p_status not in('active','invited','suspended') then raise exception 'Estado de usuario inválido.';end if;
  with members as(select ur.user_id,bool_or(ur.is_active) active,max(ur.updated_at) updated_at from public.user_roles ur where ur.company_id=p_company_id group by ur.user_id),
  user_details as(
    select 'user'::text record_type,m.user_id,null::uuid invitation_id,u.email,coalesce(nullif(trim(p.full_name),''),split_part(u.email,'@',1)) full_name,
      coalesce(rd.roles,'[]'::jsonb) roles,coalesce(rd.role_codes,'{}'::text[]) role_codes,rd.primary_code role_code,rd.primary_name role_name,coalesce(rd.all_assignable,false) role_assignable,
      case when not m.active then 'suspended' when u.last_sign_in_at is null then 'invited' else 'active' end status,u.created_at invited_at,u.last_sign_in_at,m.updated_at,coalesce(ld.locations,'[]'::jsonb) locations
    from members m join auth.users u on u.id=m.user_id left join public.profiles p on p.id=m.user_id
    left join lateral(select jsonb_agg(jsonb_build_object('code',r.code,'name',r.display_name,'description',r.description,'category',r.category,'scope_kind',r.scope_kind,'is_assignable',r.is_assignable) order by r.display_name) filter(where ur2.is_active) roles,
      array_agg(r.code order by r.code) filter(where ur2.is_active) role_codes,(array_agg(r.code order by ur2.is_active desc,ur2.updated_at desc))[1] primary_code,(array_agg(r.display_name order by ur2.is_active desc,ur2.updated_at desc))[1] primary_name,bool_and(r.is_assignable) filter(where ur2.is_active) all_assignable
      from public.user_roles ur2 join public.roles r on r.id=ur2.role_id where ur2.company_id=p_company_id and ur2.user_id=m.user_id)rd on true
    left join lateral(select jsonb_agg(jsonb_build_object('id',l.id,'code',l.external_code,'name',l.name) order by l.name,l.id) locations from public.user_location_access ula join public.locations l on l.id=ula.location_id where ula.user_id=m.user_id and l.company_id=p_company_id)ld on true
  ), invitation_details as(
    select 'invitation'::text record_type,null::uuid user_id,i.id invitation_id,i.email,'Pendiente de registro'::text full_name,
      coalesce(rd.roles,'[]'::jsonb) roles,coalesce(rd.role_codes,'{}'::text[]) role_codes,rd.primary_code role_code,rd.primary_name role_name,coalesce(rd.all_assignable,false) role_assignable,
      case when i.status='pending' then 'invited' else 'suspended' end status,i.created_at invited_at,null::timestamptz last_sign_in_at,i.updated_at,coalesce(ld.locations,'[]'::jsonb) locations
    from public.company_user_invitations i
    left join lateral(select jsonb_agg(jsonb_build_object('code',r.code,'name',r.display_name,'description',r.description,'category',r.category,'scope_kind',r.scope_kind,'is_assignable',r.is_assignable) order by r.display_name) roles,array_agg(r.code order by r.code) role_codes,min(r.code) primary_code,min(r.display_name) primary_name,bool_and(r.is_assignable) all_assignable from public.company_user_invitation_roles ir join public.roles r on r.id=ir.role_id where ir.invitation_id=i.id)rd on true
    left join lateral(select jsonb_agg(jsonb_build_object('id',l.id,'code',l.external_code,'name',l.name) order by l.name,l.id) locations from public.company_user_invitation_locations il join public.locations l on l.id=il.location_id where il.invitation_id=i.id)ld on true
    where i.company_id=p_company_id and i.status in('pending','cancelled')
  ), filtered as(select * from(select * from user_details union all select * from invitation_details)s where
    (nullif(trim(p_query),'') is null or email ilike '%'||trim(p_query)||'%' or full_name ilike '%'||trim(p_query)||'%') and
    (p_role_code is null or p_role_code=any(role_codes)) and(p_status is null or status=p_status))
  select count(*),coalesce((select jsonb_agg(to_jsonb(x) order by x.full_name,x.email) from(select * from filtered order by full_name,email limit v_size offset(v_page-1)*v_size)x),'[]'::jsonb)
  into v_total,v_items from filtered;
  return jsonb_build_object('items',v_items,'total',v_total,'page',v_page,'page_size',v_size);
end $$;

revoke all on table public.company_user_invitation_roles from anon,authenticated;
revoke all on function public.list_access_profiles(uuid) from public;
revoke all on function public.save_access_profile(uuid,uuid,text,text,text[],text,text,timestamptz,uuid) from public;
revoke all on function public.save_company_user_access_profiles(uuid,uuid,text[],uuid[],text,text,timestamptz,uuid) from public;
revoke all on function public.save_company_user_invitation_profiles(uuid,uuid,text,text[],uuid[],text,text,timestamptz,uuid) from public;
grant execute on function public.list_access_profiles(uuid) to authenticated;
grant execute on function public.save_access_profile(uuid,uuid,text,text,text[],text,text,timestamptz,uuid) to authenticated;
grant execute on function public.save_company_user_access_profiles(uuid,uuid,text[],uuid[],text,text,timestamptz,uuid) to authenticated;
grant execute on function public.save_company_user_invitation_profiles(uuid,uuid,text,text[],uuid[],text,text,timestamptz,uuid) to authenticated;
