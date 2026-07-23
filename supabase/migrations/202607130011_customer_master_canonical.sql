-- Satrapy · canonical customer master.
-- Legacy address/contact columns are migrated once and are no longer read or written.

create table public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  label text not null default 'Principal' check (length(trim(label)) > 0),
  address_line text not null check (length(trim(address_line)) > 0),
  neighborhood text,
  municipality text,
  state_name text,
  postal_code text,
  is_primary boolean not null default false,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index customer_addresses_customer_idx on public.customer_addresses(customer_id, created_at);
create unique index customer_addresses_one_primary_idx on public.customer_addresses(customer_id) where is_primary;

create table public.customer_contacts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  display_name text not null check (length(trim(display_name)) > 0),
  role_name text,
  phone text,
  email text,
  is_primary boolean not null default false,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (nullif(trim(coalesce(phone,'')),'') is not null or nullif(trim(coalesce(email,'')),'') is not null)
);
create index customer_contacts_customer_idx on public.customer_contacts(customer_id, created_at);
create index customer_contacts_phone_idx on public.customer_contacts(company_id, phone) where phone is not null;
create index customer_contacts_email_idx on public.customer_contacts(company_id, lower(email)) where email is not null;
create unique index customer_contacts_one_primary_idx on public.customer_contacts(customer_id) where is_primary;

create trigger customer_addresses_updated_at before update on public.customer_addresses for each row execute function public.set_updated_at();
create trigger customer_contacts_updated_at before update on public.customer_contacts for each row execute function public.set_updated_at();

insert into public.customer_addresses(company_id,customer_id,label,address_line,neighborhood,municipality,state_name,postal_code,is_primary,created_by)
select company_id,id,'Principal',trim(address_line),nullif(trim(neighborhood),''),nullif(trim(municipality),''),nullif(trim(state_name),''),nullif(trim(postal_code),''),true,created_by
from public.customers
where nullif(trim(coalesce(address_line,'')),'') is not null;

insert into public.customer_contacts(company_id,customer_id,display_name,role_name,phone,email,is_primary,created_by)
select company_id,id,coalesce(nullif(trim(contact_name),''),display_name),'Contacto principal',nullif(trim(phone),''),nullif(trim(email),''),true,created_by
from public.customers
where nullif(trim(coalesce(phone,'')),'') is not null or nullif(trim(coalesce(email,'')),'') is not null;

alter table public.customer_addresses enable row level security;
alter table public.customer_contacts enable row level security;
revoke all on public.customer_addresses, public.customer_contacts from authenticated;

create or replace function public.assert_customer_master_access(p_company_id uuid, p_customer_id uuid, p_write boolean default false)
returns public.customers
language plpgsql stable security definer set search_path = public
as $$
declare v_customer public.customers%rowtype;
begin
  if auth.uid() is null or not (public.has_company_permission(p_company_id,'use_pos') or public.has_company_permission(p_company_id,'manage_customers')) then raise exception 'No autorizado para consultar clientes.'; end if;
  if p_write and not public.has_company_permission(p_company_id,'manage_customers') then raise exception 'No autorizado para administrar clientes.'; end if;
  select * into v_customer from public.customers where id=p_customer_id and company_id=p_company_id;
  if not found then raise exception 'Cliente no encontrado.'; end if;
  return v_customer;
end $$;

