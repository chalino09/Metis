begin;

do $$
declare
  c uuid:='80800000-0000-4000-8000-000000000001';
  c2 uuid:='80800000-0000-4000-8000-000000000002';
  super_user uuid:='80800000-0000-4000-8000-000000000003';
  admin_user uuid:='80800000-0000-4000-8000-000000000004';
  stamp timestamptz;result jsonb;created jsonb;blocked boolean:=false;
begin
  insert into public.companies(id,legal_name,display_name) values
    (c,'Piloto Restaurant','Piloto Restaurant'),(c2,'Empresa Core','Empresa Core');
  if (select product_experience_code from public.companies where id=c2)<>'core' then
    raise exception 'Una empresa nueva no conservó la experiencia core.';
  end if;
  insert into auth.users(id,aud,role,email,encrypted_password) values
    (super_user,'authenticated','authenticated','experience-super@example.invalid',''),
    (admin_user,'authenticated','authenticated','experience-admin@example.invalid','');
  insert into public.user_roles(user_id,role_id,company_id)
    select super_user,id,null from public.roles where code='super_admin';
  insert into public.user_roles(user_id,role_id,company_id)
    select admin_user,id,c from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',super_user::text,true);
  created:=public.create_company('Empresa creada','Empresa creada','Prueba de alta','80800000-0000-4000-8000-000000000009');
  if created->>'experience_code'<>'core' or coalesce((created->>'idempotent')::boolean,true) then
    raise exception 'La empresa nueva no nació en core: %',created;
  end if;
  if (select default_company_id from public.profiles where id=super_user)<>(created->>'company_id')::uuid then
    raise exception 'La empresa nueva no quedó seleccionada para Superadmin.';
  end if;
  created:=public.create_company('Empresa creada','Empresa creada','Prueba de alta','80800000-0000-4000-8000-000000000009');
  if not coalesce((created->>'idempotent')::boolean,false) then raise exception 'La creación no fue idempotente.';end if;
  select updated_at into stamp from public.companies where id=c;
  result:=public.set_company_product_experience(c,'restaurant','Activación del piloto',stamp,'80800000-0000-4000-8000-000000000010');
  if result->>'experience_code'<>'restaurant' or coalesce((result->>'idempotent')::boolean,true) then
    raise exception 'No se activó Restaurant: %',result;
  end if;
  result:=public.set_company_product_experience(c,'restaurant','Activación del piloto',stamp,'80800000-0000-4000-8000-000000000010');
  if not coalesce((result->>'idempotent')::boolean,false) then raise exception 'El cambio no fue idempotente.';end if;
  perform set_config('request.jwt.claim.sub',admin_user::text,true);
  begin
    perform public.set_company_product_experience(c,'core','Intento no autorizado',(select updated_at from public.companies where id=c),'80800000-0000-4000-8000-000000000011');
  exception when others then blocked:=position('superadmin' in lower(sqlerrm))>0;end;
  if not blocked then raise exception 'Administrador cambió una configuración reservada.';end if;
  blocked:=false;
  begin
    perform public.create_company('No autorizada','No autorizada','Intento no autorizado','80800000-0000-4000-8000-000000000012');
  exception when others then blocked:=position('superadmin' in lower(sqlerrm))>0;end;
  if not blocked then raise exception 'Administrador creó una empresa.';end if;
  if (select product_experience_code from public.companies where id=c)<>'restaurant' then raise exception 'El intento no autorizado alteró la experiencia.';end if;
end $$;

rollback;
