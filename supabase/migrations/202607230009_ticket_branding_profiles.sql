-- Satrapy · Fase 2 POS: datos visibles en tickets de venta.
-- La configuración se administra por empresa y no modifica ventas ni tickets ya emitidos.

insert into public.permissions(code, description)
values ('manage_ticket_branding', 'Configurar los datos y logotipo visibles en tickets de venta.')
on conflict (code) do update set description = excluded.description;

insert into public.role_permissions(role_id, permission_id)
select role_data.id, permission_data.id
from public.roles role_data
join public.permissions permission_data on permission_data.code = 'manage_ticket_branding'
where role_data.code in ('super_admin', 'direccion_admin')
on conflict do nothing;

create table if not exists public.ticket_branding_profiles (
  company_id uuid primary key references public.companies(id) on delete cascade,
  display_name text not null check (char_length(trim(display_name)) between 1 and 120),
  contact_line text,
  footer_message text not null default 'Gracias por su compra' check (char_length(trim(footer_message)) between 1 and 180),
  logo_path text,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

alter table public.ticket_branding_profiles enable row level security;

create policy ticket_branding_profiles_read on public.ticket_branding_profiles
  for select to authenticated
  using (public.has_company_permission(company_id, 'view_sales'));

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
    'contact_line', v_profile.contact_line,
    'footer_message', coalesce(v_profile.footer_message, 'Gracias por su compra'),
    'logo_path', v_profile.logo_path
  );
end;
$$;

create or replace function public.update_ticket_branding(
  p_company_id uuid,
  p_display_name text,
  p_contact_line text default null,
  p_footer_message text default null,
  p_logo_path text default null
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
  if nullif(trim(coalesce(p_display_name, '')), '') is null then
    raise exception 'El nombre visible es obligatorio.';
  end if;
  if nullif(trim(coalesce(p_footer_message, '')), '') is null then
    raise exception 'El mensaje final es obligatorio.';
  end if;
  if p_logo_path is not null and p_logo_path <> '' and p_logo_path !~ ('^' || p_company_id::text || '/') then
    raise exception 'El logotipo no pertenece a esta empresa.';
  end if;
  select to_jsonb(ticket_branding_profiles.*) into v_before from public.ticket_branding_profiles where company_id = p_company_id;
  insert into public.ticket_branding_profiles(company_id, display_name, contact_line, footer_message, logo_path, updated_by)
  values (p_company_id, trim(p_display_name), nullif(trim(p_contact_line), ''), trim(p_footer_message), nullif(trim(p_logo_path), ''), auth.uid())
  on conflict (company_id) do update set
    display_name = excluded.display_name,
    contact_line = excluded.contact_line,
    footer_message = excluded.footer_message,
    logo_path = excluded.logo_path,
    updated_at = now(),
    updated_by = auth.uid()
  returning * into v_profile;
  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values (p_company_id, auth.uid(), 'ticket_branding.updated', 'ticket_branding_profile', p_company_id, jsonb_build_object('before', v_before, 'current', to_jsonb(v_profile)));
  return jsonb_build_object('display_name', v_profile.display_name, 'contact_line', v_profile.contact_line, 'footer_message', v_profile.footer_message, 'logo_path', v_profile.logo_path);
end;
$$;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('ticket-branding-assets', 'ticket-branding-assets', true, 2097152, array['image/png', 'image/jpeg'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create policy ticket_branding_assets_read on storage.objects for select to authenticated
  using (bucket_id = 'ticket-branding-assets' and public.has_company_access((storage.foldername(name))[1]::uuid));
create policy ticket_branding_assets_write on storage.objects for insert to authenticated
  with check (bucket_id = 'ticket-branding-assets' and public.has_company_permission((storage.foldername(name))[1]::uuid, 'manage_ticket_branding'));
create policy ticket_branding_assets_update on storage.objects for update to authenticated
  using (bucket_id = 'ticket-branding-assets' and public.has_company_permission((storage.foldername(name))[1]::uuid, 'manage_ticket_branding'))
  with check (bucket_id = 'ticket-branding-assets' and public.has_company_permission((storage.foldername(name))[1]::uuid, 'manage_ticket_branding'));
create policy ticket_branding_assets_delete on storage.objects for delete to authenticated
  using (bucket_id = 'ticket-branding-assets' and public.has_company_permission((storage.foldername(name))[1]::uuid, 'manage_ticket_branding'));

grant select on public.ticket_branding_profiles to authenticated;
grant execute on function public.get_ticket_branding(uuid) to authenticated;
grant execute on function public.update_ticket_branding(uuid, text, text, text, text) to authenticated;