create or replace function public.get_customer_master(p_company_id uuid, p_customer_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare v_customer public.customers%rowtype; v_can_credit boolean; v_outstanding numeric;
begin
  v_customer:=public.assert_customer_master_access(p_company_id,p_customer_id,false);
  v_can_credit:=public.has_company_permission(p_company_id,'view_customer_credit');
  select coalesce(sum(outstanding_amount),0) into v_outstanding from public.customer_receivables where customer_id=p_customer_id and company_id=p_company_id;
  return jsonb_build_object(
    'id',v_customer.id,'code',v_customer.code,'display_name',v_customer.display_name,'tax_id',v_customer.tax_id,
    'is_active',v_customer.is_active,'is_imported',v_customer.alpha_external_code is not null,
    'source_reference',v_customer.alpha_external_code,'migration_status',v_customer.migration_status,
    'addresses',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'label',a.label,'address_line',a.address_line,'neighborhood',a.neighborhood,'municipality',a.municipality,'state_name',a.state_name,'postal_code',a.postal_code,'is_primary',a.is_primary) order by a.is_primary desc,a.created_at) from public.customer_addresses a where a.customer_id=p_customer_id),'[]'::jsonb),
    'contacts',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'display_name',c.display_name,'role_name',c.role_name,'phone',c.phone,'email',c.email,'is_primary',c.is_primary) order by c.is_primary desc,c.created_at) from public.customer_contacts c where c.customer_id=p_customer_id),'[]'::jsonb),
    'commercial',jsonb_build_object('price_list_id',v_customer.price_list_id,'price_list_name',(select name from public.price_lists where id=v_customer.price_list_id),'payment_manager',v_customer.payment_manager,'sales_agent',v_customer.sales_agent,'credit_enabled',case when v_can_credit then v_customer.credit_enabled else null end,'credit_limit',case when v_can_credit then v_customer.credit_limit else null end,'credit_term_days',case when v_can_credit then v_customer.credit_term_days else null end,'outstanding_amount',case when v_can_credit then v_outstanding else null end,'available_credit',case when v_can_credit and v_customer.credit_enabled then greatest(v_customer.credit_limit-v_outstanding,0) else null end),
    'open_receivables',case when v_can_credit then coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'reference',coalesce(r.source_reference,t.folio),'issued_at',r.issued_at,'due_date',r.due_date,'original_amount',r.original_amount,'outstanding_amount',r.outstanding_amount) order by r.due_date,r.issued_at,r.id) from public.customer_receivables r left join public.canonical_tickets t on t.sale_id=r.sale_id where r.customer_id=p_customer_id and r.company_id=p_company_id and r.outstanding_amount>0),'[]'::jsonb) else '[]'::jsonb end
  );
end $$;

create or replace function public.update_customer_general(p_company_id uuid,p_customer_id uuid,p_display_name text,p_tax_id text default null)
returns void language plpgsql security definer set search_path = public
as $$
declare v_customer public.customers%rowtype;
begin
  v_customer:=public.assert_customer_master_access(p_company_id,p_customer_id,true);
  if v_customer.alpha_external_code is not null then raise exception 'Los datos importados requieren un ajuste auditado.'; end if;
  if nullif(trim(coalesce(p_display_name,'')),'') is null then raise exception 'El nombre es obligatorio.'; end if;
  update public.customers set display_name=trim(p_display_name),tax_id=nullif(upper(trim(p_tax_id)),'') where id=p_customer_id;
  perform public.write_sales_audit(p_company_id,'customer.general_updated','customers',p_customer_id,jsonb_build_object('tax_id',nullif(upper(trim(p_tax_id)),'')));
end $$;

