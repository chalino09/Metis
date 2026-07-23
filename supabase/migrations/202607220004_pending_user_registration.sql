-- Satrapy · Acceso previamente autorizado sin correo de invitación.
-- El administrador define empresa, rol y alcance; la persona crea sus credenciales después.

create table if not exists public.company_user_invitations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  email text not null,
  role_id uuid not null references public.roles(id),
  status text not null default 'pending' check (status in ('pending','claimed','cancelled')),
  reason text not null,
  created_by uuid not null references auth.users(id),
  claimed_by uuid references auth.users(id),
  claimed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint company_user_invitations_email_check check (email=lower(trim(email)) and email like '%@%')
);

create unique index if not exists company_user_invitations_pending_email_unique
  on public.company_user_invitations(company_id,lower(email)) where status='pending';
create index if not exists company_user_invitations_email_status_idx
  on public.company_user_invitations(lower(email),status);

create table if not exists public.company_user_invitation_locations (
  invitation_id uuid not null references public.company_user_invitations(id) on delete cascade,
  location_id uuid not null references public.locations(id),
  primary key(invitation_id,location_id)
);

alter table public.company_user_invitations enable row level security;
alter table public.company_user_invitation_locations enable row level security;

drop trigger if exists company_user_invitations_set_updated_at on public.company_user_invitations;
create trigger company_user_invitations_set_updated_at before update on public.company_user_invitations
for each row execute procedure public.set_updated_at();

create or replace function public.save_company_user_invitation(
  p_company_id uuid,p_invitation_id uuid,p_email text,p_role_code text,p_location_ids uuid[],
  p_status text,p_reason text,p_expected_updated_at timestamptz,p_client_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=public,auth as $$
declare
  v_role public.roles%rowtype;v_invitation public.company_user_invitations%rowtype;v_email text:=lower(trim(p_email));
  v_result jsonb;v_target_status text:=case when coalesce(p_status,'active')='suspended' then 'cancelled' else 'pending' end;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_company_users') then raise exception 'No autorizado para administrar usuarios.';end if;
  if v_email is null or v_email='' or v_email not like '%@%' then raise exception 'Captura un correo válido.';end if;
  if nullif(trim(p_reason),'') is null then raise exception 'El motivo es obligatorio.';end if;
  if p_client_request_id is null then raise exception 'Falta la referencia idempotente.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||':'||v_email,0));
  select metadata->'result' into v_result from public.audit_log
  where company_id=p_company_id and action='company.user_invitation_saved' and metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_result is not null then return v_result||jsonb_build_object('idempotent',true);end if;
  if exists(select 1 from auth.users where lower(email)=v_email) and p_invitation_id is null then
    raise exception 'El correo ya tiene cuenta. Agrégalo como usuario existente.';
  end if;
  select * into v_role from public.roles where code=p_role_code and is_assignable;
  if not found then raise exception 'Selecciona un rol disponible.';end if;
  if v_role.code in('sucursal','ingeniero_campo') and coalesce(cardinality(p_location_ids),0)=0 then raise exception 'Selecciona al menos una sucursal para este rol.';end if;
  if exists(select 1 from unnest(coalesce(p_location_ids,'{}'::uuid[])) selected(id)
    left join public.locations l on l.id=selected.id and l.company_id=p_company_id and l.is_active where l.id is null)
  then raise exception 'Hay sucursales no disponibles en la selección.';end if;

  if p_invitation_id is null then
    select * into v_invitation from public.company_user_invitations
    where company_id=p_company_id and lower(email)=v_email and status='pending' for update;
    if found then raise exception 'Este correo ya tiene un acceso pendiente.';end if;
    insert into public.company_user_invitations(company_id,email,role_id,status,reason,created_by)
    values(p_company_id,v_email,v_role.id,v_target_status,trim(p_reason),auth.uid()) returning * into v_invitation;
  else
    select * into v_invitation from public.company_user_invitations
    where id=p_invitation_id and company_id=p_company_id and status in('pending','cancelled') for update;
    if not found then raise exception 'El acceso pendiente ya no está disponible.';end if;
    if p_expected_updated_at is null or v_invitation.updated_at<>p_expected_updated_at then raise exception 'El acceso cambió mientras lo editabas. Actualiza y vuelve a intentarlo.';end if;
    update public.company_user_invitations set email=v_email,role_id=v_role.id,status=v_target_status,reason=trim(p_reason)
    where id=v_invitation.id returning * into v_invitation;
  end if;

  delete from public.company_user_invitation_locations where invitation_id=v_invitation.id;
  if v_role.code in('sucursal','ingeniero_campo') then
    insert into public.company_user_invitation_locations(invitation_id,location_id)
    select v_invitation.id,id from unnest(p_location_ids) selected(id) on conflict do nothing;
  end if;
  select jsonb_build_object('invitation_id',v_invitation.id,'email',v_email,'role_code',v_role.code,'role_name',v_role.display_name,
    'status',case when v_invitation.status='pending' then 'invited' else 'suspended' end,
    'location_ids',case when v_role.code in('sucursal','ingeniero_campo') then to_jsonb(p_location_ids) else '[]'::jsonb end,
    'updated_at',v_invitation.updated_at,'idempotent',false) into v_result;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'company.user_invitation_saved','company_user_invitation',v_invitation.id,
    jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'result',v_result));
  return v_result;
