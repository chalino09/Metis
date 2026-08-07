-- Shopify OAuth · autorización desde Satrapy y token cifrado por tienda.

begin;

alter table public.shopify_stores
  add column if not exists access_token_ciphertext text,
  add column if not exists granted_scopes text[] not null default '{}'::text[],
  add column if not exists token_expires_at timestamptz;

alter table public.shopify_stores drop constraint if exists shopify_stores_token_shape;
alter table public.shopify_stores add constraint shopify_stores_token_shape check(
  (installed_at is null and access_token_ciphertext is null)
  or(installed_at is not null and nullif(trim(access_token_ciphertext),'') is not null)
);

create or replace function public.authorize_shopify_connection(p_company_id uuid)
returns boolean language plpgsql stable security definer set search_path=public as $$
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_sales_orders') then
    raise exception 'No autorizado para conectar Shopify.';
  end if;
  return true;
end $$;

create or replace function public.complete_shopify_connection(
  p_company_id uuid,p_actor_id uuid,p_shop_domain text,p_shop_gid text,p_access_token_ciphertext text,p_granted_scopes text[],p_token_expires_at timestamptz
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_store_id uuid;v_domain text:=lower(trim(coalesce(p_shop_domain,'')));
begin
  if auth.role()<>'service_role' then raise exception 'Disponible únicamente para el servidor de integración.';end if;
  if not exists(select 1 from public.companies where id=p_company_id) or not exists(select 1 from auth.users where id=p_actor_id) then raise exception 'Empresa o responsable no disponible.';end if;
  if v_domain!~'^[a-z0-9][a-z0-9-]*\.myshopify\.com$' or nullif(trim(coalesce(p_shop_gid,'')),'') is null or nullif(trim(coalesce(p_access_token_ciphertext,'')),'') is null then raise exception 'La conexión de Shopify está incompleta.';end if;
  insert into public.shopify_stores(company_id,shop_domain,shop_gid,installed_at,access_token_ciphertext,granted_scopes,token_expires_at,last_error_code)
  values(p_company_id,v_domain,trim(p_shop_gid),now(),trim(p_access_token_ciphertext),coalesce(p_granted_scopes,'{}'::text[]),p_token_expires_at,null)
  on conflict(company_id) do update set shop_domain=excluded.shop_domain,shop_gid=excluded.shop_gid,installed_at=excluded.installed_at,access_token_ciphertext=excluded.access_token_ciphertext,granted_scopes=excluded.granted_scopes,token_expires_at=excluded.token_expires_at,last_error_code=null
  returning id into v_store_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,p_actor_id,'ecommerce.shopify_connected','shopify_store',v_store_id,jsonb_build_object('shop_domain',v_domain,'granted_scopes',coalesce(p_granted_scopes,'{}'::text[])));
  return v_store_id;
end $$;

revoke all on function public.authorize_shopify_connection(uuid) from public,anon;
grant execute on function public.authorize_shopify_connection(uuid) to authenticated;
revoke all on function public.complete_shopify_connection(uuid,uuid,text,text,text,text[],timestamptz) from public,anon,authenticated;
grant execute on function public.complete_shopify_connection(uuid,uuid,text,text,text,text[],timestamptz) to service_role;

commit;
