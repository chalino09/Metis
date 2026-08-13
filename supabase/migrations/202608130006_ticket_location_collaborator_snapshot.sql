-- Tickets v2: conserva identidad empresarial y contexto operativo de la venta.
-- Los perfiles de impresión siguen siendo empresariales; sucursal, caja y colaborador
-- se resuelven automáticamente y quedan congelados en el ticket canónico.

begin;

alter table public.location_operating_profiles
  add column if not exists contact_phone text;

alter table public.location_operating_profiles
  drop constraint if exists location_operating_profiles_contact_phone_check;
alter table public.location_operating_profiles
  add constraint location_operating_profiles_contact_phone_check
  check (contact_phone is null or contact_phone ~ '^[0-9+() .-]{7,30}$');

create or replace function public.save_company_location_operating_model(
  p_company_id uuid,p_location_id uuid,p_external_code text,p_name text,p_location_type text,p_is_active boolean,
  p_address_line_1 text,p_address_line_2 text,p_neighborhood text,p_municipality text,p_state_name text,p_postal_code text,p_country_code text,
  p_contact_phone text,p_latitude numeric,p_longitude numeric,p_sales_floor_sqm numeric,p_storage_sqm numeric,p_storage_capacity_units numeric,
  p_cost_center_code text,p_opened_on date,p_closed_on date,p_monthly_base_rent numeric,p_monthly_services_budget numeric,
  p_initial_investment numeric,p_economic_effective_from date,p_currency_code text,p_reason text,p_expected_updated_at timestamptz,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_result jsonb;v_location_id uuid;
begin
  v_result:=public.save_company_location_operating_model(
    p_company_id,p_location_id,p_external_code,p_name,p_location_type,p_is_active,
    p_address_line_1,p_address_line_2,p_neighborhood,p_municipality,p_state_name,p_postal_code,p_country_code,
    p_latitude,p_longitude,p_sales_floor_sqm,p_storage_sqm,p_storage_capacity_units,p_cost_center_code,p_opened_on,p_closed_on,
    p_monthly_base_rent,p_monthly_services_budget,p_initial_investment,p_economic_effective_from,p_currency_code,p_reason,
    p_expected_updated_at,p_client_request_id
  );
  v_location_id:=(v_result->>'id')::uuid;
  update public.location_operating_profiles
  set contact_phone=nullif(trim(p_contact_phone),''),updated_by=auth.uid()
  where location_id=v_location_id and company_id=p_company_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'location.ticket_contact_updated','location',v_location_id,
    jsonb_build_object('has_contact_phone',nullif(trim(p_contact_phone),'') is not null,'request_id',p_client_request_id));
  return public.get_location_operating_workspace(p_company_id,v_location_id);
end $$;

revoke all on function public.save_company_location_operating_model(uuid,uuid,text,text,text,boolean,text,text,text,text,text,text,text,text,numeric,numeric,numeric,numeric,numeric,text,date,date,numeric,numeric,numeric,date,text,text,timestamptz,uuid) from public,anon;
grant execute on function public.save_company_location_operating_model(uuid,uuid,text,text,text,boolean,text,text,text,text,text,text,text,text,numeric,numeric,numeric,numeric,numeric,text,date,date,numeric,numeric,numeric,date,text,text,timestamptz,uuid) to authenticated;

create or replace function public.ticket_operational_snapshot(p_company_id uuid,p_location_id uuid,p_sale_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_result jsonb;
begin
  select jsonb_build_object(
    'company',jsonb_build_object(
      'id',company_data.id,'display_name',coalesce(branding.display_name,company_data.display_name),
      'legal_name',company_data.legal_name,'tax_id',company_data.tax_id,
      'logo_path',branding.logo_path
    ),
    'location',jsonb_build_object(
      'id',location_data.id,'code',location_data.external_code,'name',location_data.name,
      'address',nullif(concat_ws(', ',profile.address_line_1,profile.address_line_2,profile.neighborhood,profile.municipality,profile.state_name,profile.postal_code),''),
      'contact_phone',profile.contact_phone
    ),
    'register',case when register_data.id is null then null else jsonb_build_object('id',register_data.id,'code',register_data.code,'name',register_data.display_name) end,
    'collaborator',jsonb_build_object(
      'user_id',sale_data.cashier_id,'id',collaborator.id,
      'code',collaborator.code,'display_name',coalesce(collaborator.display_name,user_profile.full_name,'Usuario')
    )
  ) into v_result
  from public.companies company_data
  join public.locations location_data on location_data.id=p_location_id and location_data.company_id=company_data.id
  join public.sales sale_data on sale_data.id=p_sale_id and sale_data.company_id=company_data.id and sale_data.location_id=location_data.id
  left join public.ticket_branding_profiles branding on branding.company_id=company_data.id
  left join public.location_operating_profiles profile on profile.location_id=location_data.id
  left join public.cash_registers register_data on register_data.id=sale_data.cash_register_id
  left join public.profiles user_profile on user_profile.id=sale_data.cashier_id
  left join lateral(
    select collaborator_data.id,collaborator_data.code,collaborator_data.display_name
    from public.collaborator_user_links link
    join public.collaborators collaborator_data on collaborator_data.id=link.collaborator_id and collaborator_data.company_id=link.company_id
    where link.company_id=p_company_id and link.user_id=sale_data.cashier_id
      and current_date between link.effective_from and coalesce(link.effective_to,'infinity'::date)
    order by link.effective_from desc,link.id desc limit 1
  ) collaborator on true
  where company_data.id=p_company_id;
  return coalesce(v_result,'{}'::jsonb);
end $$;

create or replace function public.snapshot_canonical_ticket_context()
returns trigger language plpgsql security definer set search_path=public,extensions as $$
declare v_snapshot jsonb;
begin
  -- Los documentos importados conservan exclusivamente la evidencia de origen.
  if exists(select 1 from public.sales sale_data where sale_data.id=new.sale_id and to_jsonb(sale_data)->>'source_kind'='alpha_historical') then
    return new;
  end if;
  v_snapshot:=public.ticket_operational_snapshot(new.company_id,new.location_id,new.sale_id);
  new.schema_version:=2;
  new.payload:=new.payload||jsonb_build_object('schema_version',2,'identity',v_snapshot);
  new.content_sha256:=encode(digest(new.payload::text,'sha256'),'hex');
  return new;
end $$;

drop trigger if exists canonical_tickets_snapshot_context on public.canonical_tickets;
create trigger canonical_tickets_snapshot_context
before insert on public.canonical_tickets
for each row execute function public.snapshot_canonical_ticket_context();

create or replace function public.get_ticket_location_preview(p_company_id uuid,p_location_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_ticket_branding')
    or not public.can_access_location(p_location_id) then raise exception 'Sucursal no disponible.';end if;
  select jsonb_build_object(
    'id',l.id,'code',l.external_code,'name',l.name,
    'address',nullif(concat_ws(', ',p.address_line_1,p.address_line_2,p.neighborhood,p.municipality,p.state_name,p.postal_code),''),
    'contact_phone',p.contact_phone
  ) into v_result from public.locations l left join public.location_operating_profiles p on p.location_id=l.id
  where l.id=p_location_id and l.company_id=p_company_id and l.is_active;
  if v_result is null then raise exception 'Sucursal no disponible.';end if;
  return v_result;
end $$;

revoke all on function public.ticket_operational_snapshot(uuid,uuid,uuid),public.get_ticket_location_preview(uuid,uuid) from public,anon;
grant execute on function public.get_ticket_location_preview(uuid,uuid) to authenticated;

commit;

notify pgrst,'reload schema';