end $$;

create or replace function public.prepare_pending_user_registration(p_email text)
returns jsonb language plpgsql stable security definer set search_path=public,auth as $$
declare v_email text:=lower(trim(p_email));v_user auth.users%rowtype;v_count integer;
begin
  if auth.role()<>'service_role' then raise exception 'Operación reservada al servidor.';end if;
  select count(*) into v_count from public.company_user_invitations where lower(email)=v_email and status='pending';
  if v_count=0 then return jsonb_build_object('allowed',false);end if;
  select * into v_user from auth.users where lower(email)=v_email limit 1;
  if found and coalesce((v_user.raw_user_meta_data->>'registration_pending')::boolean,false)=false then
    return jsonb_build_object('allowed',false,'already_registered',true);
  end if;
  return jsonb_build_object('allowed',true,'user_id',v_user.id,'company_count',v_count);
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
  update public.user_roles ur set is_active=false
  where ur.user_id=p_user_id and ur.company_id in(select company_id from public.company_user_invitations where lower(email)=v_email and status='pending');
  insert into public.user_roles(user_id,role_id,company_id,is_active,updated_at)
  select p_user_id,i.role_id,i.company_id,true,clock_timestamp() from public.company_user_invitations i where lower(i.email)=v_email and i.status='pending'
  on conflict(user_id,role_id,company_id) do update set is_active=true,updated_at=clock_timestamp();
  delete from public.user_location_access ula using public.locations l
  where ula.user_id=p_user_id and ula.location_id=l.id and l.company_id in(select company_id from public.company_user_invitations where lower(email)=v_email and status='pending');
  insert into public.user_location_access(user_id,location_id)
  select p_user_id,il.location_id from public.company_user_invitations i join public.company_user_invitation_locations il on il.invitation_id=i.id
  where lower(i.email)=v_email and i.status='pending' on conflict do nothing;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  select i.company_id,p_user_id,'company.user_registration_completed','user',p_user_id,
    jsonb_build_object('invitation_id',i.id,'email',v_email,'role_id',i.role_id)
  from public.company_user_invitations i where lower(i.email)=v_email and i.status='pending';
  update public.company_user_invitations set status='claimed',claimed_by=p_user_id,claimed_at=clock_timestamp()
  where lower(email)=v_email and status='pending';
  return jsonb_build_object('activated',true,'company_count',v_count);
end $$;

