-- Satrapy · Administración de accesos reservada.
-- Solo Superadmin y Administrador pueden administrar usuarios y perfiles.

update public.roles
set description='Administra toda la información de la empresa.',updated_at=clock_timestamp()
where code='direccion_admin' and company_id is null;

insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
select r.company_id,null,'access.reserved_permission_removed','role',r.id,
  jsonb_build_object('profile_code',r.code,'permission_code','manage_company_users','reason','Permiso reservado para Administrador y Superadmin')
from public.role_permissions rp join public.roles r on r.id=rp.role_id
join public.permissions p on p.id=rp.permission_id
where p.code='manage_company_users' and r.code not in('super_admin','direccion_admin');

delete from public.role_permissions rp
using public.roles r,public.permissions p
where rp.role_id=r.id and rp.permission_id=p.id and p.code='manage_company_users'
  and r.code not in('super_admin','direccion_admin');

create or replace function public.enforce_reserved_access_permission()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_role_code text;v_permission_code text;
begin
  select code into v_role_code from public.roles where id=new.role_id;
  select code into v_permission_code from public.permissions where id=new.permission_id;
  if v_permission_code='manage_company_users' and v_role_code not in('super_admin','direccion_admin') then
    raise exception 'Administrar usuarios y perfiles es una capacidad reservada para Administrador y Superadmin.';
  end if;
  return new;
end $$;

drop trigger if exists role_permissions_reserved_access_guard on public.role_permissions;
create trigger role_permissions_reserved_access_guard
before insert or update on public.role_permissions
for each row execute function public.enforce_reserved_access_permission();

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

revoke all on function public.enforce_reserved_access_permission() from public;
