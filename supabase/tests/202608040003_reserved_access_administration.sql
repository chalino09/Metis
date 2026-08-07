begin;

do $$
declare
  c uuid:='40840300-0000-4000-8000-000000000001';admin_user uuid:='40840300-0000-4000-8000-000000000002';operator_user uuid:='40840300-0000-4000-8000-000000000003';
  custom_role uuid;manage_permission uuid;blocked boolean:=false;
begin
  insert into public.companies(id,legal_name,display_name) values(c,'Acceso reservado','Acceso reservado');
  insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at) values
    (admin_user,'authenticated','authenticated','reserved-admin@example.invalid','',now()),
    (operator_user,'authenticated','authenticated','reserved-operator@example.invalid','',now());
  insert into public.user_roles(user_id,role_id,company_id)
  select admin_user,id,c from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',admin_user::text,true);
  if not public.has_company_permission(c,'manage_company_users') then raise exception 'Administrador perdió la administración de accesos.';end if;

  insert into public.roles(code,display_name,description,is_assignable,company_id,category,scope_kind,is_system)
  values('custom_reserved_test','Perfil sin administración','Perfil de prueba.',true,c,'custom','company',false)
  returning id into custom_role;
  select id into manage_permission from public.permissions where code='manage_company_users';
  begin
    insert into public.role_permissions(role_id,permission_id) values(custom_role,manage_permission);
  exception when others then blocked:=position('capacidad reservada' in lower(sqlerrm))>0;end;
  if not blocked then raise exception 'Un perfil personalizado recibió administración de usuarios.';end if;

  insert into public.user_roles(user_id,role_id,company_id) values(operator_user,custom_role,c);
  perform set_config('request.jwt.claim.sub',operator_user::text,true);
  if public.has_company_permission(c,'manage_company_users') then raise exception 'Un perfil personalizado administra usuarios.';end if;
end $$;

rollback;