create or replace function public.list_company_users(
  p_company_id uuid,p_query text default null,p_role_code text default null,
  p_status text default null,p_page integer default 1,p_page_size integer default 25
) returns jsonb
language plpgsql stable security definer set search_path=public,auth as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_company_users') then raise exception 'No autorizado para administrar usuarios.';end if;
  if p_status is not null and p_status not in('active','invited','suspended') then raise exception 'Estado de usuario inválido.';end if;
  with members as(
    select ur.user_id,bool_or(ur.is_active) active,max(ur.updated_at) updated_at from public.user_roles ur where ur.company_id=p_company_id group by ur.user_id
  ),user_details as(
    select 'user'::text record_type,m.user_id,null::uuid invitation_id,u.email,
      coalesce(nullif(trim(p.full_name),''),split_part(u.email,'@',1)) full_name,
      role_data.code role_code,role_data.display_name role_name,role_data.is_assignable role_assignable,
      case when not m.active then 'suspended' when u.last_sign_in_at is null then 'invited' else 'active' end status,
      u.created_at invited_at,u.last_sign_in_at,m.updated_at,coalesce(location_data.locations,'[]'::jsonb) locations
    from members m join auth.users u on u.id=m.user_id left join public.profiles p on p.id=m.user_id
    left join lateral(select r.code,r.display_name,r.is_assignable from public.user_roles ur2 join public.roles r on r.id=ur2.role_id where ur2.company_id=p_company_id and ur2.user_id=m.user_id order by ur2.is_active desc,ur2.updated_at desc,ur2.created_at desc limit 1)role_data on true
    left join lateral(select coalesce(jsonb_agg(jsonb_build_object('id',l.id,'code',l.external_code,'name',l.name) order by l.name,l.id),'[]'::jsonb) locations from public.user_location_access ula join public.locations l on l.id=ula.location_id where ula.user_id=m.user_id and l.company_id=p_company_id)location_data on true
  ),invitation_details as(
    select 'invitation'::text record_type,null::uuid user_id,i.id invitation_id,i.email,'Pendiente de registro'::text full_name,
      r.code role_code,r.display_name role_name,r.is_assignable role_assignable,
      case when i.status='pending' then 'invited' else 'suspended' end status,i.created_at invited_at,null::timestamptz last_sign_in_at,i.updated_at,
      coalesce(location_data.locations,'[]'::jsonb) locations
    from public.company_user_invitations i join public.roles r on r.id=i.role_id
    left join lateral(select coalesce(jsonb_agg(jsonb_build_object('id',l.id,'code',l.external_code,'name',l.name) order by l.name,l.id),'[]'::jsonb) locations from public.company_user_invitation_locations il join public.locations l on l.id=il.location_id where il.invitation_id=i.id)location_data on true
    where i.company_id=p_company_id and i.status in('pending','cancelled')
  ),filtered as(
    select * from(select * from user_details union all select * from invitation_details)s where
      (nullif(trim(p_query),'') is null or email ilike '%'||trim(p_query)||'%' or full_name ilike '%'||trim(p_query)||'%')
      and (p_role_code is null or role_code=p_role_code) and (p_status is null or status=p_status)
  )
  select count(*),coalesce((select jsonb_agg(to_jsonb(x) order by x.full_name,x.email) from(select * from filtered order by full_name,email limit v_size offset (v_page-1)*v_size)x),'[]'::jsonb)
  into v_total,v_items from filtered;
  return jsonb_build_object('items',v_items,'total',v_total,'page',v_page,'page_size',v_size);
end $$;

revoke all on table public.company_user_invitations from anon,authenticated;
revoke all on table public.company_user_invitation_locations from anon,authenticated;
revoke all on function public.save_company_user_invitation(uuid,uuid,text,text,uuid[],text,text,timestamptz,uuid) from public;
revoke all on function public.prepare_pending_user_registration(text) from public;
revoke all on function public.complete_pending_user_registration(uuid,text,text) from public;
grant execute on function public.save_company_user_invitation(uuid,uuid,text,text,uuid[],text,text,timestamptz,uuid) to authenticated;
grant execute on function public.prepare_pending_user_registration(text) to service_role;
grant execute on function public.complete_pending_user_registration(uuid,text,text) to service_role;