create or replace function public.upsert_customer_address(p_company_id uuid,p_customer_id uuid,p_address_id uuid default null,p_label text default 'Principal',p_address_line text default null,p_neighborhood text default null,p_municipality text default null,p_state_name text default null,p_postal_code text default null,p_is_primary boolean default false)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_customer public.customers%rowtype; v_id uuid;
begin
  v_customer:=public.assert_customer_master_access(p_company_id,p_customer_id,true);
  if v_customer.alpha_external_code is not null then raise exception 'Las direcciones importadas requieren un ajuste auditado.'; end if;
  if nullif(trim(coalesce(p_address_line,'')),'') is null then raise exception 'La dirección es obligatoria.'; end if;
  if p_is_primary then update public.customer_addresses set is_primary=false where customer_id=p_customer_id and (p_address_id is null or id<>p_address_id); end if;
  if p_address_id is null then
    insert into public.customer_addresses(company_id,customer_id,label,address_line,neighborhood,municipality,state_name,postal_code,is_primary)
    values(p_company_id,p_customer_id,coalesce(nullif(trim(p_label),''),'Principal'),trim(p_address_line),nullif(trim(p_neighborhood),''),nullif(trim(p_municipality),''),nullif(trim(p_state_name),''),nullif(trim(p_postal_code),''),p_is_primary or not exists(select 1 from public.customer_addresses where customer_id=p_customer_id)) returning id into v_id;
  else
    update public.customer_addresses set label=coalesce(nullif(trim(p_label),''),'Principal'),address_line=trim(p_address_line),neighborhood=nullif(trim(p_neighborhood),''),municipality=nullif(trim(p_municipality),''),state_name=nullif(trim(p_state_name),''),postal_code=nullif(trim(p_postal_code),''),is_primary=p_is_primary where id=p_address_id and customer_id=p_customer_id and company_id=p_company_id returning id into v_id;
  end if;
  if v_id is null then raise exception 'Dirección no encontrada.'; end if;
  perform public.write_sales_audit(p_company_id,'customer.address_saved','customer_addresses',v_id,jsonb_build_object('customer_id',p_customer_id,'is_primary',p_is_primary)); return v_id;
end $$;

