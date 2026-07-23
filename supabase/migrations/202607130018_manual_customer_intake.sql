-- Alta manual breve: datos de identificación opcionales, sin abrir condiciones comerciales.

alter table public.customers
  add column if not exists customer_type text,
  add column if not exists notes text;

alter table public.customers drop constraint if exists customers_customer_type_check;
alter table public.customers add constraint customers_customer_type_check check (customer_type is null or customer_type in ('persona_fisica','persona_moral'));

create or replace function public.normalize_customer_tax_id(p_tax_id text)
returns text language plpgsql immutable set search_path=public as $$
declare v_tax_id text;
begin
  v_tax_id:=nullif(regexp_replace(upper(trim(coalesce(p_tax_id,''))),'[^A-Z0-9Ñ&]','','g'),'');
  if v_tax_id is null then return null; end if;
  if v_tax_id !~ '^[A-ZÑ&]{3,4}[0-9]{6}[A-Z0-9]{3}$' then raise exception 'El RFC debe tener 12 o 13 caracteres válidos.'; end if;
  return v_tax_id;
end $$;

create or replace function public.update_customer_general(p_company_id uuid,p_customer_id uuid,p_display_name text,p_tax_id text default null,p_customer_type text default null,p_notes text default null)
returns void language plpgsql security definer set search_path=public as $$
declare v_tax_id text:=public.normalize_customer_tax_id(p_tax_id);
begin
  perform public.assert_customer_master_access(p_company_id,p_customer_id,true);
  if exists(select 1 from public.customers where company_id=p_company_id and lower(tax_id)=lower(v_tax_id) and id<>p_customer_id) then raise exception 'Ya existe un cliente con ese RFC.'; end if;
  if nullif(trim(coalesce(p_customer_type,'')),'') is not null and p_customer_type not in ('persona_fisica','persona_moral') then raise exception 'Tipo de cliente no válido.'; end if;
  update public.customers set display_name=trim(p_display_name),tax_id=v_tax_id,customer_type=nullif(trim(p_customer_type),''),notes=nullif(trim(p_notes),'') where id=p_customer_id;
  perform public.write_sales_audit(p_company_id,'customer.general_updated','customers',p_customer_id,jsonb_build_object('tax_id',v_tax_id,'customer_type',nullif(trim(p_customer_type),'')));
end $$;

