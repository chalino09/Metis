-- Módulo 3A: borrador mínimo y activación condicionada por tipo de persona.

create or replace function public.save_supplier(
  p_company_id uuid,p_supplier_id uuid,p_display_name text,p_legal_name text default null,
  p_legal_entity_type text default null,p_tax_id text default null,p_tax_regime text default null,
  p_fiscal_postal_code text default null,p_country_code text default 'MX',p_contact_name text default null,
  p_email text default null,p_phone text default null,p_phone_extension text default null,p_supplier_category text default null,
  p_address_line text default null,p_neighborhood text default null,p_municipality text default null,
  p_state_name text default null,p_postal_code text default null,p_is_active boolean default true,
  p_expected_updated_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_id uuid;v_code text;v_tax text;v_country text;v_entity_type text:=nullif(lower(trim(p_legal_entity_type)), '');
  v_phone text;v_before jsonb;v_after jsonb;v_candidate uuid;v_active boolean:=coalesce(p_is_active,true);
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_suppliers') then raise exception 'No autorizado para administrar proveedores.';end if;
  if nullif(trim(coalesce(p_display_name,'')),'') is null then raise exception 'El nombre comercial es obligatorio.';end if;
  if v_entity_type is null then raise exception 'El tipo de persona es obligatorio, incluso para guardar un borrador.';end if;
  if v_entity_type not in ('physical','moral') then raise exception 'El tipo de persona debe ser física o moral.';end if;
  v_country:=upper(trim(coalesce(p_country_code,'MX')));
  if v_country!~'^[A-Z]{2}$' then raise exception 'Captura el país con dos letras, por ejemplo MX.';end if;
  if v_country='MX' then
    v_tax:=public.canonical_supplier_tax_id(p_tax_id);
    if nullif(trim(coalesce(p_tax_id,'')),'') is not null and v_tax is null then raise exception 'El RFC no es canónico; corrígelo.';end if;
  else
    v_tax:=nullif(upper(trim(coalesce(p_tax_id,''))), '');
  end if;
  if v_active then
    if v_entity_type='moral' and nullif(trim(coalesce(p_legal_name,'')),'') is null then raise exception 'La razón social es obligatoria para activar una persona moral.';end if;
    if v_country='MX' and v_tax is null then raise exception 'El RFC es obligatorio para activar un proveedor de México.';end if;
    if v_country='MX' and trim(coalesce(p_fiscal_postal_code,'')) !~ '^[0-9]{5}$' then raise exception 'El código postal fiscal de México debe tener 5 dígitos.';end if;
    if nullif(trim(coalesce(p_email,'')),'') is null and nullif(trim(coalesce(p_phone,'')),'') is null then raise exception 'Captura un correo electrónico o teléfono para activar el proveedor.';end if;
  end if;
  if nullif(trim(coalesce(p_email,'')),'') is not null and lower(trim(p_email))!~'^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'El correo electrónico no es válido.';end if;
  if nullif(trim(coalesce(p_phone,'')),'') is not null then
    v_phone:=public.canonical_supplier_phone(p_phone,v_country);
    if v_phone is null then raise exception 'El teléfono debe incluir lada y país; para México captura 10 dígitos.';end if;
  end if;
  select id into v_candidate from public.suppliers where company_id=p_company_id and id is distinct from p_supplier_id and ((v_tax is not null and tax_id=v_tax) or public.normalize_supplier_identity(display_name)=public.normalize_supplier_identity(p_display_name)) limit 1;
  if found then raise exception 'Existe un proveedor candidato con el mismo RFC o identidad. Revisa el catálogo antes de guardar.';end if;
  if p_supplier_id is null then
    loop
      v_code:='SUP-'||upper(substr(gen_random_uuid()::text,1,8));
      exit when not exists(select 1 from public.suppliers where company_id=p_company_id and lower(code)=lower(v_code));
    end loop;
    insert into public.suppliers(company_id,code,display_name,legal_name,legal_entity_type,tax_id,tax_regime,fiscal_postal_code,country_code,contact_name,email,phone,phone_e164,phone_extension,phone_status,supplier_category,address_line,neighborhood,municipality,state_name,postal_code,is_active)
    values(p_company_id,v_code,trim(p_display_name),nullif(trim(p_legal_name),''),v_entity_type,v_tax,nullif(trim(p_tax_regime),''),nullif(trim(p_fiscal_postal_code),''),v_country,nullif(trim(p_contact_name),''),nullif(lower(trim(p_email)),''),v_phone,v_phone,nullif(trim(p_phone_extension),''),case when v_phone is not null then 'canonical' end,nullif(trim(p_supplier_category),''),nullif(trim(p_address_line),''),nullif(trim(p_neighborhood),''),nullif(trim(p_municipality),''),nullif(trim(p_state_name),''),nullif(trim(p_postal_code),''),v_active) returning id,to_jsonb(suppliers.*) into v_id,v_after;
    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier.created','supplier',v_id,jsonb_build_object('after',v_after));
  else
    select to_jsonb(s),s.id,s.code into v_before,v_id,v_code from public.suppliers s where s.id=p_supplier_id and s.company_id=p_company_id for update;
    if not found then raise exception 'Proveedor no encontrado.';end if;
    if p_expected_updated_at is not null and (v_before->>'updated_at')::timestamptz is distinct from p_expected_updated_at then raise exception 'El proveedor cambió desde que lo abriste. Actualiza y vuelve a intentar.';end if;
    update public.suppliers set display_name=trim(p_display_name),legal_name=nullif(trim(p_legal_name),''),legal_entity_type=v_entity_type,tax_id=v_tax,tax_regime=nullif(trim(p_tax_regime),''),fiscal_postal_code=nullif(trim(p_fiscal_postal_code),''),country_code=v_country,contact_name=nullif(trim(p_contact_name),''),email=nullif(lower(trim(p_email)),''),phone=v_phone,phone_e164=v_phone,phone_extension=nullif(trim(p_phone_extension),''),phone_status=case when v_phone is not null then 'canonical' end,supplier_category=nullif(trim(p_supplier_category),''),address_line=nullif(trim(p_address_line),''),neighborhood=nullif(trim(p_neighborhood),''),municipality=nullif(trim(p_municipality),''),state_name=nullif(trim(p_state_name),''),postal_code=coalesce(nullif(trim(p_postal_code),''),postal_code),is_active=v_active,updated_by=auth.uid() where id=v_id returning to_jsonb(suppliers.*) into v_after;
    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier.updated','supplier',v_id,jsonb_build_object('before',v_before,'after',v_after));
  end if;
  return v_after;
end $$;
