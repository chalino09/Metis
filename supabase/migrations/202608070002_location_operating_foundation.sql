-- Base operativa para escalar sucursales: maestro físico, responsables vigentes
-- y rentabilidad por ubicación a partir de hechos canónicos existentes.

begin;

insert into public.permissions(code,description) values
  ('manage_location_operating_profiles','Configurar domicilio, capacidad y vigencia operativa de las sucursales.'),
  ('manage_location_responsibilities','Asignar responsables vigentes por sucursal.'),
  ('view_location_profitability','Consultar rentabilidad y punto de equilibrio por sucursal.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in('super_admin','direccion_admin')
  and p.code in('manage_location_operating_profiles','manage_location_responsibilities','view_location_profitability')
on conflict do nothing;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code='supervisor_sucursal' and p.code='view_location_profitability'
on conflict do nothing;

create table public.location_operating_profiles(
  location_id uuid primary key references public.locations(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  address_line_1 text,
  address_line_2 text,
  neighborhood text,
  municipality text,
  state_name text,
  postal_code text,
  country_code text not null default 'MX' check(country_code ~ '^[A-Z]{2}$'),
  latitude numeric(9,6) check(latitude between -90 and 90),
  longitude numeric(9,6) check(longitude between -180 and 180),
  sales_floor_sqm numeric(12,2) check(sales_floor_sqm is null or sales_floor_sqm>0),
  storage_sqm numeric(12,2) check(storage_sqm is null or storage_sqm>=0),
  storage_capacity_units numeric(18,6) check(storage_capacity_units is null or storage_capacity_units>=0),
  cost_center_code text,
  opened_on date,
  closed_on date,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,cost_center_code),
  check(closed_on is null or opened_on is not null),
  check(closed_on is null or closed_on>=opened_on)
);
create index location_operating_profiles_company_idx on public.location_operating_profiles(company_id,municipality,state_name,location_id);
create trigger location_operating_profiles_updated_at before update on public.location_operating_profiles
for each row execute function public.set_updated_at();

create table public.location_economic_terms(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete restrict,
  effective_from date not null,
  effective_to date,
  currency_code text not null check(currency_code ~ '^[A-Z]{3}$'),
  monthly_base_rent numeric(18,2) not null default 0 check(monthly_base_rent>=0),
  monthly_services_budget numeric(18,2) not null default 0 check(monthly_services_budget>=0),
  initial_investment numeric(18,2) not null default 0 check(initial_investment>=0),
  reason text not null check(nullif(trim(reason),'') is not null),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(effective_to is null or effective_to>=effective_from),
  exclude using gist(location_id with =,daterange(effective_from,coalesce(effective_to,'infinity'::date),'[]') with &&)
);
create index location_economic_terms_current_idx on public.location_economic_terms(company_id,location_id,effective_from desc);
create trigger location_economic_terms_updated_at before update on public.location_economic_terms
for each row execute function public.set_updated_at();

create table public.location_responsibility_assignments(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete restrict,
  collaborator_id uuid not null references public.collaborators(id) on delete restrict,
  responsibility_type text not null check(responsibility_type in('branch_manager','inventory_owner','financial_owner')),
  effective_from date not null,
  effective_to date,
  reason text not null check(nullif(trim(reason),'') is not null),
  assigned_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  check(effective_to is null or effective_to>=effective_from),
  exclude using gist(location_id with =,responsibility_type with =,daterange(effective_from,coalesce(effective_to,'infinity'::date),'[]') with &&)
);
create index location_responsibilities_lookup_idx
  on public.location_responsibility_assignments(company_id,location_id,responsibility_type,effective_from desc);

create or replace function public.assert_location_operating_company_integrity()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_company uuid;
begin
  select company_id into v_company from public.locations where id=new.location_id;
  if v_company is distinct from new.company_id then raise exception 'La ubicación no pertenece a la empresa.';end if;
  if tg_table_name='location_responsibility_assignments' then
    if not exists(select 1 from public.collaborators c where c.id=new.collaborator_id and c.company_id=new.company_id) then
      raise exception 'El responsable no pertenece a la empresa.';
    end if;
  end if;
  return new;
end $$;
create trigger location_operating_profiles_company_guard before insert or update of company_id,location_id on public.location_operating_profiles
for each row execute function public.assert_location_operating_company_integrity();
create trigger location_economic_terms_company_guard before insert or update of company_id,location_id on public.location_economic_terms
for each row execute function public.assert_location_operating_company_integrity();
create trigger location_responsibilities_company_guard before insert or update of company_id,location_id,collaborator_id on public.location_responsibility_assignments
for each row execute function public.assert_location_operating_company_integrity();

alter table public.location_operating_profiles enable row level security;
alter table public.location_economic_terms enable row level security;
alter table public.location_responsibility_assignments enable row level security;
create policy location_operating_profiles_read on public.location_operating_profiles for select to authenticated
using(public.has_company_access(company_id) and public.can_access_location(location_id));
create policy location_economic_terms_read on public.location_economic_terms for select to authenticated
using(public.has_company_permission(company_id,'view_location_profitability') and public.can_access_location(location_id));
create policy location_responsibilities_read on public.location_responsibility_assignments for select to authenticated
using(public.has_company_access(company_id) and public.can_access_location(location_id));
revoke all on public.location_operating_profiles,public.location_economic_terms,public.location_responsibility_assignments from public,anon,authenticated;
grant select on public.location_operating_profiles,public.location_economic_terms,public.location_responsibility_assignments to authenticated;

create or replace function public.get_location_operating_workspace(p_company_id uuid,p_location_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_access(p_company_id) or not public.can_access_location(p_location_id) then raise exception 'Sucursal no disponible.';end if;
  select to_jsonb(l)||jsonb_build_object(
    'inventory_quantity',coalesce(b.quantity,0),
    'open_cash_sessions',coalesce(cs.sessions,0),
    'active_counts',coalesce(ic.counts,0),
    'active_transfers',coalesce(t.transfers,0),
    'can_deactivate',coalesce(b.quantity,0)=0 and coalesce(cs.sessions,0)=0 and coalesce(ic.counts,0)=0 and coalesce(t.transfers,0)=0,
    'profile',coalesce(to_jsonb(op)-'location_id'-'company_id','{}'::jsonb),
    'economic_terms',case when public.has_company_permission(p_company_id,'view_location_profitability')
      or public.has_company_permission(p_company_id,'manage_location_operating_profiles') then
      coalesce((select to_jsonb(e)-'company_id' from public.location_economic_terms e
        where e.location_id=l.id and current_date between e.effective_from and coalesce(e.effective_to,'infinity'::date)
        order by e.effective_from desc limit 1),'{}'::jsonb)
      else '{}'::jsonb end,
    'responsibilities',coalesce((select jsonb_agg(jsonb_build_object(
      'id',a.id,'responsibility_type',a.responsibility_type,'collaborator_id',a.collaborator_id,
      'collaborator_name',c.display_name,'collaborator_code',c.code,'effective_from',a.effective_from,'effective_to',a.effective_to
    ) order by a.responsibility_type) from public.location_responsibility_assignments a join public.collaborators c on c.id=a.collaborator_id
      where a.location_id=l.id and current_date between a.effective_from and coalesce(a.effective_to,'infinity'::date)),'[]'::jsonb)
  ) into v_result from public.locations l left join public.location_operating_profiles op on op.location_id=l.id
  left join lateral(select coalesce(sum(quantity_on_hand),0) quantity from public.inventory_balances where location_id=l.id)b on true
  left join lateral(select count(*) sessions from public.cash_sessions where location_id=l.id and status in('open','pending_variance_approval'))cs on true
  left join lateral(select count(*) counts from public.inventory_counts where location_id=l.id and status in('open','review','pending_approval'))ic on true
  left join lateral(select count(*) transfers from public.inventory_transfers where (source_location_id=l.id or destination_location_id=l.id) and status in('sent','in_transit'))t on true
  where l.id=p_location_id and l.company_id=p_company_id;
  if v_result is null then raise exception 'Sucursal no disponible.';end if;
  return v_result;
end $$;

create or replace function public.save_company_location_operating_model(
  p_company_id uuid,p_location_id uuid,p_external_code text,p_name text,p_location_type text,p_is_active boolean,
  p_address_line_1 text,p_address_line_2 text,p_neighborhood text,p_municipality text,p_state_name text,p_postal_code text,p_country_code text,
  p_latitude numeric,p_longitude numeric,p_sales_floor_sqm numeric,p_storage_sqm numeric,p_storage_capacity_units numeric,
  p_cost_center_code text,p_opened_on date,p_closed_on date,p_monthly_base_rent numeric,p_monthly_services_budget numeric,
  p_initial_investment numeric,p_economic_effective_from date,p_currency_code text,p_reason text,p_expected_updated_at timestamptz,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_location jsonb;v_id uuid;v_terms public.location_economic_terms%rowtype;v_next_effective_from date;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_location_operating_profiles') then raise exception 'No autorizado para configurar sucursales.';end if;
  if p_client_request_id is null then raise exception 'Falta la referencia idempotente.';end if;
  select entity_id into v_id from public.audit_log where company_id=p_company_id and action='company.location_operating_model_saved'
    and metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_id is not null then return public.get_location_operating_workspace(p_company_id,v_id);end if;
  if p_closed_on is not null and p_is_active then raise exception 'Una sucursal con fecha de cierre no puede permanecer activa.';end if;
  if coalesce(p_monthly_base_rent,0)>0 or coalesce(p_monthly_services_budget,0)>0 or coalesce(p_initial_investment,0)>0 then
    if p_economic_effective_from is null or p_currency_code is null then raise exception 'Indica vigencia y moneda para los datos económicos.';end if;
  end if;
  v_location:=public.save_company_location(p_company_id,p_location_id,p_external_code,p_name,p_location_type,p_is_active,p_reason,p_expected_updated_at,p_client_request_id);
  v_id:=(v_location->>'id')::uuid;
  insert into public.location_operating_profiles(location_id,company_id,address_line_1,address_line_2,neighborhood,municipality,state_name,postal_code,country_code,
    latitude,longitude,sales_floor_sqm,storage_sqm,storage_capacity_units,cost_center_code,opened_on,closed_on,updated_by)
  values(v_id,p_company_id,nullif(trim(p_address_line_1),''),nullif(trim(p_address_line_2),''),nullif(trim(p_neighborhood),''),nullif(trim(p_municipality),''),
    nullif(trim(p_state_name),''),nullif(trim(p_postal_code),''),upper(coalesce(nullif(trim(p_country_code),''),'MX')),p_latitude,p_longitude,p_sales_floor_sqm,
    p_storage_sqm,p_storage_capacity_units,nullif(upper(trim(p_cost_center_code)),''),p_opened_on,p_closed_on,auth.uid())
  on conflict(location_id) do update set address_line_1=excluded.address_line_1,address_line_2=excluded.address_line_2,neighborhood=excluded.neighborhood,
    municipality=excluded.municipality,state_name=excluded.state_name,postal_code=excluded.postal_code,country_code=excluded.country_code,latitude=excluded.latitude,
    longitude=excluded.longitude,sales_floor_sqm=excluded.sales_floor_sqm,storage_sqm=excluded.storage_sqm,storage_capacity_units=excluded.storage_capacity_units,
    cost_center_code=excluded.cost_center_code,opened_on=excluded.opened_on,closed_on=excluded.closed_on,updated_by=auth.uid();
  if p_economic_effective_from is not null then
    perform pg_advisory_xact_lock(hashtextextended(v_id::text||':economic-terms',0));
    select * into v_terms from public.location_economic_terms where location_id=v_id
      and p_economic_effective_from between effective_from and coalesce(effective_to,'infinity'::date) for update;
    if found and v_terms.effective_from=p_economic_effective_from then
      update public.location_economic_terms set currency_code=upper(p_currency_code),monthly_base_rent=coalesce(p_monthly_base_rent,0),
        monthly_services_budget=coalesce(p_monthly_services_budget,0),initial_investment=coalesce(p_initial_investment,0),reason=trim(p_reason),updated_by=auth.uid()
      where id=v_terms.id;
    elsif found then
      update public.location_economic_terms set effective_to=p_economic_effective_from-1,updated_by=auth.uid() where id=v_terms.id;
      insert into public.location_economic_terms(company_id,location_id,effective_from,effective_to,currency_code,monthly_base_rent,monthly_services_budget,initial_investment,reason)
      values(p_company_id,v_id,p_economic_effective_from,v_terms.effective_to,upper(p_currency_code),coalesce(p_monthly_base_rent,0),coalesce(p_monthly_services_budget,0),coalesce(p_initial_investment,0),trim(p_reason));
    else
      select min(effective_from) into v_next_effective_from from public.location_economic_terms where location_id=v_id and effective_from>p_economic_effective_from;
      insert into public.location_economic_terms(company_id,location_id,effective_from,effective_to,currency_code,monthly_base_rent,monthly_services_budget,initial_investment,reason)
      values(p_company_id,v_id,p_economic_effective_from,v_next_effective_from-1,upper(p_currency_code),coalesce(p_monthly_base_rent,0),coalesce(p_monthly_services_budget,0),coalesce(p_initial_investment,0),trim(p_reason));
    end if;
  end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'company.location_operating_model_saved','location',v_id,jsonb_build_object('reason',trim(p_reason),'request_id',p_client_request_id));
  return public.get_location_operating_workspace(p_company_id,v_id);
end $$;

create or replace function public.search_location_responsibility_collaborators(p_company_id uuid,p_query text default null,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_q text:=lower(trim(coalesce(p_query,'')));v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_location_responsibilities') then raise exception 'No autorizado para asignar responsables.';end if;
  select count(*) into v_total from public.collaborators c where c.company_id=p_company_id and c.employment_status='active'
    and(v_q='' or lower(c.display_name) like '%'||v_q||'%' or lower(c.code) like '%'||v_q||'%');
  select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'code',x.code,'name',x.display_name) order by x.display_name,x.id),'[]'::jsonb) into v_items
  from(select c.id,c.code,c.display_name from public.collaborators c where c.company_id=p_company_id and c.employment_status='active'
    and(v_q='' or lower(c.display_name) like '%'||v_q||'%' or lower(c.code) like '%'||v_q||'%') order by c.display_name,c.id limit v_size offset(v_page-1)*v_size)x;
  return jsonb_build_object('items',v_items,'total',v_total,'page',v_page,'page_size',v_size);