create or replace function public.delete_customer_address(p_company_id uuid,p_customer_id uuid,p_address_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare v_customer public.customers%rowtype; v_was_primary boolean;
begin
  v_customer:=public.assert_customer_master_access(p_company_id,p_customer_id,true);
  if v_customer.alpha_external_code is not null then raise exception 'Las direcciones importadas requieren un ajuste auditado.'; end if;
  delete from public.customer_addresses where id=p_address_id and customer_id=p_customer_id and company_id=p_company_id returning is_primary into v_was_primary;
  if v_was_primary then update public.customer_addresses set is_primary=true where id=(select id from public.customer_addresses where customer_id=p_customer_id order by created_at limit 1); end if;
  perform public.write_sales_audit(p_company_id,'customer.address_deleted','customer_addresses',p_address_id,jsonb_build_object('customer_id',p_customer_id));
end $$;

create or replace function public.upsert_customer_contact(p_company_id uuid,p_customer_id uuid,p_contact_id uuid default null,p_display_name text default null,p_role_name text default null,p_phone text default null,p_email text default null,p_is_primary boolean default false)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_customer public.customers%rowtype; v_id uuid;
begin
  v_customer:=public.assert_customer_master_access(p_company_id,p_customer_id,true);
  if v_customer.alpha_external_code is not null then raise exception 'Los contactos importados requieren un ajuste auditado.'; end if;
  if nullif(trim(coalesce(p_display_name,'')),'') is null or (nullif(trim(coalesce(p_phone,'')),'') is null and nullif(trim(coalesce(p_email,'')),'') is null) then raise exception 'Captura el nombre y al menos un teléfono o correo.'; end if;
  if p_is_primary then update public.customer_contacts set is_primary=false where customer_id=p_customer_id and (p_contact_id is null or id<>p_contact_id); end if;
  if p_contact_id is null then
    insert into public.customer_contacts(company_id,customer_id,display_name,role_name,phone,email,is_primary)
    values(p_company_id,p_customer_id,trim(p_display_name),nullif(trim(p_role_name),''),nullif(trim(p_phone),''),nullif(lower(trim(p_email)),''),p_is_primary or not exists(select 1 from public.customer_contacts where customer_id=p_customer_id)) returning id into v_id;
  else
    update public.customer_contacts set display_name=trim(p_display_name),role_name=nullif(trim(p_role_name),''),phone=nullif(trim(p_phone),''),email=nullif(lower(trim(p_email)),''),is_primary=p_is_primary where id=p_contact_id and customer_id=p_customer_id and company_id=p_company_id returning id into v_id;
  end if;
  if v_id is null then raise exception 'Contacto no encontrado.'; end if;
  perform public.write_sales_audit(p_company_id,'customer.contact_saved','customer_contacts',v_id,jsonb_build_object('customer_id',p_customer_id,'is_primary',p_is_primary)); return v_id;
end $$;

create or replace function public.delete_customer_contact(p_company_id uuid,p_customer_id uuid,p_contact_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare v_customer public.customers%rowtype; v_was_primary boolean;
begin
  v_customer:=public.assert_customer_master_access(p_company_id,p_customer_id,true);
  if v_customer.alpha_external_code is not null then raise exception 'Los contactos importados requieren un ajuste auditado.'; end if;
  delete from public.customer_contacts where id=p_contact_id and customer_id=p_customer_id and company_id=p_company_id returning is_primary into v_was_primary;
  if v_was_primary then update public.customer_contacts set is_primary=true where id=(select id from public.customer_contacts where customer_id=p_customer_id order by created_at limit 1); end if;
  perform public.write_sales_audit(p_company_id,'customer.contact_deleted','customer_contacts',p_contact_id,jsonb_build_object('customer_id',p_customer_id));
end $$;

create or replace function public.update_customer_commercial(p_company_id uuid,p_customer_id uuid,p_price_list_id uuid default null,p_payment_manager text default null,p_sales_agent text default null,p_credit_enabled boolean default false,p_credit_limit numeric default 0,p_credit_term_days integer default 0)
returns void language plpgsql security definer set search_path = public
as $$
declare v_customer public.customers%rowtype;
begin
  v_customer:=public.assert_customer_master_access(p_company_id,p_customer_id,true);
  if v_customer.alpha_external_code is not null then raise exception 'Los datos importados requieren un ajuste auditado.'; end if;
  if p_price_list_id is not null and not exists(select 1 from public.price_lists where id=p_price_list_id and company_id=p_company_id and is_active and status='active') then raise exception 'Lista de precios no disponible.'; end if;
  if p_credit_enabled and not public.has_company_permission(p_company_id,'view_customer_credit') then raise exception 'No autorizado para administrar crédito.'; end if;
  if p_credit_enabled and (coalesce(p_credit_limit,0)<=0 or coalesce(p_credit_term_days,0)<=0) then raise exception 'El crédito requiere límite y plazo mayores a cero.'; end if;
  update public.customers set price_list_id=p_price_list_id,payment_manager=nullif(trim(p_payment_manager),''),sales_agent=nullif(trim(p_sales_agent),''),credit_enabled=coalesce(p_credit_enabled,false),credit_limit=case when p_credit_enabled then round(p_credit_limit,2) else 0 end,credit_term_days=case when p_credit_enabled then p_credit_term_days else 0 end where id=p_customer_id;
  perform public.write_sales_audit(p_company_id,'customer.commercial_updated','customers',p_customer_id,jsonb_build_object('price_list_id',p_price_list_id,'credit_enabled',p_credit_enabled,'credit_limit',case when p_credit_enabled then round(p_credit_limit,2) else 0 end,'credit_term_days',case when p_credit_enabled then p_credit_term_days else 0 end));
end $$;

create or replace function public.create_pos_cash_customer(p_company_id uuid,p_location_id uuid,p_display_name text,p_tax_id text default null,p_phone text default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_customer_id uuid; v_code text; v_price_list_id uuid;
begin
  perform public.assert_pos_access(p_company_id,p_location_id,'use_pos');
  if not public.has_company_permission(p_company_id,'manage_customers') then raise exception 'No autorizado para crear clientes.'; end if;
  if nullif(trim(coalesce(p_display_name,'')),'') is null then raise exception 'El nombre es obligatorio.'; end if;
  if nullif(trim(coalesce(p_tax_id,'')),'') is not null and exists(select 1 from public.customers where company_id=p_company_id and lower(tax_id)=lower(trim(p_tax_id))) then raise exception 'Ya existe un cliente con ese RFC.'; end if;
  select coalesce(l.default_price_list_id,c.default_price_list_id) into v_price_list_id from public.locations l join public.companies c on c.id=l.company_id where l.id=p_location_id and l.company_id=p_company_id;
  v_code:='CLI-'||upper(substr(gen_random_uuid()::text,1,8));
  insert into public.customers(company_id,code,display_name,tax_id,price_list_id,credit_enabled,credit_limit,credit_term_days,created_by)
  values(p_company_id,v_code,trim(p_display_name),nullif(upper(trim(p_tax_id)),''),v_price_list_id,false,0,0,auth.uid()) returning id into v_customer_id;
  if nullif(trim(coalesce(p_phone,'')),'') is not null then insert into public.customer_contacts(company_id,customer_id,display_name,role_name,phone,is_primary) values(p_company_id,v_customer_id,trim(p_display_name),'Contacto principal',trim(p_phone),true); end if;
  perform public.write_sales_audit(p_company_id,'customer.quick_created','customers',v_customer_id,jsonb_build_object('location_id',p_location_id,'price_list_id',v_price_list_id,'credit_enabled',false));
  return jsonb_build_object('id',v_customer_id,'code',v_code,'display_name',trim(p_display_name),'credit_enabled',false,'price_list_id',v_price_list_id,'migration_status','manual','alpha_external_code',null);
end $$;

create or replace function public.upsert_sale_customer(p_company_id uuid,p_customer_id uuid default null,p_code text default null,p_display_name text default null,p_tax_id text default null,p_email text default null,p_phone text default null,p_price_list_id uuid default null,p_credit_enabled boolean default false,p_credit_limit numeric default 0,p_credit_term_days integer default 0)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_customer_id uuid; v_can_credit boolean; v_existing public.customers%rowtype; v_contact_id uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_customers') then raise exception 'No autorizado para administrar clientes.'; end if;
  v_can_credit:=public.has_company_permission(p_company_id,'view_customer_credit');
  if nullif(trim(coalesce(p_display_name,'')),'') is null then raise exception 'El nombre del cliente es obligatorio.'; end if;
  if p_price_list_id is not null and not exists(select 1 from public.price_lists where id=p_price_list_id and company_id=p_company_id and is_active and status='active') then raise exception 'Lista de precio no disponible.'; end if;
  if p_credit_enabled and (not v_can_credit or coalesce(p_credit_limit,0)<=0 or coalesce(p_credit_term_days,0)<=0) then raise exception 'El crédito requiere permiso, límite y plazo vigentes.'; end if;
  if p_customer_id is null then
    insert into public.customers(company_id,code,display_name,tax_id,price_list_id,credit_enabled,credit_limit,credit_term_days,created_by) values(p_company_id,coalesce(nullif(trim(p_code),''),'CLI-'||upper(substr(gen_random_uuid()::text,1,8))),trim(p_display_name),nullif(upper(trim(p_tax_id)),''),p_price_list_id,coalesce(p_credit_enabled,false),case when p_credit_enabled then round(p_credit_limit,2) else 0 end,case when p_credit_enabled then p_credit_term_days else 0 end,auth.uid()) returning id into v_customer_id;
  else
    select * into v_existing from public.customers where id=p_customer_id and company_id=p_company_id for update;
    if not found then raise exception 'Cliente no encontrado.'; end if;
    if v_existing.alpha_external_code is not null then raise exception 'Los clientes importados solo se corrigen mediante un ajuste auditado.'; end if;
    update public.customers set code=coalesce(nullif(trim(p_code),''),code),display_name=trim(p_display_name),tax_id=nullif(upper(trim(p_tax_id)),''),price_list_id=p_price_list_id,credit_enabled=case when v_can_credit then coalesce(p_credit_enabled,false) else credit_enabled end,credit_limit=case when v_can_credit and p_credit_enabled then round(p_credit_limit,2) when v_can_credit then 0 else credit_limit end,credit_term_days=case when v_can_credit and p_credit_enabled then p_credit_term_days when v_can_credit then 0 else credit_term_days end where id=p_customer_id returning id into v_customer_id;
  end if;
  select id into v_contact_id from public.customer_contacts where customer_id=v_customer_id and is_primary limit 1;
  if nullif(trim(coalesce(p_phone,'')),'') is not null or nullif(trim(coalesce(p_email,'')),'') is not null then
    if v_contact_id is null then insert into public.customer_contacts(company_id,customer_id,display_name,role_name,phone,email,is_primary) values(p_company_id,v_customer_id,trim(p_display_name),'Contacto principal',nullif(trim(p_phone),''),nullif(lower(trim(p_email)),''),true);
    else update public.customer_contacts set display_name=trim(p_display_name),phone=nullif(trim(p_phone),''),email=nullif(lower(trim(p_email)),'') where id=v_contact_id; end if;
  elsif v_contact_id is not null then delete from public.customer_contacts where id=v_contact_id; end if;
  perform public.write_sales_audit(p_company_id,case when p_customer_id is null then 'customer.created' else 'customer.updated' end,'customers',v_customer_id,jsonb_build_object('credit_enabled',coalesce(p_credit_enabled,false),'price_list_id',p_price_list_id)); return v_customer_id;
end $$;

-- Canonical search: contact data comes only from customer_contacts.
create or replace function public.customer_matches_query(p_customer_id uuid,p_query text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(p_query,'')='' or exists(select 1 from public.customers c where c.id=p_customer_id and (lower(c.code) like '%'||p_query||'%' or lower(c.display_name) like '%'||p_query||'%' or lower(coalesce(c.tax_id,'')) like '%'||p_query||'%')) or exists(select 1 from public.customer_contacts cc where cc.customer_id=p_customer_id and (lower(coalesce(cc.phone,'')) like '%'||p_query||'%' or lower(coalesce(cc.email,'')) like '%'||p_query||'%'));
$$;

create or replace function public.search_sale_customers(p_company_id uuid,p_query text default null,p_page integer default 1,p_page_size integer default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1); v_size integer:=least(greatest(coalesce(p_page_size,30),1),100); v_query text:=lower(trim(coalesce(p_query,''))); v_total integer; v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'use_pos') then raise exception 'No autorizado.'; end if;
  select count(*) into v_total from public.customers c where c.company_id=p_company_id and c.is_active and public.customer_matches_query(c.id,v_query);
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'code',p.code,'display_name',p.display_name,'credit_enabled',p.credit_enabled,'price_list_id',p.price_list_id,'migration_status',p.migration_status,'alpha_external_code',p.alpha_external_code) order by p.display_name,p.id),'[]'::jsonb) into v_items
  from (select c.* from public.customers c where c.company_id=p_company_id and c.is_active and public.customer_matches_query(c.id,v_query) order by c.display_name,c.id limit v_size offset (v_page-1)*v_size) p;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size);
