begin;

do $$
declare v_count integer;v_warning_count integer;
begin
  select count(*) into v_count from public.roles where code in(
    'payroll_capture_review','payroll_preparation','payroll_approval','payroll_payment',
    'procurement_operations','procurement_approval'
  ) and is_assignable and is_system;
  if v_count<>6 then raise exception 'Expected 6 curated access profiles, found %.',v_count;end if;

  if not exists(
    select 1 from public.roles r join public.role_permissions rp on rp.role_id=r.id
    join public.permissions p on p.id=rp.permission_id
    where r.code='payroll_payment' and p.code='mark_payroll_paid'
  ) then raise exception 'Payroll payment profile is missing mark_payroll_paid.';end if;

  if exists(
    select 1 from public.roles r join public.role_permissions rp on rp.role_id=r.id
    join public.permissions p on p.id=rp.permission_id
    where r.code='payroll_payment' and p.code='approve_payroll_runs'
  ) then raise exception 'Payroll payment profile must not approve payroll runs.';end if;

  select jsonb_array_length(public.access_profile_warnings(array['payroll_capture_review','payroll_approval'])) into v_warning_count;
  if v_warning_count<>1 then raise exception 'Expected one payroll segregation warning.';end if;

  if exists(
    select 1 from public.company_user_invitations i
    where not exists(select 1 from public.company_user_invitation_roles ir where ir.invitation_id=i.id)
  ) then raise exception 'Every existing invitation must retain its original role.';end if;
end $$;

do $$
declare
  c uuid:='40840000-0000-4000-8000-000000000001';admin_user uuid:='40840000-0000-4000-8000-000000000002';target_user uuid:='40840000-0000-4000-8000-000000000003';
  l1 uuid:='40840000-0000-4000-8000-000000000011';result jsonb;stamp timestamptz;profile_id uuid;
begin
  insert into public.companies(id,legal_name,display_name) values(c,'Perfiles combinables','Perfiles combinables');
  insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,last_sign_in_at) values
    (admin_user,'authenticated','authenticated','profiles-admin@example.invalid','',now(),now()),
    (target_user,'authenticated','authenticated','profiles-target@example.invalid','',now(),now());
  insert into public.locations(id,company_id,external_code,name,location_type,classification_source)
  values(l1,c,'PFL-01','Sucursal perfiles','sucursal','manual_review');
  insert into public.user_roles(user_id,role_id,company_id) select admin_user,id,c from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',admin_user::text,true);

  result:=public.save_company_user_access_profiles(c,target_user,array['payroll_capture_review','payroll_preparation'],'{}'::uuid[],'active','Responsabilidades de prueba',null,'40840000-0000-4000-8000-000000000021');
  if jsonb_array_length(result->'role_codes')<>2 then raise exception 'Expected two assigned profiles: %',result;end if;
  if (select count(*) from public.user_roles where company_id=c and user_id=target_user and is_active)<>2 then raise exception 'Multiple profiles were not persisted.';end if;
  stamp:=(result->>'updated_at')::timestamptz;
  result:=public.list_company_users(c,'profiles-target','payroll_preparation','active',1,25);
  if (result->>'total')::integer<>1 or jsonb_array_length(result#>'{items,0,roles}')<>2 then raise exception 'User list did not expose effective profiles: %',result;end if;

  result:=public.save_access_profile(c,null,'Perfil local QA','Acceso de prueba limitado por sucursal',array['view_collaborators'],'locations','Validación del editor',null,'40840000-0000-4000-8000-000000000022');
  profile_id:=(result->>'profile_id')::uuid;
  if not exists(select 1 from public.roles where id=profile_id and company_id=c and not is_system and scope_kind='locations') then raise exception 'Custom profile was not company-scoped.';end if;
  if (select count(*) from public.role_permissions where role_id=profile_id)<>1 then raise exception 'Custom profile permissions were not saved.';end if;

  perform set_config('request.jwt.claim.sub',target_user::text,true);
  if not public.has_company_permission(c,'view_collaborators') or public.has_company_permission(c,'approve_payroll_runs') then raise exception 'Effective permissions are not the expected union.';end if;
  perform set_config('request.jwt.claim.sub',admin_user::text,true);
  result:=public.save_company_user_access_profiles(c,target_user,array['payroll_approval','payroll_payment'],'{}'::uuid[],'active','Cambio probado',stamp,'40840000-0000-4000-8000-000000000023');
  if jsonb_array_length(result->'role_codes')<>2 then raise exception 'Profile replacement failed.';end if;
end $$;

rollback;
