-- Satrapy · Fase 2: alta rápida, presentación y documento de cotizaciones.
-- No crea ventas, no reserva existencias y no modifica los precios vigentes.

begin;

insert into public.permissions(code, description)
values ('manage_quote_branding', 'Configurar la presentación imprimible de cotizaciones.')
on conflict (code) do update set description = excluded.description;

insert into public.role_permissions(role_id, permission_id)
select role_data.id, permission_data.id
from public.roles role_data
join public.permissions permission_data on permission_data.code = 'manage_quote_branding'
where role_data.code in ('super_admin', 'direccion_admin')
on conflict do nothing;

create table if not exists public.quote_branding_profiles (
  company_id uuid primary key references public.companies(id) on delete cascade,
  display_name text not null check (char_length(trim(display_name)) between 1 and 120),
  document_title text not null default 'COTIZACIÓN' check (char_length(trim(document_title)) between 1 and 60),
  contact_line text,
  header_message text,
  footer_message text not null default 'Gracias por considerar nuestra propuesta.' check (char_length(trim(footer_message)) between 1 and 180),
  terms_and_conditions text,
  website text,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

alter table public.quote_branding_profiles enable row level security;
drop policy if exists quote_branding_profiles_read on public.quote_branding_profiles;
create policy quote_branding_profiles_read on public.quote_branding_profiles
  for select to authenticated
  using (public.has_company_permission(company_id, 'view_sales_quotes'));

create table if not exists public.sales_quote_document_snapshots (
  quote_id uuid primary key references public.sales_quotes(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  branding jsonb not null,
  generated_at timestamptz not null default now(),
  generated_by uuid references auth.users(id) on delete set null
);
create index if not exists sales_quote_document_snapshots_company_idx on public.sales_quote_document_snapshots(company_id);
alter table public.sales_quote_document_snapshots enable row level security;
drop policy if exists sales_quote_document_snapshots_read on public.sales_quote_document_snapshots;
create policy sales_quote_document_snapshots_read on public.sales_quote_document_snapshots
  for select to authenticated
  using (public.has_company_permission(company_id, 'view_sales_quotes'));

create or replace function public.create_sales_quote_customer(
  p_company_id uuid,
  p_location_id uuid,
  p_display_name text,
  p_tax_id text default null,
  p_phone text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
  v_code text;
  v_price_list_id uuid;
begin
  if auth.uid() is null
    or not public.has_company_permission(p_company_id, 'manage_sales_quotes')
    or not public.has_company_permission(p_company_id, 'manage_customers')
    or not public.can_access_location(p_location_id) then
    raise exception 'No autorizado para crear clientes desde cotizaciones.';
  end if;
  if not exists (
    select 1 from public.locations
    where id = p_location_id and company_id = p_company_id and is_active
  ) then
    raise exception 'Sucursal no disponible.';
  end if;
  if nullif(trim(coalesce(p_display_name, '')), '') is null then
    raise exception 'El nombre es obligatorio.';
  end if;
  if nullif(trim(coalesce(p_tax_id, '')), '') is not null and exists (
    select 1 from public.customers
    where company_id = p_company_id and lower(tax_id) = lower(trim(p_tax_id))
  ) then
    raise exception 'Ya existe un cliente con ese RFC.';
  end if;

  select coalesce(location_data.default_price_list_id, company_data.default_price_list_id)
    into v_price_list_id
  from public.locations location_data
  join public.companies company_data on company_data.id = location_data.company_id
  where location_data.id = p_location_id and location_data.company_id = p_company_id;

  v_code := 'CLI-' || upper(substr(gen_random_uuid()::text, 1, 8));
  insert into public.customers(
    company_id, code, display_name, tax_id, price_list_id,
    credit_enabled, credit_limit, credit_term_days, created_by
  ) values (
    p_company_id, v_code, trim(p_display_name), nullif(upper(trim(p_tax_id)), ''),
    v_price_list_id, false, 0, 0, auth.uid()
  ) returning id into v_customer_id;

  if nullif(trim(coalesce(p_phone, '')), '') is not null then
    insert into public.customer_contacts(
      company_id, customer_id, display_name, role_name, phone, is_primary
    ) values (
      p_company_id, v_customer_id, trim(p_display_name), 'Contacto principal',
      trim(p_phone), true
    );
  end if;

  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values (
    p_company_id, auth.uid(), 'customer.quote_quick_created', 'customers', v_customer_id,
    jsonb_build_object('location_id', p_location_id, 'price_list_id', v_price_list_id, 'credit_enabled', false)
  );
  return jsonb_build_object('id', v_customer_id, 'code', v_code, 'display_name', trim(p_display_name));
end;
$$;

create or replace function public.get_quote_branding(p_company_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company public.companies%rowtype;
  v_quote_profile public.quote_branding_profiles%rowtype;
  v_ticket_profile public.ticket_branding_profiles%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_sales_quotes') then
    raise exception 'No autorizado para consultar el formato de cotización.';
  end if;
  select * into v_company from public.companies where id = p_company_id;
  if not found then raise exception 'Empresa no disponible.'; end if;
  select * into v_quote_profile from public.quote_branding_profiles where company_id = p_company_id;
  select * into v_ticket_profile from public.ticket_branding_profiles where company_id = p_company_id;
  return jsonb_build_object(
    'display_name', coalesce(v_quote_profile.display_name, v_ticket_profile.display_name, v_company.display_name),
    'legal_name', v_company.legal_name,
    'tax_id', v_company.tax_id,
    'document_title', coalesce(v_quote_profile.document_title, 'COTIZACIÓN'),
    'contact_line', coalesce(v_quote_profile.contact_line, v_ticket_profile.contact_line),
    'header_message', v_quote_profile.header_message,
    'footer_message', coalesce(v_quote_profile.footer_message, 'Gracias por considerar nuestra propuesta.'),
    'terms_and_conditions', v_quote_profile.terms_and_conditions,
    'website', v_quote_profile.website,
    'logo_path', v_ticket_profile.logo_path
  );
end;
$$;

create or replace function public.update_quote_branding(
  p_company_id uuid,
  p_display_name text,
  p_document_title text default 'COTIZACIÓN',
  p_contact_line text default null,
  p_header_message text default null,
  p_footer_message text default null,
  p_terms_and_conditions text default null,
  p_website text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_profile public.quote_branding_profiles%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_quote_branding') then
    raise exception 'No autorizado para configurar cotizaciones.';
  end if;
  if nullif(trim(coalesce(p_display_name, '')), '') is null then raise exception 'El nombre visible es obligatorio.'; end if;
  if nullif(trim(coalesce(p_document_title, '')), '') is null then raise exception 'El título del documento es obligatorio.'; end if;
  if nullif(trim(coalesce(p_footer_message, '')), '') is null then raise exception 'El mensaje final es obligatorio.'; end if;

  select to_jsonb(profile_data.*) into v_before
  from public.quote_branding_profiles profile_data where profile_data.company_id = p_company_id;
  insert into public.quote_branding_profiles(
    company_id, display_name, document_title, contact_line, header_message,
    footer_message, terms_and_conditions, website, updated_by
  ) values (
    p_company_id, trim(p_display_name), trim(p_document_title), nullif(trim(p_contact_line), ''),
    nullif(trim(p_header_message), ''), trim(p_footer_message),
    nullif(trim(p_terms_and_conditions), ''), nullif(trim(p_website), ''), auth.uid()
  ) on conflict (company_id) do update set
    display_name = excluded.display_name,
    document_title = excluded.document_title,
    contact_line = excluded.contact_line,
    header_message = excluded.header_message,
    footer_message = excluded.footer_message,
    terms_and_conditions = excluded.terms_and_conditions,
    website = excluded.website,
    updated_at = now(),
    updated_by = auth.uid()
  returning * into v_profile;

  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values (p_company_id, auth.uid(), 'quote_branding.updated', 'quote_branding_profile', p_company_id, jsonb_build_object('before', v_before, 'current', to_jsonb(v_profile)));
  return public.get_quote_branding(p_company_id);
end;
$$;

create or replace function public.get_sales_quote_document(p_company_id uuid, p_quote_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_branding jsonb;
  v_quote jsonb;
begin
  v_quote := public.get_sales_quote_detail(p_company_id, p_quote_id);
  select branding into v_branding
  from public.sales_quote_document_snapshots
  where quote_id = p_quote_id and company_id = p_company_id;
  if v_branding is null then
    v_branding := public.get_quote_branding(p_company_id);
    insert into public.sales_quote_document_snapshots(quote_id, company_id, branding, generated_by)
    values (p_quote_id, p_company_id, v_branding, auth.uid());
    insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
    values (p_company_id, auth.uid(), 'sales_quote.document_prepared', 'sales_quote', p_quote_id, jsonb_build_object('format', 'pdf_a4'));
  end if;
  return jsonb_build_object('quote', v_quote, 'branding', v_branding);
end;
$$;

grant select on public.quote_branding_profiles, public.sales_quote_document_snapshots to authenticated;
grant execute on function public.create_sales_quote_customer(uuid, uuid, text, text, text) to authenticated;
grant execute on function public.get_quote_branding(uuid) to authenticated;
grant execute on function public.update_quote_branding(uuid, text, text, text, text, text, text, text) to authenticated;
grant execute on function public.get_sales_quote_document(uuid, uuid) to authenticated;

commit;