end $$;

create or replace function public.search_sale_customers_credit(p_company_id uuid,p_query text default null,p_page integer default 1,p_page_size integer default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1); v_size integer:=least(greatest(coalesce(p_page_size,30),1),100); v_query text:=lower(trim(coalesce(p_query,''))); v_total integer; v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_customer_credit') then raise exception 'No autorizado para consultar crédito de clientes.'; end if;
  select count(*) into v_total from public.customers c where c.company_id=p_company_id and c.is_active and public.customer_matches_query(c.id,v_query);
  with paged as (select c.*,coalesce((select sum(r.outstanding_amount) from public.customer_receivables r where r.customer_id=c.id),0) outstanding from public.customers c where c.company_id=p_company_id and c.is_active and public.customer_matches_query(c.id,v_query) order by c.display_name,c.id limit v_size offset (v_page-1)*v_size)
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'code',p.code,'display_name',p.display_name,'credit_enabled',p.credit_enabled and (p.alpha_external_code is null or p.migration_status='promoted'),'price_list_id',p.price_list_id,'credit_limit',p.credit_limit,'credit_term_days',p.credit_term_days,'outstanding_amount',p.outstanding,'available_credit',greatest(p.credit_limit-p.outstanding,0),'migration_status',p.migration_status,'alpha_external_code',p.alpha_external_code) order by p.display_name,p.id),'[]'::jsonb) into v_items from paged p;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size);
end $$;

