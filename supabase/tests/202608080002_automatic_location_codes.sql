begin;

do $automatic_location_codes$
declare
  c uuid:='a8080000-0000-4000-8000-000000000001';
  admin_user uuid:='a8080000-0000-4000-8000-000000000002';
  first_location jsonb;
  second_location jsonb;
  edited_location jsonb;
begin
  insert into public.companies(id,legal_name,display_name)
  values(c,'Códigos automáticos','Códigos automáticos');

  insert into auth.users(id,aud,role,email,encrypted_password)
  values(admin_user,'authenticated','authenticated','automatic-codes@example.com','');

  insert into public.user_roles(user_id,role_id,company_id)
  select admin_user,id,c from public.roles where code='direccion_admin';

  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',admin_user::text,true);

  first_location:=public.save_company_location(
    c,null,'','Cuapancingo','sucursal',true,'Apertura piloto',null,
    'a8080000-0000-4000-8000-000000000010'
  );
  second_location:=public.save_company_location(
    c,null,null,'Sucursal Norte','sucursal',true,'Apertura aprobada',null,
    'a8080000-0000-4000-8000-000000000011'
  );

  if first_location->>'external_code'<>'SUC-001'
    or second_location->>'external_code'<>'SUC-002' then
    raise exception 'La secuencia automática no es correcta: %, %',first_location,second_location;
  end if;

  edited_location:=public.save_company_location(
    c,(first_location->>'id')::uuid,'CODIGO-MANUAL','Cuapancingo Centro','sucursal',true,
    'Corrección de nombre',(first_location->>'updated_at')::timestamptz,
    'a8080000-0000-4000-8000-000000000012'
  );

  if edited_location->>'external_code'<>'SUC-001' then
    raise exception 'El código cambió después del alta: %',edited_location;
  end if;
end;
$automatic_location_codes$;

rollback;
