-- Experiencia de producto por empresa. El valor predeterminado conserva Satrapy
-- completo; Restaurant sólo modifica la superficie visible y su vocabulario.

begin;

alter table public.companies
  add column if not exists product_experience_code text not null default 'core';

alter table public.companies drop constraint if exists companies_product_experience_code_check;
alter table public.companies add constraint companies_product_experience_code_check
  check(product_experience_code in('core','restaurant'));

insert into public.permissions(code,description) values
  ('manage_product_experience','Elegir la experiencia de producto visible para una empresa.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code='super_admin' and p.code='manage_product_experience'
on conflict do nothing;

create or replace function public.set_company_product_experience(
  p_company_id uuid,
  p_experience_code text,
  p_reason text,
  p_expected_updated_at timestamptz,
  p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_company public.companies%rowtype;v_result jsonb;v_previous_experience_code text;
begin
  if auth.uid() is null or not public.is_super_admin() then
    raise exception 'Solo Superadmin puede cambiar la experiencia del producto.';
  end if;
  if p_experience_code not in('core','restaurant') then raise exception 'Experiencia no disponible.';end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null or p_client_request_id is null then
    raise exception 'El motivo y la referencia son obligatorios.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||':product-experience',0));
  select metadata->'result' into v_result from public.audit_log
  where company_id=p_company_id and action='company.product_experience_changed'
    and metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_result is not null then return v_result||jsonb_build_object('idempotent',true);end if;
  select * into v_company from public.companies where id=p_company_id for update;
  if not found then raise exception 'Empresa no disponible.';end if;
  if p_expected_updated_at is null or v_company.updated_at<>p_expected_updated_at then
    raise exception 'La empresa cambió mientras editabas. Actualiza y vuelve a intentarlo.';
  end if;
  v_previous_experience_code:=v_company.product_experience_code;
  update public.companies set product_experience_code=p_experience_code,updated_at=clock_timestamp()
  where id=p_company_id returning * into v_company;
  v_result:=jsonb_build_object(
    'company_id',v_company.id,'experience_code',v_company.product_experience_code,
    'updated_at',v_company.updated_at,'idempotent',false
  );
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'company.product_experience_changed','company',p_company_id,
    jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),
      'previous_experience_code',v_previous_experience_code,
      'result',v_result));
  return v_result;
end $$;

create or replace function public.create_company(
  p_legal_name text,
  p_display_name text,
  p_reason text,
  p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_company public.companies%rowtype;v_result jsonb;
begin
  if auth.uid() is null or not public.is_super_admin() then
    raise exception 'Solo Superadmin puede crear empresas.';
  end if;
  if nullif(trim(coalesce(p_legal_name,'')),'') is null or nullif(trim(coalesce(p_display_name,'')),'') is null then
    raise exception 'Captura la razón social y el nombre visible.';
  end if;
  if char_length(trim(p_legal_name))>240 or char_length(trim(p_display_name))>240 then
    raise exception 'La razón social y el nombre visible admiten hasta 240 caracteres.';
  end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null or p_client_request_id is null then
    raise exception 'El motivo y la referencia son obligatorios.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':company-creation',0));
  select metadata->'result' into v_result from public.audit_log
  where actor_id=auth.uid() and action='company.created' and metadata->>'request_id'=p_client_request_id::text
  limit 1;
  if v_result is not null then return v_result||jsonb_build_object('idempotent',true);end if;
  insert into public.companies(legal_name,display_name)
  values(trim(p_legal_name),trim(p_display_name))
  returning * into v_company;
  insert into public.profiles(id) values(auth.uid()) on conflict(id) do nothing;
  update public.profiles set default_company_id=v_company.id where id=auth.uid();
  v_result:=jsonb_build_object(
    'company_id',v_company.id,'legal_name',v_company.legal_name,'display_name',v_company.display_name,
    'experience_code',v_company.product_experience_code,'updated_at',v_company.updated_at,'idempotent',false
  );
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_company.id,auth.uid(),'company.created','company',v_company.id,
    jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'result',v_result));
  return v_result;
end $$;

create unique index if not exists audit_company_product_experience_request_uidx
  on public.audit_log(company_id,(metadata->>'request_id'))
  where action='company.product_experience_changed' and metadata ? 'request_id';

create unique index if not exists audit_company_creation_request_uidx
  on public.audit_log(actor_id,(metadata->>'request_id'))
  where action='company.created' and metadata ? 'request_id';

revoke all on function public.set_company_product_experience(uuid,text,text,timestamptz,uuid) from public,anon;
grant execute on function public.set_company_product_experience(uuid,text,text,timestamptz,uuid) to authenticated;
revoke all on function public.create_company(text,text,text,uuid) from public,anon;
grant execute on function public.create_company(text,text,text,uuid) to authenticated;

commit;
notify pgrst,'reload schema';