end $$;

create or replace function public.assign_location_responsibility(
  p_company_id uuid,p_location_id uuid,p_responsibility_type text,p_collaborator_id uuid,p_effective_from date,p_reason text,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_current public.location_responsibility_assignments%rowtype;v_id uuid;v_next_effective_from date;v_had_current boolean;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_location_responsibilities')
    or not public.can_access_location(p_location_id) then raise exception 'No autorizado para asignar responsables.';end if;
  if p_responsibility_type not in('branch_manager','inventory_owner','financial_owner') then raise exception 'Responsabilidad no válida.';end if;
  if p_effective_from is null or nullif(trim(coalesce(p_reason,'')),'') is null or p_client_request_id is null then raise exception 'Fecha, motivo y referencia son obligatorios.';end if;
  if not exists(select 1 from public.locations where id=p_location_id and company_id=p_company_id and is_active) then raise exception 'Sucursal no disponible.';end if;
  if not exists(select 1 from public.collaborators where id=p_collaborator_id and company_id=p_company_id and employment_status='active') then raise exception 'Colaborador no disponible.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_location_id::text||':'||p_responsibility_type,0));
  select entity_id into v_id from public.audit_log where company_id=p_company_id and action='location.responsibility_assigned'
    and metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_id is not null then return public.get_location_operating_workspace(p_company_id,p_location_id);end if;
  select * into v_current from public.location_responsibility_assignments where location_id=p_location_id and responsibility_type=p_responsibility_type
    and p_effective_from between effective_from and coalesce(effective_to,'infinity'::date) for update;
  v_had_current:=found;
  if found and v_current.effective_from=p_effective_from then
    update public.location_responsibility_assignments set collaborator_id=p_collaborator_id,reason=trim(p_reason),assigned_by=auth.uid() where id=v_current.id returning id into v_id;
  else
    if v_had_current then update public.location_responsibility_assignments set effective_to=p_effective_from-1 where id=v_current.id;end if;
    if not v_had_current then
      select min(effective_from) into v_next_effective_from from public.location_responsibility_assignments
      where location_id=p_location_id and responsibility_type=p_responsibility_type and effective_from>p_effective_from;
    end if;
    insert into public.location_responsibility_assignments(company_id,location_id,collaborator_id,responsibility_type,effective_from,effective_to,reason)
    values(p_company_id,p_location_id,p_collaborator_id,p_responsibility_type,p_effective_from,
      case when v_had_current then v_current.effective_to else v_next_effective_from-1 end,trim(p_reason)) returning id into v_id;
  end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'location.responsibility_assigned','location_responsibility_assignment',v_id,
    jsonb_build_object('location_id',p_location_id,'responsibility_type',p_responsibility_type,'collaborator_id',p_collaborator_id,'effective_from',p_effective_from,'reason',trim(p_reason),'request_id',p_client_request_id));
  return public.get_location_operating_workspace(p_company_id,p_location_id);
