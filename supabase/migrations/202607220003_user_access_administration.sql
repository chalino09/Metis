-- Administración empresarial de usuarios y accesos.
-- Reutiliza auth.users, profiles, roles, user_roles y user_location_access.

alter table public.roles add column if not exists is_assignable boolean not null default true;
alter table public.user_roles add column if not exists is_active boolean not null default true;
alter table public.user_roles add column if not exists updated_at timestamptz not null default now();

update public.roles
set display_name='Operador de sucursal',
    description='Opera ventas, caja, clientes e inventario en sus ubicaciones asignadas.',
    is_assignable=true
where code='sucursal';

update public.roles set is_assignable=false where code in ('super_admin','supervisor_sucursal','punto_venta');
update public.roles set is_assignable=true where code in ('direccion_admin','sucursal','almacen','ingeniero_campo');

insert into public.permissions(code,description)
values('manage_company_users','Invitar, asignar, suspender y limitar usuarios de la empresa.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r join public.permissions p on p.code='manage_company_users'
where r.code in('super_admin','direccion_admin')
on conflict do nothing;

-- Las aprobaciones sensibles quedan centralizadas en Dirección.
delete from public.role_permissions rp
using public.roles r,public.permissions p
where rp.role_id=r.id and rp.permission_id=p.id
  and r.code='supervisor_sucursal'
  and p.code in ('approve_inventory_adjustments','approve_cash_variance');

-- Punto de Venta se consolida en Operador de sucursal sin perder evidencia.
insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
select ur.company_id,null,'access.role_consolidated','user_role',ur.id,
  jsonb_build_object('user_id',ur.user_id,'previous_role','punto_venta','current_role','sucursal','migrated_at',now())
from public.user_roles ur join public.roles r on r.id=ur.role_id
where r.code='punto_venta' and ur.company_id is not null;

insert into public.user_roles(user_id,role_id,company_id,created_at,is_active,updated_at)
select ur.user_id,target.id,ur.company_id,ur.created_at,ur.is_active,clock_timestamp()
from public.user_roles ur
join public.roles legacy on legacy.id=ur.role_id and legacy.code='punto_venta'
join public.roles target on target.code='sucursal'
where ur.company_id is not null
on conflict(user_id,role_id,company_id) do update
set is_active=public.user_roles.is_active or excluded.is_active,
    updated_at=greatest(public.user_roles.updated_at,excluded.updated_at);

delete from public.user_roles ur using public.roles r
where ur.role_id=r.id and r.code='punto_venta' and ur.company_id is not null;

create or replace function public.set_user_role_updated_at()
returns trigger language plpgsql set search_path=public as $$
begin
  new.updated_at:=greatest(clock_timestamp(),old.updated_at+interval '1 microsecond');
  return new;
end $$;

drop trigger if exists user_roles_set_updated_at on public.user_roles;
create trigger user_roles_set_updated_at before update on public.user_roles
for each row execute function public.set_user_role_updated_at();

create unique index if not exists audit_company_user_request_uidx
  on public.audit_log(company_id,(metadata->>'request_id'))
  where action='company.user_access_saved' and metadata ? 'request_id';

create index if not exists user_roles_company_active_user_idx
  on public.user_roles(company_id,is_active,user_id,updated_at desc);

create or replace function public.is_super_admin()
returns boolean language sql stable security definer set search_path=public as $$
  select exists(
    select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id
    where ur.user_id=auth.uid() and ur.is_active and r.code='super_admin'
  );
$$;

create or replace function public.has_company_access(target_company_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_super_admin() or exists(
    select 1 from public.user_roles ur
    where ur.user_id=auth.uid() and ur.company_id=target_company_id and ur.is_active
  );
$$;

create or replace function public.has_company_permission(target_company_id uuid,requested_permission text)
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_super_admin() or exists(
    select 1 from public.user_roles ur
    join public.role_permissions rp on rp.role_id=ur.role_id
    join public.permissions p on p.id=rp.permission_id
    where ur.user_id=auth.uid() and ur.company_id=target_company_id and ur.is_active
      and p.code=requested_permission
  );
$$;

create or replace function public.can_access_location(target_location_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_super_admin()
    or exists(
      select 1 from public.locations l
      join public.user_roles ur on ur.company_id=l.company_id and ur.user_id=auth.uid() and ur.is_active
      join public.roles r on r.id=ur.role_id
      where l.id=target_location_id and r.code in ('direccion_admin','almacen')
    )
    or exists(
      select 1 from public.user_location_access ula
      join public.locations l on l.id=ula.location_id
      join public.user_roles ur on ur.company_id=l.company_id and ur.user_id=ula.user_id and ur.is_active
      where ula.user_id=auth.uid() and ula.location_id=target_location_id
    );
$$;

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
    select ur.user_id,bool_or(ur.is_active) active,max(ur.updated_at) updated_at
    from public.user_roles ur where ur.company_id=p_company_id group by ur.user_id
  ),details as(
    select m.user_id,u.email,coalesce(nullif(trim(p.full_name),''),split_part(u.email,'@',1)) full_name,
      role_data.code role_code,role_data.display_name role_name,role_data.is_assignable role_assignable,
      case when not m.active then 'suspended' when u.last_sign_in_at is null then 'invited' else 'active' end status,
      u.created_at invited_at,u.last_sign_in_at,m.updated_at,
      coalesce(location_data.locations,'[]'::jsonb) locations
    from members m join auth.users u on u.id=m.user_id left join public.profiles p on p.id=m.user_id
    left join lateral(
      select r.code,r.display_name,r.is_assignable from public.user_roles ur2 join public.roles r on r.id=ur2.role_id
      where ur2.company_id=p_company_id and ur2.user_id=m.user_id
      order by ur2.is_active desc,ur2.updated_at desc,ur2.created_at desc limit 1
    )role_data on true
    left join lateral(
      select coalesce(jsonb_agg(jsonb_build_object('id',l.id,'code',l.external_code,'name',l.name) order by l.name,l.id),'[]'::jsonb) locations
      from public.user_location_access ula join public.locations l on l.id=ula.location_id
      where ula.user_id=m.user_id and l.company_id=p_company_id
    )location_data on true
  ),filtered as(
    select * from details where
      (nullif(trim(p_query),'') is null or email ilike '%'||trim(p_query)||'%' or full_name ilike '%'||trim(p_query)||'%')
      and (p_role_code is null or role_code=p_role_code)
      and (p_status is null or status=p_status)
  ) select count(*) into v_total from filtered;
  with members as(
    select ur.user_id,bool_or(ur.is_active) active,max(ur.updated_at) updated_at
    from public.user_roles ur where ur.company_id=p_company_id group by ur.user_id
  ),details as(
    select m.user_id,u.email,coalesce(nullif(trim(p.full_name),''),split_part(u.email,'@',1)) full_name,
      role_data.code role_code,role_data.display_name role_name,role_data.is_assignable role_assignable,
      case when not m.active then 'suspended' when u.last_sign_in_at is null then 'invited' else 'active' end status,
      u.created_at invited_at,u.last_sign_in_at,m.updated_at,
      coalesce(location_data.locations,'[]'::jsonb) locations
    from members m join auth.users u on u.id=m.user_id left join public.profiles p on p.id=m.user_id
    left join lateral(
      select r.code,r.display_name,r.is_assignable from public.user_roles ur2 join public.roles r on r.id=ur2.role_id
      where ur2.company_id=p_company_id and ur2.user_id=m.user_id
      order by ur2.is_active desc,ur2.updated_at desc,ur2.created_at desc limit 1
    )role_data on true
    left join lateral(
      select coalesce(jsonb_agg(jsonb_build_object('id',l.id,'code',l.external_code,'name',l.name) order by l.name,l.id),'[]'::jsonb) locations
      from public.user_location_access ula join public.locations l on l.id=ula.location_id
      where ula.user_id=m.user_id and l.company_id=p_company_id
    )location_data on true
  ),filtered as(
    select * from details where
      (nullif(trim(p_query),'') is null or email ilike '%'||trim(p_query)||'%' or full_name ilike '%'||trim(p_query)||'%')
      and (p_role_code is null or role_code=p_role_code)
      and (p_status is null or status=p_status)
  )
  select coalesce(jsonb_agg(to_jsonb(x) order by x.full_name,x.email),'[]'::jsonb) into v_items
  from(select * from filtered order by full_name,email limit v_size offset (v_page-1)*v_size)x;
  return jsonb_build_object('items',v_items,'total',v_total,'page',v_page,'page_size',v_size);
end $$;

create or replace function public.get_company_user_access_options(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_roles jsonb;v_locations jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_company_users') then raise exception 'No autorizado para administrar usuarios.';end if;
  select coalesce(jsonb_agg(jsonb_build_object('code',code,'name',display_name,'description',description) order by
    case code when 'direccion_admin' then 1 when 'sucursal' then 2 when 'almacen' then 3 when 'ingeniero_campo' then 4 else 9 end),'[]'::jsonb)
  into v_roles from public.roles where is_assignable;
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'code',external_code,'name',name,'type',location_type) order by name,id),'[]'::jsonb)
  into v_locations from public.locations where company_id=p_company_id and is_active;
  return jsonb_build_object('roles',v_roles,'locations',v_locations);
