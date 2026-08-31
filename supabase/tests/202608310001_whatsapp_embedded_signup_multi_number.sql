begin;

do $$
declare
  c uuid:='68310000-0000-4000-8000-000000000101';
  u uuid:='68310000-0000-4000-8000-000000000102';
  l1 uuid:='68310000-0000-4000-8000-000000000103';
  l2 uuid:='68310000-0000-4000-8000-000000000104';
  n1 uuid;
  n2 uuid;
begin
  insert into public.companies(id,legal_name,display_name) values(c,'WhatsApp Multi QA','WhatsApp Multi QA');
  insert into public.locations(id,company_id,external_code,name) values(l1,c,'QA-1','Sucursal uno'),(l2,c,'QA-2','Sucursal dos');
  insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,last_sign_in_at) values(u,'authenticated','authenticated','whatsapp-multi@example.invalid','',now(),now());
  perform set_config('request.jwt.claim.role','service_role',true);
  n1:=public.complete_whatsapp_connection(c,u,'Ventas uno',l1,'1001','2001','+527971000001','coexistence','v1.test-one');
  n2:=public.complete_whatsapp_connection(c,u,'Ventas dos',l2,'1001','2002','+527971000002','coexistence','v1.test-two');
  if n1=n2 or (select count(*) from public.integration_connections where company_id=c and provider_code='meta_whatsapp')<>2 then raise exception 'No se conservaron ambos números.'; end if;
  if (select configuration->>'location_id' from public.integration_connections where id=n2)<>l2::text then raise exception 'El segundo número no conservó su sucursal.'; end if;
  perform public.complete_whatsapp_connection(c,u,'Ventas uno actualizada',l2,'1001','2001','+527971000001','coexistence','v1.test-three');
  if (select count(*) from public.integration_connections where company_id=c and provider_code='meta_whatsapp')<>2 then raise exception 'Reconectar un número creó un duplicado.'; end if;
  if not exists(select 1 from public.audit_log where company_id=c and action='whatsapp.embedded_signup_completed') then raise exception 'Embedded Signup no fue auditado.'; end if;
  if has_table_privilege('authenticated','public.integration_connections','select') then raise exception 'Las credenciales no deben exponerse al navegador.'; end if;
end $$;

rollback;