end $$;

create or replace function public.get_location_profitability(p_company_id uuid,p_location_id uuid,p_date_from date,p_date_to date)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_currency text;v_sales numeric:=0;v_returns numeric:=0;v_cogs numeric:=0;v_returned_cost numeric:=0;v_expenses numeric:=0;
  v_sale_items bigint:=0;v_costed_items bigint:=0;v_sqm numeric;v_rent numeric:=0;v_services numeric:=0;v_months numeric;
  v_net_sales numeric;v_net_cogs numeric;v_margin numeric;v_margin_rate numeric;v_operating numeric;v_break_even numeric;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_location_profitability') or not public.can_access_location(p_location_id) then raise exception 'No autorizado para consultar rentabilidad.';end if;
  if p_date_from is null or p_date_to is null or p_date_to<p_date_from or p_date_to-p_date_from>366 then raise exception 'Selecciona un periodo válido de hasta 366 días.';end if;
  if not exists(select 1 from public.locations where id=p_location_id and company_id=p_company_id) then raise exception 'Sucursal no disponible.';end if;
  select coalesce(
    (select base_currency from public.accounting_config_versions where company_id=p_company_id and status='approved'),
    (select currency_code from public.location_economic_terms where location_id=p_location_id
      and p_date_to between effective_from and coalesce(effective_to,'infinity'::date) order by effective_from desc limit 1)
  ) into v_currency;
  if v_currency is null then raise exception 'Configura la moneda contable o económica de la sucursal antes de comparar importes.';end if;
  select coalesce(sum(si.taxable_amount),0),coalesce(sum(si.recognized_cost_amount),0),count(*),count(si.recognized_cost_amount)
  into v_sales,v_cogs,v_sale_items,v_costed_items from public.sales s join public.sale_items si on si.sale_id=s.id
  where s.company_id=p_company_id and s.location_id=p_location_id and s.completed_at::date between p_date_from and p_date_to
    and(v_currency is null or s.currency_code=v_currency) and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id);
  select coalesce(sum(ri.taxable_amount),0),coalesce(sum(ri.recognized_cost_amount) filter(where ri.restocked),0)
  into v_returns,v_returned_cost from public.sale_returns r join public.sale_return_items ri on ri.sale_return_id=r.id
  where r.company_id=p_company_id and r.location_id=p_location_id and r.returned_at::date between p_date_from and p_date_to
    and(v_currency is null or r.currency_code=v_currency);
  select coalesce(sum(case when a.normal_balance='debit' then jl.debit-jl.credit else jl.credit-jl.debit end),0)
  into v_expenses from public.accounting_journal_lines jl join public.accounting_journal_entries je on je.id=jl.journal_entry_id
  join public.accounting_accounts a on a.id=jl.account_id and a.company_id=jl.company_id
  where jl.company_id=p_company_id and jl.location_id=p_location_id and je.status='posted' and je.entry_date between p_date_from and p_date_to and a.account_type='expense'
    and not exists(select 1 from public.accounting_event_role_accounts era
      where era.company_id=p_company_id and era.account_id=a.id and era.account_role='cost_of_goods_sold');
  select op.sales_floor_sqm into v_sqm from public.location_operating_profiles op where op.location_id=p_location_id;
  select coalesce(e.monthly_base_rent,0),coalesce(e.monthly_services_budget,0) into v_rent,v_services
  from public.location_economic_terms e where e.location_id=p_location_id and p_date_to between e.effective_from and coalesce(e.effective_to,'infinity'::date) order by e.effective_from desc limit 1;
  v_months:=(p_date_to-p_date_from+1)/30.4375;
  v_net_sales:=v_sales-v_returns;v_net_cogs:=v_cogs-v_returned_cost;v_margin:=v_net_sales-v_net_cogs;
  v_margin_rate:=case when v_net_sales<>0 then v_margin/v_net_sales end;
  v_operating:=case when v_sale_items=v_costed_items then v_margin-v_expenses end;
  v_break_even:=case when v_margin_rate>0 then(v_rent+v_services)*v_months/v_margin_rate end;
  return jsonb_build_object('currency_code',v_currency,'date_from',p_date_from,'date_to',p_date_to,
    'metrics',jsonb_build_object('gross_sales',v_sales,'returns',v_returns,'net_sales',v_net_sales,'net_cogs',case when v_sale_items=v_costed_items then v_net_cogs end,
      'gross_margin',case when v_sale_items=v_costed_items then v_margin end,'gross_margin_percent',case when v_sale_items=v_costed_items then round(v_margin_rate*100,2) end,
      'operating_expenses',v_expenses,'operating_contribution',v_operating,'sales_per_sqm',case when v_sqm>0 then round(v_net_sales/v_sqm,2) end,
      'break_even_sales',v_break_even,'break_even_coverage_percent',case when v_break_even>0 then round(v_net_sales/v_break_even*100,2) end),
    'coverage',jsonb_build_object('sale_item_count',v_sale_items,'costed_sale_item_count',v_costed_items,'recognized_cost_percent',case when v_sale_items=0 then null else round(100.0*v_costed_items/v_sale_items,2) end,
      'sales_floor_sqm',v_sqm,'planned_monthly_rent',v_rent,'planned_monthly_services',v_services),
    'limitations',jsonb_build_array('Los gastos incluyen sólo líneas contabilizadas y atribuidas a esta sucursal.','El punto de equilibrio usa renta y servicios planeados vigentes; no sustituye el resultado contable.'));