end $$;

create or replace function public.resolve_company_user_email(p_company_id uuid,p_email text)
returns uuid language plpgsql stable security definer set search_path=public,auth as $$
declare v_user uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_company_users') then raise exception 'No autorizado para administrar usuarios.';end if;
  if nullif(trim(p_email),'') is null then raise exception 'El correo es obligatorio.';end if;
  select id into v_user from auth.users where lower(email)=lower(trim(p_email)) limit 1;
  return v_user;
end $$;

create or replace function public.save_company_user_access(
  p_company_id uuid,p_user_id uuid,p_role_code text,p_location_ids uuid[],p_status text,
  p_reason text,p_expected_updated_at timestamptz,p_client_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=public,auth as $$
declare v_role public.roles%rowtype;v_current_updated timestamptz;v_existing boolean;v_was_admin boolean;v_result jsonb;v_email text;v_status text:=coalesce(p_status,'active');
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_company_users') then raise exception 'No autorizado para administrar usuarios.';end if;
  if p_user_id is null or p_user_id=auth.uid() then raise exception 'No puedes modificar tu propio acceso.';end if;
  if v_status not in('active','suspended') then raise exception 'Estado de usuario inválido.';end if;
  if nullif(trim(p_reason),'') is null then raise exception 'El motivo es obligatorio.';end if;
  if p_client_request_id is null then raise exception 'Falta la referencia idempotente.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||':'||p_user_id::text,0));
  select metadata->'result' into v_result from public.audit_log where company_id=p_company_id and action='company.user_access_saved' and metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_result is not null then return v_result||jsonb_build_object('idempotent',true);end if;
  select email into v_email from auth.users where id=p_user_id;if not found then raise exception 'El usuario ya no está disponible.';end if;
  select * into v_role from public.roles where code=p_role_code and is_assignable;
  if not found then raise exception 'Selecciona un rol disponible.';end if;
  select max(ur.updated_at),count(*)>0,bool_or(ur.is_active and r.code='direccion_admin')
  into v_current_updated,v_existing,v_was_admin
  from public.user_roles ur join public.roles r on r.id=ur.role_id
  where ur.company_id=p_company_id and ur.user_id=p_user_id;
  if v_existing and (p_expected_updated_at is null or v_current_updated<>p_expected_updated_at) then raise exception 'El acceso cambió mientras lo editabas. Actualiza y vuelve a intentarlo.';end if;
  if not v_existing and p_expected_updated_at is not null then raise exception 'El acceso cambió mientras lo editabas. Actualiza y vuelve a intentarlo.';end if;
  if v_was_admin and (v_status='suspended' or v_role.code<>'direccion_admin') and
    (select count(distinct ur.user_id) from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.company_id=p_company_id and ur.is_active and r.code='direccion_admin')<=1
  then raise exception 'La empresa debe conservar al menos un Administrador general activo.';end if;
  if v_status='active' and v_role.code in('sucursal','ingeniero_campo') and coalesce(cardinality(p_location_ids),0)=0 then raise exception 'Selecciona al menos una sucursal para este rol.';end if;
  if exists(select 1 from unnest(coalesce(p_location_ids,'{}'::uuid[])) selected(id) left join public.locations l on l.id=selected.id and l.company_id=p_company_id and l.is_active where l.id is null) then raise exception 'Hay sucursales no disponibles en la selección.';end if;
  update public.user_roles set is_active=false where company_id=p_company_id and user_id=p_user_id and is_active;
  if v_status='active' then
    insert into public.user_roles(user_id,role_id,company_id,is_active,updated_at)
    values(p_user_id,v_role.id,p_company_id,true,clock_timestamp())
    on conflict(user_id,role_id,company_id) do update set is_active=true,updated_at=clock_timestamp();
    delete from public.user_location_access ula using public.locations l where ula.location_id=l.id and l.company_id=p_company_id and ula.user_id=p_user_id;
    if v_role.code in('sucursal','ingeniero_campo') then
      insert into public.user_location_access(user_id,location_id)
      select p_user_id,id from unnest(p_location_ids) selected(id) on conflict do nothing;
    end if;
  end if;
  select jsonb_build_object('user_id',p_user_id,'email',v_email,'role_code',v_role.code,'role_name',v_role.display_name,'status',v_status,
    'location_ids',case when v_status='active' and v_role.code in('sucursal','ingeniero_campo') then to_jsonb(p_location_ids) else '[]'::jsonb end,
    'updated_at',max(ur.updated_at),'idempotent',false)
  into v_result from public.user_roles ur where ur.company_id=p_company_id and ur.user_id=p_user_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'company.user_access_saved','user',p_user_id,jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'result',v_result));
  return v_result;
end $$;

revoke all on function public.list_company_users(uuid,text,text,text,integer,integer) from public;
revoke all on function public.get_company_user_access_options(uuid) from public;
revoke all on function public.resolve_company_user_email(uuid,text) from public;
revoke all on function public.save_company_user_access(uuid,uuid,text,uuid[],text,text,timestamptz,uuid) from public;
grant execute on function public.list_company_users(uuid,text,text,text,integer,integer) to authenticated;
grant execute on function public.get_company_user_access_options(uuid) to authenticated;
grant execute on function public.resolve_company_user_email(uuid,text) to authenticated;
grant execute on function public.save_company_user_access(uuid,uuid,text,uuid[],text,text,timestamptz,uuid) to authenticated;