create or replace function public.list_receivable_customers(p_company_id uuid,p_query text default null,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1); v_size integer:=least(greatest(coalesce(p_page_size,50),1),100); v_query text:=lower(trim(coalesce(p_query,''))); v_total integer; v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_customer_credit') then raise exception 'No autorizado para consultar cuentas por cobrar.'; end if;
  with balances as materialized (select customer_id,sum(outstanding_amount) outstanding from public.customer_receivables where company_id=p_company_id and outstanding_amount>0 group by customer_id)
  select count(*) into v_total from balances b join public.customers c on c.id=b.customer_id where c.company_id=p_company_id and c.is_active and public.customer_matches_query(c.id,v_query);
  with balances as materialized (select customer_id,sum(outstanding_amount) outstanding from public.customer_receivables where company_id=p_company_id and outstanding_amount>0 group by customer_id), paged as (select c.*,b.outstanding from balances b join public.customers c on c.id=b.customer_id where c.company_id=p_company_id and c.is_active and public.customer_matches_query(c.id,v_query) order by c.display_name,c.id limit v_size offset (v_page-1)*v_size)
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'code',p.code,'display_name',p.display_name,'credit_enabled',p.credit_enabled and (p.alpha_external_code is null or p.migration_status='promoted'),'price_list_id',p.price_list_id,'credit_limit',p.credit_limit,'credit_term_days',p.credit_term_days,'outstanding_amount',p.outstanding,'available_credit',greatest(p.credit_limit-p.outstanding,0),'migration_status',p.migration_status,'alpha_external_code',p.alpha_external_code) order by p.display_name,p.id),'[]'::jsonb) into v_items from paged p;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size);
end $$;