end $$;

revoke all on function public.get_location_operating_workspace(uuid,uuid) from public,anon;
revoke all on function public.save_company_location_operating_model(uuid,uuid,text,text,text,boolean,text,text,text,text,text,text,text,numeric,numeric,numeric,numeric,numeric,text,date,date,numeric,numeric,numeric,date,text,text,timestamptz,uuid) from public,anon;
revoke all on function public.search_location_responsibility_collaborators(uuid,text,integer,integer) from public,anon;
revoke all on function public.assign_location_responsibility(uuid,uuid,text,uuid,date,text,uuid) from public,anon;
revoke all on function public.get_location_profitability(uuid,uuid,date,date) from public,anon;
grant execute on function public.get_location_operating_workspace(uuid,uuid) to authenticated;
grant execute on function public.save_company_location_operating_model(uuid,uuid,text,text,text,boolean,text,text,text,text,text,text,text,numeric,numeric,numeric,numeric,numeric,text,date,date,numeric,numeric,numeric,date,text,text,timestamptz,uuid) to authenticated;
grant execute on function public.search_location_responsibility_collaborators(uuid,text,integer,integer) to authenticated;
grant execute on function public.assign_location_responsibility(uuid,uuid,text,uuid,date,text,uuid) to authenticated;
grant execute on function public.get_location_profitability(uuid,uuid,date,date) to authenticated;

commit;
notify pgrst,'reload schema';
