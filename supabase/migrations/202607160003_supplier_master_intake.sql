-- Module 3A: supplier master intake and canonical phone handling.

alter table public.suppliers add column tax_regime text;
alter table public.suppliers add column fiscal_postal_code text;
alter table public.suppliers add column country_code text not null default 'MX' check(country_code~'^[A-Z]{2}$');
alter table public.suppliers add column contact_name text;
alter table public.suppliers add column email text;
alter table public.suppliers add column phone_e164 text;
alter table public.suppliers add column phone_extension text;
alter table public.suppliers add column phone_status text check(phone_status in('canonical','missing_area_code','invalid'));
alter table public.suppliers add column postal_code text;

create index suppliers_company_email_idx on public.suppliers(company_id,lower(email)) where email is not null;
create index suppliers_company_phone_idx on public.suppliers(company_id,phone_e164) where phone_e164 is not null;

create or replace function public.canonical_supplier_phone(p_value text,p_country_code text default 'MX')
returns text language plpgsql immutable parallel safe as $$
declare v_digits text:=regexp_replace(coalesce(p_value,''),'[^0-9]','','g');
begin
  if coalesce(p_country_code,'MX')='MX' then
    if v_digits~'^52[0-9]{10}$' then return '+'||v_digits; end if;
    if v_digits~'^[0-9]{10}$' then return '+52'||v_digits; end if;
  elsif v_digits~'^[1-9][0-9]{7,14}$' then return '+'||v_digits;
  end if;
  return null;
end $$;

create or replace function public.supplier_phone_without_placeholder_extension(p_value text)
returns text language sql immutable parallel safe as $$
  select nullif(trim(regexp_replace(coalesce(p_value,''),'-0000\s*$','','i')),'')
$$;

update public.supplier_external_references er set metadata=er.metadata||jsonb_build_object('source_phone',s.phone)
from public.suppliers s where er.supplier_id=s.id and er.source_system='alpha' and s.phone is not null;

update public.suppliers set
  phone_e164=public.canonical_supplier_phone(public.supplier_phone_without_placeholder_extension(phone),'MX'),
  phone_extension=null,
  phone_status=case
    when public.canonical_supplier_phone(public.supplier_phone_without_placeholder_extension(phone),'MX') is not null then 'canonical'
    when regexp_replace(public.supplier_phone_without_placeholder_extension(phone),'[^0-9]','','g')~'^[0-9]{7,8}$' then 'missing_area_code'
    when nullif(trim(coalesce(phone,'')),'') is not null then 'invalid' end,
  phone=public.supplier_phone_without_placeholder_extension(phone)
where phone is not null;

create or replace function public.normalize_supplier_phone_columns()
returns trigger language plpgsql set search_path=public as $$
declare v_source text;v_digits text;
begin
  if (tg_op='INSERT' or new.phone is distinct from old.phone) and new.phone_e164 is null then
    v_source:=public.supplier_phone_without_placeholder_extension(new.phone);
    v_digits:=regexp_replace(coalesce(v_source,''),'[^0-9]','','g');
    new.phone:=v_source;
    new.phone_e164:=public.canonical_supplier_phone(v_source,coalesce(new.country_code,'MX'));
    new.phone_status:=case when new.phone_e164 is not null then 'canonical' when v_digits~'^[0-9]{7,8}$' then 'missing_area_code' when v_source is not null then 'invalid' end;
  end if;
  if trim(coalesce(new.phone_extension,'')) in('','0000') then new.phone_extension:=null;end if;
  return new;
end $$;
create trigger suppliers_normalize_phone before insert or update of phone,phone_e164,phone_extension on public.suppliers for each row execute function public.normalize_supplier_phone_columns();