revoke all on function public.assert_customer_master_access(uuid,uuid,boolean),public.get_customer_master(uuid,uuid),public.update_customer_general(uuid,uuid,text,text),public.upsert_customer_address(uuid,uuid,uuid,text,text,text,text,text,text,boolean),public.delete_customer_address(uuid,uuid,uuid),public.upsert_customer_contact(uuid,uuid,uuid,text,text,text,text,boolean),public.delete_customer_contact(uuid,uuid,uuid),public.update_customer_commercial(uuid,uuid,uuid,text,text,boolean,numeric,integer),public.create_pos_cash_customer(uuid,uuid,text,text,text),public.customer_matches_query(uuid,text) from public;
grant execute on function public.get_customer_master(uuid,uuid),public.update_customer_general(uuid,uuid,text,text),public.upsert_customer_address(uuid,uuid,uuid,text,text,text,text,text,text,boolean),public.delete_customer_address(uuid,uuid,uuid),public.upsert_customer_contact(uuid,uuid,uuid,text,text,text,text,boolean),public.delete_customer_contact(uuid,uuid,uuid),public.update_customer_commercial(uuid,uuid,uuid,text,text,boolean,numeric,integer),public.create_pos_cash_customer(uuid,uuid,text,text,text) to authenticated;

-- Legacy columns are intentionally cleared after the one-time backfill so no reader can silently fall back to them.
update public.customers set phone=null,email=null,address_line=null,neighborhood=null,municipality=null,state_name=null,postal_code=null,contact_name=null
where phone is not null or email is not null or address_line is not null or neighborhood is not null or municipality is not null or state_name is not null or postal_code is not null or contact_name is not null;
