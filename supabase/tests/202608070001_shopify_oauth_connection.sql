begin;

do $$
declare
  c uuid:='60870000-0000-4000-8000-000000000101';
  u uuid:='60870000-0000-4000-8000-000000000102';
begin
  insert into public.companies(id,legal_name,display_name) values(c,'Shopify OAuth QA','Shopify OAuth QA');
  insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,last_sign_in_at)
  values(u,'authenticated','authenticated','shopify-oauth-qa@example.invalid','',now(),now());
  insert into public.user_roles(user_id,role_id,company_id) select u,id,c from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',u::text,true);
  if not public.authorize_shopify_connection(c) then raise exception 'La autorización de conexión no respondió.';end if;
  perform set_config('request.jwt.claim.role','service_role',true);
  perform public.complete_shopify_connection(c,u,'oauth-qa.myshopify.com','gid://shopify/Shop/1','v1.example-ciphertext',array['read_orders','read_customers'],null);
  if(select access_token_ciphertext is null from public.shopify_stores where company_id=c) then raise exception 'No se conservó el token cifrado.';end if;
  if not exists(select 1 from public.audit_log where company_id=c and action='ecommerce.shopify_connected') then raise exception 'No se auditó la conexión.';end if;
  if has_table_privilege('authenticated','public.shopify_stores','select') then raise exception 'El token no debe exponerse a authenticated.';end if;
end $$;

rollback;
