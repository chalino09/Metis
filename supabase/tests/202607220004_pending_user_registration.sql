begin;
do $pending_registration$
declare
  c uuid:='cf040000-0000-4000-8000-000000000001';admin_user uuid:='cf040000-0000-4000-8000-000000000002';new_user uuid:='cf040000-0000-4000-8000-000000000003';
  l1 uuid:='cf040000-0000-4000-8000-000000000011';l2 uuid:='cf040000-0000-4000-8000-000000000012';r jsonb;r2 jsonb;invite_id uuid;
begin
  insert into public.companies(id,legal_name,display_name) values(c,'Registro pendiente','Registro pendiente');
  insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,last_sign_in_at) values
    (admin_user,'authenticated','authenticated','pending-admin@example.invalid','',now(),now());
  insert into public.locations(id,company_id,external_code,name,location_type,classification_source) values
    (l1,c,'PEND-01','Sucursal Autorizada','sucursal','manual_review'),(l2,c,'PEND-02','Sucursal Restringida','sucursal','manual_review');
  insert into public.user_roles(user_id,role_id,company_id) select admin_user,id,c from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',admin_user::text,true);
  r:=public.save_company_user_invitation(c,null,'nuevo@example.invalid','sucursal',array[l1],'active','Alta autorizada',null,'cf040000-0000-4000-8000-000000000021');
  invite_id:=(r->>'invitation_id')::uuid;
  if r->>'status'<>'invited' or exists(select 1 from auth.users where lower(email)='nuevo@example.invalid') then raise exception 'El panel creó credenciales o no dejó el acceso pendiente: %',r;end if;
  r2:=public.save_company_user_invitation(c,null,'nuevo@example.invalid','sucursal',array[l1],'active','Alta autorizada',null,'cf040000-0000-4000-8000-000000000021');
  if not coalesce((r2->>'idempotent')::boolean,false) then raise exception 'La autorización no es idempotente.';end if;
  r:=public.list_company_users(c,'nuevo@example.invalid','sucursal','invited',1,25);
  if (r->>'total')::integer<>1 or r#>>'{items,0,record_type}'<>'invitation' or r#>>'{items,0,locations,0,id}'<>l1::text then raise exception 'El pendiente no aparece con rol y alcance: %',r;end if;

  perform set_config('request.jwt.claim.role','service_role',true);perform set_config('request.jwt.claim.sub','',true);
  r:=public.prepare_pending_user_registration('nuevo@example.invalid');
  if not coalesce((r->>'allowed')::boolean,false) or r->>'user_id' is not null then raise exception 'El correo autorizado no puede iniciar su alta: %',r;end if;
  if coalesce((public.prepare_pending_user_registration('otro@example.invalid')->>'allowed')::boolean,false) then raise exception 'Un correo no autorizado pudo registrarse.';end if;
  insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,last_sign_in_at,raw_user_meta_data) values
    (new_user,'authenticated','authenticated','nuevo@example.invalid','',now(),null,'{"registration_pending":true}'::jsonb);
  r:=public.complete_pending_user_registration(new_user,'nuevo@example.invalid','Persona Nueva');
  if not coalesce((r->>'activated')::boolean,false) then raise exception 'No se completó el registro: %',r;end if;
  if not exists(select 1 from public.profiles where id=new_user and full_name='Persona Nueva' and default_company_id=c) then raise exception 'El perfil no quedó ligado a la empresa.';end if;
  if not exists(select 1 from public.user_roles ur join public.roles ro on ro.id=ur.role_id where ur.user_id=new_user and ur.company_id=c and ur.is_active and ro.code='sucursal') then raise exception 'El rol preparado no fue reclamado.';end if;
  if not exists(select 1 from public.company_user_invitations where id=invite_id and status='claimed' and claimed_by=new_user) then raise exception 'La autorización no quedó reclamada.';end if;
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',new_user::text,true);
  if not public.can_access_location(l1) or public.can_access_location(l2) then raise exception 'RLS no respetó la sucursal preparada.';end if;
  if (select count(*) from public.audit_log where company_id=c and action='company.user_registration_completed' and actor_id=new_user)<>1 then raise exception 'La activación no quedó auditada.';end if;
  raise notice 'Registro pendiente: correo autorizado, alta cerrada, empresa, rol, alcance, RLS y auditoría aprobados.';
end;$pending_registration$;
rollback;