create or replace function public.upsert_sale_customer(p_company_id uuid,p_customer_id uuid default null,p_code text default null,p_display_name text default null,p_tax_id text default null,p_email text default null,p_phone text default null,p_price_list_id uuid default null,p_credit_enabled boolean default false,p_credit_limit numeric default 0,p_credit_term_days integer default 0,p_customer_type text default null,p_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_customer_id uuid; v_can_credit boolean; v_existing public.customers%rowtype; v_contact_id uuid; v_tax_id text:=public.normalize_customer_tax_id(p_tax_id); v_type text:=nullif(trim(coalesce(p_customer_type,'')), '');
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_customers') then raise exception 'No autorizado para administrar clientes.'; end if;
  v_can_credit:=public.has_company_permission(p_company_id,'view_customer_credit');
  if nullif(trim(coalesce(p_display_name,'')),'') is null then raise exception 'El nombre o razón social es obligatorio.'; end if;
  if v_type is not null and v_type not in ('persona_fisica','persona_moral') then raise exception 'Tipo de cliente no válido.'; end if;
  if v_tax_id is not null and exists(select 1 from public.customers where company_id=p_company_id and lower(tax_id)=lower(v_tax_id) and id is distinct from p_customer_id) then raise exception 'Ya existe un cliente con ese RFC.'; end if;
  if p_price_list_id is not null and not exists(select 1 from public.price_lists where id=p_price_list_id and company_id=p_company_id and is_active and status='active') then raise exception 'Lista de precio no disponible.'; end if;
  if p_credit_enabled and (not v_can_credit or coalesce(p_credit_limit,0)<=0 or coalesce(p_credit_term_days,0)<=0) then raise exception 'El crédito requiere permiso, límite y plazo vigentes.'; end if;
  if p_customer_id is null then
    insert into public.customers(company_id,code,display_name,tax_id,customer_type,notes,price_list_id,credit_enabled,credit_limit,credit_term_days,is_active,created_by) values(p_company_id,coalesce(nullif(trim(p_code),''),'CLI-'||upper(substr(gen_random_uuid()::text,1,8))),trim(p_display_name),v_tax_id,v_type,nullif(trim(p_notes),''),p_price_list_id,false,0,0,true,auth.uid()) returning id into v_customer_id;
  else
    select * into v_existing from public.customers where id=p_customer_id and company_id=p_company_id for update;
    if not found then raise exception 'Cliente no encontrado.'; end if;
    if v_existing.alpha_external_code is not null then raise exception 'Los clientes importados solo se corrigen mediante un ajuste auditado.'; end if;
    update public.customers set code=coalesce(nullif(trim(p_code),''),code),display_name=trim(p_display_name),tax_id=v_tax_id,customer_type=v_type,notes=nullif(trim(p_notes),''),price_list_id=p_price_list_id,credit_enabled=case when v_can_credit then coalesce(p_credit_enabled,false) else credit_enabled end,credit_limit=case when v_can_credit and p_credit_enabled then round(p_credit_limit,2) when v_can_credit then 0 else credit_limit end,credit_term_days=case when v_can_credit and p_credit_enabled then p_credit_term_days when v_can_credit then 0 else credit_term_days end where id=p_customer_id returning id into v_customer_id;
  end if;
  select id into v_contact_id from public.customer_contacts where customer_id=v_customer_id and is_primary limit 1;
  if nullif(trim(coalesce(p_phone,'')),'') is not null or nullif(trim(coalesce(p_email,'')),'') is not null then
    if v_contact_id is null then insert into public.customer_contacts(company_id,customer_id,display_name,role_name,phone,email,is_primary) values(p_company_id,v_customer_id,trim(p_display_name),'Contacto principal',nullif(trim(p_phone),''),nullif(lower(trim(p_email)),''),true);
    else update public.customer_contacts set display_name=trim(p_display_name),phone=nullif(trim(p_phone),''),email=nullif(lower(trim(p_email)),''),is_primary=true where id=v_contact_id; end if;
  end if;
  perform public.write_sales_audit(p_company_id,case when p_customer_id is null then 'customer.created' else 'customer.updated' end,'customers',v_customer_id,jsonb_build_object('credit_enabled',false,'price_list_id',p_price_list_id,'customer_type',v_type)); return v_customer_id;
end $$;

create or replace function public.get_customer_master(p_company_id uuid, p_customer_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_customer public.customers%rowtype; v_can_credit boolean; v_outstanding numeric;
begin
  v_customer:=public.assert_customer_master_access(p_company_id,p_customer_id,false);
  v_can_credit:=public.has_company_permission(p_company_id,'view_customer_credit');
  select coalesce(sum(outstanding_amount),0) into v_outstanding from public.customer_receivables where customer_id=p_customer_id and company_id=p_company_id;
  return jsonb_build_object('id',v_customer.id,'code',v_customer.code,'display_name',v_customer.display_name,'tax_id',v_customer.tax_id,'customer_type',v_customer.customer_type,'notes',v_customer.notes,'is_active',v_customer.is_active,'is_imported',v_customer.alpha_external_code is not null,'source_reference',v_customer.alpha_external_code,'migration_status',v_customer.migration_status,'addresses',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'label',a.label,'address_line',a.address_line,'neighborhood',a.neighborhood,'municipality',a.municipality,'state_name',a.state_name,'postal_code',a.postal_code,'is_primary',a.is_primary) order by a.is_primary desc,a.created_at) from public.customer_addresses a where a.customer_id=p_customer_id),'[]'::jsonb),'contacts',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'display_name',c.display_name,'role_name',c.role_name,'phone',c.phone,'email',c.email,'is_primary',c.is_primary) order by c.is_primary desc,c.created_at) from public.customer_contacts c where c.customer_id=p_customer_id),'[]'::jsonb),'commercial',jsonb_build_object('price_list_id',v_customer.price_list_id,'price_list_name',(select name from public.price_lists where id=v_customer.price_list_id),'payment_manager',v_customer.payment_manager,'sales_agent',v_customer.sales_agent,'credit_enabled',case when v_can_credit then v_customer.credit_enabled else null end,'credit_limit',case when v_can_credit then v_customer.credit_limit else null end,'credit_term_days',case when v_can_credit then v_customer.credit_term_days else null end,'outstanding_amount',case when v_can_credit then v_outstanding else null end,'available_credit',case when v_can_credit and v_customer.credit_enabled then greatest(v_customer.credit_limit-v_outstanding,0) else null end),'open_receivables',case when v_can_credit then coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'reference',coalesce(r.source_reference,t.folio),'issued_at',r.issued_at,'due_date',r.due_date,'original_amount',r.original_amount,'outstanding_amount',r.outstanding_amount) order by r.due_date,r.issued_at,r.id) from public.customer_receivables r left join public.canonical_tickets t on t.sale_id=r.sale_id where r.customer_id=p_customer_id and r.company_id=p_company_id and r.outstanding_amount>0),'[]'::jsonb) else '[]'::jsonb end);
end $$;

revoke all on function public.normalize_customer_tax_id(text),public.update_customer_general(uuid,uuid,text,text,text,text),public.upsert_sale_customer(uuid,uuid,text,text,text,text,text,uuid,boolean,numeric,integer,text,text) from public;
grant execute on function public.normalize_customer_tax_id(text),public.update_customer_general(uuid,uuid,text,text,text,text),public.upsert_sale_customer(uuid,uuid,text,text,text,text,text,uuid,boolean,numeric,integer,text,text) to authenticated;