drop function if exists public.save_supplier(uuid,uuid,text,text,text,text,text,text,text,text,text,text,boolean,timestamptz);
create or replace function public.save_supplier(
  p_company_id uuid,p_supplier_id uuid,p_display_name text,p_legal_name text default null,p_tax_id text default null,
  p_tax_regime text default null,p_fiscal_postal_code text default null,p_country_code text default 'MX',
  p_contact_name text default null,p_email text default null,p_phone text default null,p_phone_extension text default null,
  p_supplier_category text default null,p_address_line text default null,p_neighborhood text default null,p_municipality text default null,
  p_state_name text default null,p_postal_code text default null,p_is_active boolean default true,p_expected_updated_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_id uuid;v_code text;v_tax text:=public.canonical_supplier_tax_id(p_tax_id);v_country text:=upper(trim(coalesce(p_country_code,'MX')));v_phone text;v_before jsonb;v_after jsonb;v_candidate uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_suppliers') then raise exception 'No autorizado para administrar proveedores.';end if;
  if nullif(trim(coalesce(p_display_name,'')),'') is null then raise exception 'El nombre comercial es obligatorio.';end if;
  if v_country!~'^[A-Z]{2}$' then raise exception 'Captura el país con dos letras, por ejemplo MX.';end if;
  if nullif(trim(coalesce(p_tax_id,'')),'') is not null and v_tax is null then raise exception 'El RFC no es canónico; corrígelo o déjalo vacío.';end if;
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
    insert into public.suppliers(company_id,code,display_name,legal_name,tax_id,tax_regime,fiscal_postal_code,country_code,contact_name,email,phone,phone_e164,phone_extension,phone_status,supplier_category,address_line,neighborhood,municipality,state_name,postal_code,is_active)
    values(p_company_id,v_code,trim(p_display_name),nullif(trim(p_legal_name),''),v_tax,nullif(trim(p_tax_regime),''),nullif(trim(p_fiscal_postal_code),''),v_country,nullif(trim(p_contact_name),''),nullif(lower(trim(p_email)),''),v_phone,v_phone,nullif(trim(p_phone_extension),''),case when v_phone is not null then 'canonical' end,nullif(trim(p_supplier_category),''),nullif(trim(p_address_line),''),nullif(trim(p_neighborhood),''),nullif(trim(p_municipality),''),nullif(trim(p_state_name),''),nullif(trim(p_postal_code),''),coalesce(p_is_active,true)) returning id,to_jsonb(suppliers.*) into v_id,v_after;
    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier.created','supplier',v_id,jsonb_build_object('after',v_after));
  else
    select to_jsonb(s),s.id,s.code into v_before,v_id,v_code from public.suppliers s where s.id=p_supplier_id and s.company_id=p_company_id for update;
    if not found then raise exception 'Proveedor no encontrado.';end if;
    if p_expected_updated_at is not null and (v_before->>'updated_at')::timestamptz is distinct from p_expected_updated_at then raise exception 'El proveedor cambió desde que lo abriste. Actualiza y vuelve a intentar.';end if;
    update public.suppliers set display_name=trim(p_display_name),legal_name=nullif(trim(p_legal_name),''),tax_id=v_tax,tax_regime=nullif(trim(p_tax_regime),''),fiscal_postal_code=nullif(trim(p_fiscal_postal_code),''),country_code=v_country,contact_name=nullif(trim(p_contact_name),''),email=nullif(lower(trim(p_email)),''),phone=v_phone,phone_e164=v_phone,phone_extension=nullif(trim(p_phone_extension),''),phone_status=case when v_phone is not null then 'canonical' end,supplier_category=nullif(trim(p_supplier_category),''),address_line=nullif(trim(p_address_line),''),neighborhood=nullif(trim(p_neighborhood),''),municipality=nullif(trim(p_municipality),''),state_name=nullif(trim(p_state_name),''),postal_code=nullif(trim(p_postal_code),''),is_active=coalesce(p_is_active,true),updated_by=auth.uid() where id=v_id returning to_jsonb(suppliers.*) into v_after;
    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier.updated','supplier',v_id,jsonb_build_object('before',v_before,'after',v_after));
  end if;
  return v_after;
end $$;

create or replace function public.search_suppliers(
  p_company_id uuid,p_query text default null,p_page integer default 1,p_page_size integer default 50,p_is_active boolean default null,p_origin text default null
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),100);v_q text:=lower(trim(coalesce(p_query,'')));v_total bigint;v_items jsonb;
begin
 if auth.uid() is null or not public.has_company_permission(p_company_id,'view_suppliers') then raise exception 'No autorizado para consultar proveedores.';end if;
 with filtered as materialized(select s.* from public.suppliers s where s.company_id=p_company_id and(p_is_active is null or s.is_active=p_is_active) and(v_q='' or lower(s.code) like '%'||v_q||'%' or lower(s.display_name) like '%'||v_q||'%' or lower(coalesce(s.legal_name,'')) like '%'||v_q||'%' or lower(coalesce(s.tax_id,'')) like '%'||v_q||'%' or lower(coalesce(s.phone_e164,s.phone,'')) like '%'||v_q||'%')),counted as(select count(*) total from filtered),paged as(select * from filtered order by display_name,id limit v_size offset(v_page-1)*v_size)
 select(select total from counted),coalesce(jsonb_agg(jsonb_build_object('id',id,'code',code,'display_name',display_name,'legal_name',legal_name,'tax_id',tax_id,'tax_regime',tax_regime,'fiscal_postal_code',fiscal_postal_code,'country_code',country_code,'contact_name',contact_name,'email',email,'phone',coalesce(phone_e164,phone),'phone_extension',phone_extension,'phone_status',phone_status,'supplier_category',supplier_category,'address_line',address_line,'neighborhood',neighborhood,'municipality',municipality,'state_name',state_name,'postal_code',postal_code,'is_active',is_active,'updated_at',updated_at) order by display_name,id),'[]'::jsonb) into v_total,v_items from paged;
 return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',coalesce(v_total,0)));
end $$;

revoke all on function public.canonical_supplier_phone(text,text),public.supplier_phone_without_placeholder_extension(text),public.save_supplier(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,boolean,timestamptz) from public;
grant execute on function public.save_supplier(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,boolean,timestamptz) to authenticated;
