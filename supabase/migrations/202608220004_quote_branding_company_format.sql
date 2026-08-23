-- Satrapy - Formato de cotizacion independiente por empresa.
-- La configuracion se congela en el snapshot al aprobar el documento.
begin;
alter table public.quote_branding_profiles add column if not exists legal_name text, add column if not exists tax_id text, add column if not exists fiscal_address text, add column if not exists accent_color text not null default '#176F5E', add column if not exists logo_path text;
alter table public.quote_branding_profiles drop constraint if exists quote_branding_profiles_accent_color_check;
alter table public.quote_branding_profiles add constraint quote_branding_profiles_accent_color_check check (accent_color ~ '^#[0-9A-F]{6}$');

create or replace function public.get_quote_branding(p_company_id uuid) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_company public.companies%rowtype; v_quote_profile public.quote_branding_profiles%rowtype; v_ticket_profile public.ticket_branding_profiles%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_sales_quotes') then raise exception 'No autorizado para consultar el formato de cotizacion.'; end if;
  select * into v_company from public.companies where id=p_company_id; if not found then raise exception 'Empresa no disponible.'; end if;
  select * into v_quote_profile from public.quote_branding_profiles where company_id=p_company_id;
  select * into v_ticket_profile from public.ticket_branding_profiles where company_id=p_company_id;
  return jsonb_build_object('display_name',coalesce(v_quote_profile.display_name,v_ticket_profile.display_name,v_company.display_name),'legal_name',coalesce(v_quote_profile.legal_name,v_company.legal_name),'tax_id',coalesce(v_quote_profile.tax_id,v_company.tax_id),'fiscal_address',v_quote_profile.fiscal_address,'document_title',coalesce(v_quote_profile.document_title,'COTIZACION'),'contact_line',coalesce(v_quote_profile.contact_line,v_ticket_profile.contact_line),'header_message',v_quote_profile.header_message,'footer_message',coalesce(v_quote_profile.footer_message,'Gracias por considerar nuestra propuesta.'),'terms_and_conditions',v_quote_profile.terms_and_conditions,'website',v_quote_profile.website,'accent_color',coalesce(v_quote_profile.accent_color,'#176F5E'),'logo_path',coalesce(v_quote_profile.logo_path,v_ticket_profile.logo_path));
end $$;

drop function if exists public.update_quote_branding(uuid,text,text,text,text,text,text,text);
create or replace function public.update_quote_branding(p_company_id uuid,p_display_name text,p_document_title text default 'COTIZACION',p_contact_line text default null,p_header_message text default null,p_footer_message text default null,p_terms_and_conditions text default null,p_website text default null,p_legal_name text default null,p_tax_id text default null,p_fiscal_address text default null,p_accent_color text default '#176F5E',p_logo_path text default null) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_before jsonb; v_profile public.quote_branding_profiles%rowtype; v_accent text:=upper(trim(coalesce(p_accent_color,'')));
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_quote_branding') then raise exception 'No autorizado para configurar cotizaciones.'; end if;
  if nullif(trim(coalesce(p_display_name,'')),'') is null then raise exception 'El nombre visible es obligatorio.'; end if;
  if nullif(trim(coalesce(p_document_title,'')),'') is null then raise exception 'El titulo del documento es obligatorio.'; end if;
  if nullif(trim(coalesce(p_footer_message,'')),'') is null then raise exception 'El mensaje final es obligatorio.'; end if;
  if v_accent !~ '^#[0-9A-F]{6}$' then raise exception 'Selecciona un color valido.'; end if;
  if p_logo_path is not null and p_logo_path<>'' and p_logo_path !~ ('^'||p_company_id::text||'/') then raise exception 'El logotipo no pertenece a esta empresa.'; end if;
  select to_jsonb(profile_data.*) into v_before from public.quote_branding_profiles profile_data where profile_data.company_id=p_company_id;
  insert into public.quote_branding_profiles(company_id,display_name,legal_name,tax_id,fiscal_address,document_title,contact_line,header_message,footer_message,terms_and_conditions,website,accent_color,logo_path,updated_by) values(p_company_id,trim(p_display_name),nullif(trim(p_legal_name),''),nullif(upper(trim(p_tax_id)),''),nullif(trim(p_fiscal_address),''),trim(p_document_title),nullif(trim(p_contact_line),''),nullif(trim(p_header_message),''),trim(p_footer_message),nullif(trim(p_terms_and_conditions),''),nullif(trim(p_website),''),v_accent,nullif(trim(p_logo_path),''),auth.uid()) on conflict(company_id) do update set display_name=excluded.display_name,legal_name=excluded.legal_name,tax_id=excluded.tax_id,fiscal_address=excluded.fiscal_address,document_title=excluded.document_title,contact_line=excluded.contact_line,header_message=excluded.header_message,footer_message=excluded.footer_message,terms_and_conditions=excluded.terms_and_conditions,website=excluded.website,accent_color=excluded.accent_color,logo_path=excluded.logo_path,updated_at=now(),updated_by=auth.uid() returning * into v_profile;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'quote_branding.updated','quote_branding_profile',p_company_id,jsonb_build_object('before',v_before,'current',to_jsonb(v_profile)));
  return public.get_quote_branding(p_company_id);
end $$;

do $storage$
begin
  if to_regclass('storage.objects') is not null then
    execute 'drop policy if exists ticket_branding_assets_write on storage.objects';
    execute 'drop policy if exists ticket_branding_assets_insert on storage.objects';
    execute $policy$create policy ticket_branding_assets_write on storage.objects for insert to authenticated with check(bucket_id='ticket-branding-assets' and (public.has_company_permission((storage.foldername(name))[1]::uuid,'manage_ticket_branding') or public.has_company_permission((storage.foldername(name))[1]::uuid,'manage_quote_branding')))$policy$;
    execute 'drop policy if exists ticket_branding_assets_update on storage.objects';
    execute $policy$create policy ticket_branding_assets_update on storage.objects for update to authenticated using(bucket_id='ticket-branding-assets' and (public.has_company_permission((storage.foldername(name))[1]::uuid,'manage_ticket_branding') or public.has_company_permission((storage.foldername(name))[1]::uuid,'manage_quote_branding'))) with check(bucket_id='ticket-branding-assets' and (public.has_company_permission((storage.foldername(name))[1]::uuid,'manage_ticket_branding') or public.has_company_permission((storage.foldername(name))[1]::uuid,'manage_quote_branding')))$policy$;
    execute 'drop policy if exists ticket_branding_assets_delete on storage.objects';
    execute $policy$create policy ticket_branding_assets_delete on storage.objects for delete to authenticated using(bucket_id='ticket-branding-assets' and (public.has_company_permission((storage.foldername(name))[1]::uuid,'manage_ticket_branding') or public.has_company_permission((storage.foldername(name))[1]::uuid,'manage_quote_branding')))$policy$;
  end if;
end $storage$;
revoke all on function public.update_quote_branding(uuid,text,text,text,text,text,text,text,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.update_quote_branding(uuid,text,text,text,text,text,text,text,text,text,text,text,text) to authenticated;
commit;
