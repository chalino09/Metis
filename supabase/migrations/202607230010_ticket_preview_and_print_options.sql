-- Satrapy · Fase 2 POS: opciones de presentación del ticket térmico.
-- Complementa 202607230009_ticket_branding_profiles.sql, ya aplicada.

alter table public.ticket_branding_profiles
  add column if not exists document_title text not null default 'TICKET DE VENTA',
  add column if not exists header_message text,
  add column if not exists website text,
  add column if not exists return_policy text,
  add column if not exists paper_width text not null default '80mm',
  add column if not exists show_customer boolean not null default true,
  add column if not exists show_product_code boolean not null default false,
  add column if not exists show_payment_details boolean not null default true,
  add column if not exists show_tax_id boolean not null default false;

alter table public.ticket_branding_profiles drop constraint if exists ticket_branding_profiles_paper_width_check;
alter table public.ticket_branding_profiles add constraint ticket_branding_profiles_paper_width_check check (paper_width in ('58mm', '80mm'));
alter table public.ticket_branding_profiles drop constraint if exists ticket_branding_profiles_document_title_check;
alter table public.ticket_branding_profiles add constraint ticket_branding_profiles_document_title_check check (char_length(trim(document_title)) between 1 and 60);

create or replace function public.get_ticket_branding(p_company_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company public.companies%rowtype;
  v_profile public.ticket_branding_profiles%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_sales') then
    raise exception 'No autorizado para consultar el ticket.';
  end if;
  select * into v_company from public.companies where id = p_company_id;
  if not found then raise exception 'Empresa no disponible.'; end if;
  select * into v_profile from public.ticket_branding_profiles where company_id = p_company_id;
  return jsonb_build_object(
    'display_name', coalesce(v_profile.display_name, v_company.display_name),
    'legal_name', v_company.legal_name,
    'tax_id', v_company.tax_id,
    'contact_line', v_profile.contact_line,
    'document_title', coalesce(v_profile.document_title, 'TICKET DE VENTA'),
    'header_message', v_profile.header_message,
    'website', v_profile.website,
    'return_policy', v_profile.return_policy,
    'footer_message', coalesce(v_profile.footer_message, 'Gracias por su compra'),
    'paper_width', coalesce(v_profile.paper_width, '80mm'),
    'show_customer', coalesce(v_profile.show_customer, true),
    'show_product_code', coalesce(v_profile.show_product_code, false),
    'show_payment_details', coalesce(v_profile.show_payment_details, true),
    'show_tax_id', coalesce(v_profile.show_tax_id, false),
    'logo_path', v_profile.logo_path
  );
end;
$$;

create or replace function public.update_ticket_branding(
  p_company_id uuid,
  p_display_name text,
  p_contact_line text default null,
  p_footer_message text default null,
  p_logo_path text default null,
  p_document_title text default 'TICKET DE VENTA',
  p_header_message text default null,
  p_website text default null,
  p_return_policy text default null,
  p_paper_width text default '80mm',
  p_show_customer boolean default true,
  p_show_product_code boolean default false,
  p_show_payment_details boolean default true,
  p_show_tax_id boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_profile public.ticket_branding_profiles%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_ticket_branding') then
    raise exception 'No autorizado para configurar el ticket.';
  end if;
  if nullif(trim(coalesce(p_display_name, '')), '') is null then raise exception 'El nombre visible es obligatorio.'; end if;
  if nullif(trim(coalesce(p_document_title, '')), '') is null then raise exception 'El título del documento es obligatorio.'; end if;
  if nullif(trim(coalesce(p_footer_message, '')), '') is null then raise exception 'El mensaje final es obligatorio.'; end if;
  if p_paper_width not in ('58mm', '80mm') then raise exception 'El ancho de papel no es válido.'; end if;
  if p_logo_path is not null and p_logo_path <> '' and p_logo_path !~ ('^' || p_company_id::text || '/') then raise exception 'El logotipo no pertenece a esta empresa.'; end if;

  select to_jsonb(ticket_branding_profiles.*) into v_before from public.ticket_branding_profiles where company_id = p_company_id;
  insert into public.ticket_branding_profiles(
    company_id, display_name, contact_line, footer_message, logo_path, document_title,
    header_message, website, return_policy, paper_width, show_customer,
    show_product_code, show_payment_details, show_tax_id, updated_by
  ) values (
    p_company_id, trim(p_display_name), nullif(trim(p_contact_line), ''), trim(p_footer_message), nullif(trim(p_logo_path), ''), trim(p_document_title),
    nullif(trim(p_header_message), ''), nullif(trim(p_website), ''), nullif(trim(p_return_policy), ''), p_paper_width, coalesce(p_show_customer, true),
    coalesce(p_show_product_code, false), coalesce(p_show_payment_details, true), coalesce(p_show_tax_id, false), auth.uid()
  ) on conflict (company_id) do update set
    display_name = excluded.display_name,
    contact_line = excluded.contact_line,
    footer_message = excluded.footer_message,
    logo_path = excluded.logo_path,
    document_title = excluded.document_title,
    header_message = excluded.header_message,
    website = excluded.website,
    return_policy = excluded.return_policy,
    paper_width = excluded.paper_width,
    show_customer = excluded.show_customer,
    show_product_code = excluded.show_product_code,
    show_payment_details = excluded.show_payment_details,
    show_tax_id = excluded.show_tax_id,
    updated_at = now(),
    updated_by = auth.uid()
  returning * into v_profile;

  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values (p_company_id, auth.uid(), 'ticket_branding.updated', 'ticket_branding_profile', p_company_id, jsonb_build_object('before', v_before, 'current', to_jsonb(v_profile)));
  return public.get_ticket_branding(p_company_id);
end;
$$;

grant execute on function public.update_ticket_branding(uuid, text, text, text, text, text, text, text, text, text, boolean, boolean, boolean, boolean) to authenticated;
