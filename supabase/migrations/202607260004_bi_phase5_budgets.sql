-- Satrapy BI · Fase 5: metas y presupuestos.
-- Extiende el catálogo y el Explorador existentes. Los resultados reales se
-- calculan desde ventas, partidas y cancelaciones canónicas; nunca se copian.

insert into public.permissions(code,description) values
  ('view_bi_budgets','Consultar metas y presupuestos dentro del alcance autorizado.'),
  ('create_bi_budget_drafts','Crear y modificar borradores de metas y presupuestos.'),
  ('import_bi_budgets','Importar presupuestos mediante staging validado.'),
  ('approve_bi_budgets','Aprobar y sustituir versiones de presupuestos.'),
  ('manage_bi_budget_distributions','Administrar distribuciones jerárquicas de presupuestos.'),
  ('view_team_bi_budgets','Consultar y comparar metas del equipo autorizado.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in('super_admin','direccion_admin') and p.code in(
  'view_bi_budgets','create_bi_budget_drafts','import_bi_budgets',
  'approve_bi_budgets','manage_bi_budget_distributions','view_team_bi_budgets'
) on conflict do nothing;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code='ingeniero_campo' and p.code='view_bi_budgets'
on conflict do nothing;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code='supervisor_sucursal' and p.code='view_bi_budgets'
on conflict do nothing;

-- Vínculos canónicos mínimos. Ninguno se completa desde nombre, notas o Alpha.
create table public.collaborator_user_links(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  collaborator_id uuid not null references public.collaborators(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  effective_from date not null default current_date,
  effective_to date,
  reason text not null check(nullif(trim(reason),'') is not null),
  created_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  created_at timestamptz not null default now(),
  check(effective_to is null or effective_to>=effective_from),
  unique(company_id,collaborator_id,effective_from),
  unique(company_id,user_id,effective_from)
);
create index collaborator_user_links_lookup_idx
  on public.collaborator_user_links(company_id,user_id,effective_from,effective_to);

create table public.sale_responsibilities(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  sale_id uuid not null unique references public.sales(id) on delete restrict,
  collaborator_id uuid not null references public.collaborators(id) on delete restrict,
  reason text not null check(nullif(trim(reason),'') is not null),
  assigned_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  assigned_at timestamptz not null default now()
);
create index sale_responsibilities_collaborator_idx
  on public.sale_responsibilities(company_id,collaborator_id,sale_id);

create table public.bi_budgets(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  created_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  created_at timestamptz not null default now()
);

create table public.bi_budget_versions(
  id uuid primary key default gen_random_uuid(),
  budget_id uuid not null references public.bi_budgets(id) on delete restrict,
  company_id uuid not null references public.companies(id) on delete cascade,
  version integer not null check(version>0),
  name text not null check(nullif(trim(name),'') is not null and length(trim(name))<=140),
  description text,
  metric_code text not null check(metric_code in('net_sales','gross_margin','units_sold')),
  period_type text not null check(period_type in('monthly','quarterly','annual')),
  period_start date not null,
  period_end date not null,
  scope_type text not null check(scope_type in(
    'company','location','responsible','category','location_category','responsible_category'
  )),
  location_id uuid references public.locations(id) on delete restrict,
  collaborator_id uuid references public.collaborators(id) on delete restrict,
  category_id uuid references public.product_categories(id) on delete restrict,
  value numeric(20,6) not null check(value>=0),
  unit_code text not null,
  owner_user_id uuid references auth.users(id) on delete set null,
  budget_kind text not null default'independent' check(budget_kind in('independent','distribution')),
  parent_version_id uuid references public.bi_budget_versions(id) on delete restrict,
  replaces_version_id uuid references public.bi_budget_versions(id) on delete restrict,
  status text not null default'draft' check(status in('draft','approved','superseded')),
  approved_by uuid references auth.users(id) on delete restrict,
  approved_at timestamptz,
  approval_reason text,
  created_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(budget_id,version),
  check(period_end>=period_start),
  check(
    (metric_code in('net_sales','gross_margin') and unit_code~'^[A-Z]{3}$')
    or(metric_code='units_sold' and unit_code='unit')
  ),
  check(
    (scope_type='company' and location_id is null and collaborator_id is null and category_id is null)
    or(scope_type='location' and location_id is not null and collaborator_id is null and category_id is null)
    or(scope_type='responsible' and location_id is null and collaborator_id is not null and category_id is null)
    or(scope_type='category' and location_id is null and collaborator_id is null and category_id is not null)
    or(scope_type='location_category' and location_id is not null and collaborator_id is null and category_id is not null)
    or(scope_type='responsible_category' and location_id is null and collaborator_id is not null and category_id is not null)
  ),
  check(
    (budget_kind='independent' and parent_version_id is null)
    or(budget_kind='distribution' and parent_version_id is not null)
  ),
  check(
    (status='approved' and approved_by is not null and approved_at is not null and nullif(trim(approval_reason),'') is not null)
    or(status<>'approved')
  )
);
create index bi_budget_versions_catalog_idx
  on public.bi_budget_versions(company_id,status,period_start desc,id);
create index bi_budget_versions_scope_idx
  on public.bi_budget_versions(company_id,metric_code,scope_type,location_id,collaborator_id,category_id,period_start,period_end);
create index bi_budget_versions_parent_idx on public.bi_budget_versions(parent_version_id,status);

create table public.bi_budget_import_batches(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  client_request_id uuid not null,
  file_name text not null,
  file_sha256 text not null,
  status text not null default'staged' check(status in('staged','validation_failed','promoted')),
  row_count integer not null default 0,
  valid_count integer not null default 0,
  error_count integer not null default 0,
  promoted_count integer not null default 0,
  created_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  created_at timestamptz not null default now(),
  promoted_at timestamptz,
  unique(company_id,client_request_id),
  unique(company_id,file_sha256)
);

create table public.bi_budget_import_rows(
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.bi_budget_import_batches(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  row_number integer not null check(row_number>0),
  raw_data jsonb not null check(jsonb_typeof(raw_data)='object'),
  normalized_data jsonb not null default'{}'::jsonb,
  location_id uuid references public.locations(id) on delete restrict,
  collaborator_id uuid references public.collaborators(id) on delete restrict,
  category_id uuid references public.product_categories(id) on delete restrict,
  errors jsonb not null default'[]'::jsonb check(jsonb_typeof(errors)='array'),
  promoted_version_id uuid references public.bi_budget_versions(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique(batch_id,row_number)
);
create index bi_budget_import_rows_preview_idx on public.bi_budget_import_rows(batch_id,row_number);

create table public.bi_budget_version_events(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  version_id uuid not null references public.bi_budget_versions(id) on delete restrict,
  action text not null check(action in('created','modified','approved','superseded','imported')),
  reason text not null check(nullif(trim(reason),'') is not null),
  snapshot jsonb not null,
  actor_id uuid not null references auth.users(id) on delete restrict default auth.uid(),
  occurred_at timestamptz not null default now()
);
create index bi_budget_version_events_history_idx on public.bi_budget_version_events(version_id,occurred_at,id);

create or replace function public.bi_user_is_field_engineer(p_company_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(
    select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id
    where ur.user_id=auth.uid()and ur.company_id=p_company_id and r.code='ingeniero_campo'
  )
$$;

create or replace function public.bi_user_is_direction(p_company_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_super_admin()or exists(
    select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id
    where ur.user_id=auth.uid()and ur.company_id=p_company_id and r.code='direccion_admin'
  )
$$;

create or replace function public.bi_current_collaborator_id(p_company_id uuid,p_on date default current_date)
returns uuid language sql stable security definer set search_path=public as $$
  select l.collaborator_id from public.collaborator_user_links l
  where l.company_id=p_company_id and l.user_id=auth.uid()
    and l.effective_from<=p_on and(l.effective_to is null or l.effective_to>=p_on)
  order by l.effective_from desc limit 1
$$;

create or replace function public.bi_can_view_budget_version(p_version_id uuid)
returns boolean language plpgsql stable security definer set search_path=public as $$
declare v public.bi_budget_versions%rowtype;v_own uuid;v_effective_location uuid;
begin
  select*into v from public.bi_budget_versions where id=p_version_id;
  if not found or not public.has_company_permission(v.company_id,'view_bi_budgets')then return false;end if;
  v_effective_location:=v.location_id;
  if v_effective_location is null and v.parent_version_id is not null then select location_id into v_effective_location from public.bi_budget_versions where id=v.parent_version_id;end if;
  if v_effective_location is not null and not public.can_access_location(v_effective_location)then return false;end if;
  if public.bi_user_is_field_engineer(v.company_id)then
    v_own:=public.bi_current_collaborator_id(v.company_id,least(current_date,v.period_end));
    return v.collaborator_id=v_own;
  end if;
  if not public.bi_user_is_direction(v.company_id)and v_effective_location is null then return false;end if;
  if v.collaborator_id is not null and v.collaborator_id<>public.bi_current_collaborator_id(v.company_id,least(current_date,v.period_end))
    and not public.has_company_permission(v.company_id,'view_team_bi_budgets')then return false;end if;
  return true;
end$$;

create or replace function public.bi_validate_budget_version()
returns trigger language plpgsql set search_path=public as $$
declare v_company uuid;v_start date;v_end date;
begin
  select company_id into v_company from public.bi_budgets where id=new.budget_id;
  if v_company is null or v_company<>new.company_id then raise exception 'El presupuesto no pertenece a la empresa.';end if;
  if new.location_id is not null and not exists(select 1 from public.locations where id=new.location_id and company_id=new.company_id)then raise exception'Ubicación canónica inválida.';end if;
  if new.collaborator_id is not null and not exists(select 1 from public.collaborators where id=new.collaborator_id and company_id=new.company_id)then raise exception'Responsable canónico inválido.';end if;
  if new.category_id is not null and not exists(select 1 from public.product_categories where id=new.category_id and company_id=new.company_id)then raise exception'Categoría canónica inválida.';end if;
  if new.period_type='monthly'then
    v_start:=date_trunc('month',new.period_start)::date;v_end:=(v_start+interval'1 month'-interval'1 day')::date;
  elsif new.period_type='quarterly'then
    v_start:=date_trunc('quarter',new.period_start)::date;v_end:=(v_start+interval'3 months'-interval'1 day')::date;
  else v_start:=date_trunc('year',new.period_start)::date;v_end:=(v_start+interval'1 year'-interval'1 day')::date;end if;
  if new.period_start<>v_start or new.period_end<>v_end then raise exception'El periodo no coincide con el tipo seleccionado.';end if;
  if tg_op='UPDATE'and old.status in('approved','superseded')
    and not(old.status='approved'and new.status='superseded'
      and(to_jsonb(new)-'status'-'updated_at')=(to_jsonb(old)-'status'-'updated_at'))
    and to_jsonb(new)is distinct from to_jsonb(old)then
    raise exception'Una versión aprobada no puede modificarse destructivamente.';
  end if;
  return new;
end$$;
create trigger bi_budget_versions_validate before insert or update on public.bi_budget_versions
for each row execute function public.bi_validate_budget_version();

create or replace function public.link_collaborator_user(
  p_company_id uuid,p_collaborator_id uuid,p_user_id uuid,p_effective_from date,p_effective_to date,p_reason text
)returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.collaborator_user_links%rowtype;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'manage_collaborators')then raise exception'No autorizado para vincular colaboradores.';end if;
  if nullif(trim(coalesce(p_reason,'')),'')is null then raise exception'El motivo es obligatorio.';end if;
  if not exists(select 1 from public.collaborators where id=p_collaborator_id and company_id=p_company_id)then raise exception'Colaborador no disponible.';end if;
  if not exists(select 1 from public.user_roles where user_id=p_user_id and company_id=p_company_id)then raise exception'Usuario no disponible en la empresa.';end if;
  if exists(select 1 from public.collaborator_user_links l where l.company_id=p_company_id
    and(l.user_id=p_user_id or l.collaborator_id=p_collaborator_id)
    and daterange(l.effective_from,coalesce(l.effective_to,'infinity'::date),'[]')&&daterange(p_effective_from,coalesce(p_effective_to,'infinity'::date),'[]'))
  then raise exception'El vínculo se solapa con otro periodo.';end if;
  insert into public.collaborator_user_links(company_id,collaborator_id,user_id,effective_from,effective_to,reason)
  values(p_company_id,p_collaborator_id,p_user_id,p_effective_from,p_effective_to,trim(p_reason))returning*into v;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'bi.collaborator_user_linked','collaborator_user_link',v.id,jsonb_build_object('collaborator_id',p_collaborator_id,'user_id',p_user_id,'reason',trim(p_reason)));
  return to_jsonb(v);
end$$;

create or replace function public.assign_sale_responsible(
  p_company_id uuid,p_sale_id uuid,p_collaborator_id uuid,p_reason text
)returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.sale_responsibilities%rowtype;
begin
  if auth.uid()is null or not(public.has_company_permission(p_company_id,'manage_collaborators')or public.has_company_permission(p_company_id,'approve_bi_budgets'))then raise exception'No autorizado para atribuir ventas.';end if;
  if nullif(trim(coalesce(p_reason,'')),'')is null then raise exception'El motivo es obligatorio.';end if;
  if not exists(select 1 from public.sales where id=p_sale_id and company_id=p_company_id)then raise exception'Venta no disponible.';end if;
  if not exists(select 1 from public.collaborators where id=p_collaborator_id and company_id=p_company_id and employment_status='active')then raise exception'Responsable no disponible.';end if;
  insert into public.sale_responsibilities(company_id,sale_id,collaborator_id,reason)
  values(p_company_id,p_sale_id,p_collaborator_id,trim(p_reason))returning*into v;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'bi.sale_responsible_assigned','sale',p_sale_id,jsonb_build_object('collaborator_id',p_collaborator_id,'reason',trim(p_reason)));
  return to_jsonb(v);
end$$;

create or replace function public.bi_save_budget_draft(
  p_company_id uuid,p_version_id uuid,p_name text,p_description text,p_metric_code text,
  p_period_type text,p_period_start date,p_scope_type text,p_location_id uuid,p_collaborator_id uuid,
  p_category_id uuid,p_value numeric,p_unit_code text,p_owner_user_id uuid,p_parent_version_id uuid,
  p_replace_version_id uuid,p_reason text
)returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.bi_budget_versions%rowtype;b uuid;v_end date;v_kind text:='independent';v_number integer:=1;old_v public.bi_budget_versions%rowtype;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'create_bi_budget_drafts')then raise exception'No autorizado para crear borradores.';end if;
  if nullif(trim(coalesce(p_reason,'')),'')is null then raise exception'El motivo de creación o modificación es obligatorio.';end if;
  if p_parent_version_id is not null and not public.has_company_permission(p_company_id,'manage_bi_budget_distributions')then raise exception'No autorizado para distribuir presupuestos.';end if;
  if p_period_type='monthly'then v_end:=(date_trunc('month',p_period_start)+interval'1 month'-interval'1 day')::date;
  elsif p_period_type='quarterly'then v_end:=(date_trunc('quarter',p_period_start)+interval'3 months'-interval'1 day')::date;
  elsif p_period_type='annual'then v_end:=(date_trunc('year',p_period_start)+interval'1 year'-interval'1 day')::date;
  else raise exception'Tipo de periodo inválido.';end if;
  if p_version_id is null then
    if p_replace_version_id is not null then
      select*into old_v from public.bi_budget_versions where id=p_replace_version_id and company_id=p_company_id and status='approved';
      if not found then raise exception'La versión a sustituir no está aprobada.';end if;
      b:=old_v.budget_id;v_number:=old_v.version+1;
    else insert into public.bi_budgets(company_id)values(p_company_id)returning id into b;end if;
    if p_parent_version_id is not null then
      v_kind:='distribution';
      if not exists(select 1 from public.bi_budget_versions p where p.id=p_parent_version_id and p.company_id=p_company_id and p.status='approved'
        and p.metric_code=p_metric_code and p.period_start=date_trunc(case p_period_type when'monthly'then'month'when'quarterly'then'quarter'else'year'end,p_period_start)::date
        and p.period_end=v_end and((p.scope_type='company'and p_scope_type='location')or(p.scope_type='location'and p_scope_type in('location_category','responsible')))
        and(p.scope_type<>'location'or p.location_id=coalesce(p_location_id,p.location_id)))
      then raise exception'La distribución no corresponde a una jerarquía aprobada.';end if;
    end if;
    insert into public.bi_budget_versions(budget_id,company_id,version,name,description,metric_code,period_type,period_start,period_end,
      scope_type,location_id,collaborator_id,category_id,value,unit_code,owner_user_id,budget_kind,parent_version_id,replaces_version_id)
    values(b,p_company_id,v_number,trim(p_name),nullif(trim(coalesce(p_description,'')),''),p_metric_code,p_period_type,
      date_trunc(case p_period_type when'monthly'then'month'when'quarterly'then'quarter'else'year'end,p_period_start)::date,v_end,
      p_scope_type,p_location_id,p_collaborator_id,p_category_id,p_value,case when p_metric_code='units_sold'then'unit'else upper(p_unit_code)end,coalesce(p_owner_user_id,auth.uid()),v_kind,p_parent_version_id,p_replace_version_id)
    returning*into v;
    insert into public.bi_budget_version_events(company_id,version_id,action,reason,snapshot)values(p_company_id,v.id,'created',trim(p_reason),to_jsonb(v));
  else
    select*into v from public.bi_budget_versions where id=p_version_id and company_id=p_company_id for update;
    if not found or v.status<>'draft'then raise exception'El borrador no está disponible para modificación.';end if;
    update public.bi_budget_versions set name=trim(p_name),description=nullif(trim(coalesce(p_description,'')),''),metric_code=p_metric_code,
      period_type=p_period_type,period_start=date_trunc(case p_period_type when'monthly'then'month'when'quarterly'then'quarter'else'year'end,p_period_start)::date,
      period_end=v_end,scope_type=p_scope_type,location_id=p_location_id,collaborator_id=p_collaborator_id,category_id=p_category_id,
      value=p_value,unit_code=case when p_metric_code='units_sold'then'unit'else upper(p_unit_code)end,owner_user_id=coalesce(p_owner_user_id,owner_user_id),updated_at=now()
    where id=v.id returning*into v;
    insert into public.bi_budget_version_events(company_id,version_id,action,reason,snapshot)values(p_company_id,v.id,'modified',trim(p_reason),to_jsonb(v));
  end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'bi.budget_draft_saved','bi_budget_version',v.id,jsonb_build_object('version',v.version,'reason',trim(p_reason)));
  return to_jsonb(v);
end$$;

create or replace function public.bi_approve_budget_version(p_company_id uuid,p_version_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.bi_budget_versions%rowtype;parent public.bi_budget_versions%rowtype;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'approve_bi_budgets')then raise exception'No autorizado para aprobar presupuestos.';end if;
  if nullif(trim(coalesce(p_reason,'')),'')is null then raise exception'El motivo de aprobación es obligatorio.';end if;
  select*into v from public.bi_budget_versions where id=p_version_id and company_id=p_company_id for update;
  if not found or v.status<>'draft'then raise exception'El borrador no está disponible.';end if;
  if v.budget_kind='distribution'then
    select*into parent from public.bi_budget_versions where id=v.parent_version_id and status='approved'for share;
    if not found then raise exception'El presupuesto superior ya no está aprobado.';end if;
  elsif exists(select 1 from public.bi_budget_versions x where x.company_id=p_company_id and x.id<>v.id and x.status='approved'
    and x.budget_kind='independent'and x.metric_code=v.metric_code and x.scope_type=v.scope_type
    and x.location_id is not distinct from v.location_id and x.collaborator_id is not distinct from v.collaborator_id
    and x.category_id is not distinct from v.category_id
    and daterange(x.period_start,x.period_end,'[]')&&daterange(v.period_start,v.period_end,'[]')
    and x.id is distinct from v.replaces_version_id)
  then raise exception'Existe un presupuesto aprobado que se solapa con este alcance y periodo.';end if;
  update public.bi_budget_versions set status='approved',approved_by=auth.uid(),approved_at=now(),approval_reason=trim(p_reason),updated_at=now()
  where id=v.id returning*into v;
  if v.replaces_version_id is not null then
    update public.bi_budget_versions set status='superseded',updated_at=now()where id=v.replaces_version_id and status='approved';
    insert into public.bi_budget_version_events(company_id,version_id,action,reason,snapshot)
    select p_company_id,id,'superseded',trim(p_reason),to_jsonb(x)from public.bi_budget_versions x where id=v.replaces_version_id;
  end if;
  insert into public.bi_budget_version_events(company_id,version_id,action,reason,snapshot)values(p_company_id,v.id,'approved',trim(p_reason),to_jsonb(v));
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'bi.budget_approved','bi_budget_version',v.id,jsonb_build_object('version',v.version,'reason',trim(p_reason),'replaces',v.replaces_version_id));
  return to_jsonb(v);
end$$;

create or replace function public.bi_budget_actual(p_version_id uuid,p_from date,p_to date)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v public.bi_budget_versions%rowtype;parent_location uuid;amount numeric:=0;rows_count bigint:=0;attributed bigint:=0;
begin
  select*into v from public.bi_budget_versions where id=p_version_id;
  if not found or not public.bi_can_view_budget_version(v.id)then raise exception'Presupuesto no disponible.';end if;
  if v.metric_code='gross_margin'then
    return jsonb_build_object('available',false,'value',null,'reason','El catálogo BI no dispone aún de costo reconocido por partida vendida y fecha; no se usa costo vigente.');
  end if;
  if v.parent_version_id is not null then select location_id into parent_location from public.bi_budget_versions where id=v.parent_version_id and scope_type='location';end if;
  select coalesce(sum(case when v.metric_code='units_sold'then si.quantity else si.taxable_amount end),0),count(distinct s.id),
    count(distinct s.id)filter(where sr.id is not null)
  into amount,rows_count,attributed
  from public.sales s join public.sale_items si on si.sale_id=s.id
  join public.products p on p.id=si.product_id
  left join public.sale_responsibilities sr on sr.sale_id=s.id
  where s.company_id=v.company_id and s.completed_at::date between p_from and p_to
    and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id)
    and public.can_access_location(s.location_id)
    and(v.location_id is null or s.location_id=v.location_id)
    and(parent_location is null or s.location_id=parent_location)
    and(v.collaborator_id is null or sr.collaborator_id=v.collaborator_id)
    and(v.category_id is null or p.category_id=v.category_id);
  return jsonb_build_object('available',true,'value',amount,'operation_count',rows_count,
    'attributed_operation_count',attributed,'attribution_limited',v.collaborator_id is not null);
end$$;

create or replace function public.bi_list_budget_performance(
  p_company_id uuid,p_status text default'approved',p_from date default null,p_to date default null,
  p_page integer default 1,p_page_size integer default 25
)returns jsonb language plpgsql security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);
v_total bigint;v_items jsonb;today date:=current_date;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'view_bi_budgets')then raise exception'No autorizado para consultar presupuestos.';end if;
  select count(*)into v_total from public.bi_budget_versions v where v.company_id=p_company_id and(p_status is null or v.status=p_status)
    and(p_from is null or v.period_end>=p_from)and(p_to is null or v.period_start<=p_to)and public.bi_can_view_budget_version(v.id);
  select coalesce(jsonb_agg(to_jsonb(x)order by x.period_start desc,x.name,x.id),'[]')into v_items from(
    select v.*,coalesce(l.name,c.display_name,pc.name,'Empresa')scope_label,
      a.available actual_available,a.value actual_value,a.reason actual_reason,
      case when a.available and v.value<>0 then round(a.value/v.value*100,2)end attainment_percent,
      case when a.available then v.value-a.value end remaining_value,
      case when a.available then case when today<v.period_start then 0 when today>=v.period_end then a.value
        else round(a.value/greatest(today-v.period_start+1,1)*(v.period_end-v.period_start+1),6)end end projected_value,
      case when v.budget_kind='independent'then coalesce(d.assigned,0)else null end assigned_value,
      case when v.budget_kind='independent'then greatest(v.value-coalesce(d.assigned,0),0)else null end pending_distribution,
      case when v.budget_kind='independent'then greatest(coalesce(d.assigned,0)-v.value,0)else null end distribution_excess
    from public.bi_budget_versions v
    left join public.locations l on l.id=v.location_id left join public.collaborators c on c.id=v.collaborator_id
    left join public.product_categories pc on pc.id=v.category_id
    left join lateral(select sum(ch.value)assigned from public.bi_budget_versions ch where ch.parent_version_id=v.id and ch.status='approved')d on true
    left join lateral(select (z->>'available')::boolean available,(z->>'value')::numeric value,z->>'reason'reason
      from(select public.bi_budget_actual(v.id,v.period_start,least(today,v.period_end))z)q)a on true
    where v.company_id=p_company_id and(p_status is null or v.status=p_status)
      and(p_from is null or v.period_end>=p_from)and(p_to is null or v.period_start<=p_to)and public.bi_can_view_budget_version(v.id)
    order by v.period_start desc,v.name,v.id limit v_size offset(v_page-1)*v_size
  )x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total),'updated_at',now());
end$$;

create or replace function public.bi_search_budget_scope_options(
  p_company_id uuid,p_scope text,p_query text default null,p_page integer default 1,p_page_size integer default 20
)returns jsonb language plpgsql stable security definer set search_path=public as $$
declare q text:=lower(trim(coalesce(p_query,'')));v_page integer:=greatest(p_page,1);v_size integer:=least(greatest(p_page_size,1),50);v_total bigint;items jsonb;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'create_bi_budget_drafts')then raise exception'No autorizado para consultar alcances.';end if;
  if p_scope='location'then
    select count(*)into v_total from public.locations l where l.company_id=p_company_id and l.is_active and public.can_access_location(l.id)
      and(q=''or lower(l.name)like'%'||q||'%'or lower(l.external_code)like'%'||q||'%');
    select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'label',x.name,'secondary',x.external_code)order by x.name,x.id),'[]')into items from(
      select l.id,l.name,l.external_code from public.locations l where l.company_id=p_company_id and l.is_active and public.can_access_location(l.id)
        and(q=''or lower(l.name)like'%'||q||'%'or lower(l.external_code)like'%'||q||'%')
      order by l.name,l.id limit v_size offset(v_page-1)*v_size)x;
  elsif p_scope='responsible'then
    select count(*)into v_total from public.collaborators c where c.company_id=p_company_id and c.employment_status='active'
      and(q=''or lower(c.display_name)like'%'||q||'%'or lower(c.code)like'%'||q||'%');
    select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'label',x.display_name,'secondary',x.code)order by x.display_name,x.id),'[]')into items from(
      select c.id,c.display_name,c.code from public.collaborators c where c.company_id=p_company_id and c.employment_status='active'
        and(q=''or lower(c.display_name)like'%'||q||'%'or lower(c.code)like'%'||q||'%')
      order by c.display_name,c.id limit v_size offset(v_page-1)*v_size)x;
  elsif p_scope='category'then
    select count(*)into v_total from public.product_categories c where c.company_id=p_company_id
      and(q=''or lower(c.name)like'%'||q||'%'or lower(c.external_code)like'%'||q||'%');
    select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'label',x.name,'secondary',x.external_code)order by x.name,x.id),'[]')into items from(
      select c.id,c.name,c.external_code from public.product_categories c where c.company_id=p_company_id
        and(q=''or lower(c.name)like'%'||q||'%'or lower(c.external_code)like'%'||q||'%')
      order by c.name,c.id limit v_size offset(v_page-1)*v_size)x;
  else raise exception'Tipo de alcance inválido.';end if;
  return jsonb_build_object('items',items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end$$;

create or replace function public.bi_get_budget_detail(p_company_id uuid,p_version_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.bi_budget_versions%rowtype;actual jsonb;previous jsonb;series jsonb;events jsonb;children jsonb;today date:=current_date;
begin
  select*into v from public.bi_budget_versions where id=p_version_id and company_id=p_company_id;
  if not found or not public.bi_can_view_budget_version(v.id)then raise exception'Presupuesto no disponible.';end if;
  actual:=public.bi_budget_actual(v.id,v.period_start,least(today,v.period_end));
  previous:=public.bi_budget_actual(v.id,v.period_start-(v.period_end-v.period_start+1),v.period_start-1);
  select coalesce(jsonb_agg(jsonb_build_object('date',d,'actual',case when(a->>'available')::boolean then(a->>'value')::numeric end,
    'budget_pace',round(v.value*(d::date-v.period_start+1)/(v.period_end-v.period_start+1),6))order by d),'[]')into series
  from generate_series(v.period_start,least(v.period_end,today),'1 day')g(d)
  cross join lateral(select public.bi_budget_actual(v.id,v.period_start,d::date)a)q;
  select coalesce(jsonb_agg(to_jsonb(e)order by occurred_at desc,id),'[]')into events from public.bi_budget_version_events e where e.version_id=v.id;
  select coalesce(jsonb_agg(to_jsonb(c)order by c.name,c.id),'[]')into children from public.bi_budget_versions c where c.parent_version_id=v.id and public.bi_can_view_budget_version(c.id);
  return jsonb_build_object('version',to_jsonb(v),'actual',actual,'previous_period',previous,'series',series,'history',events,'distributions',children);
end$$;

create or replace function public.bi_budget_drilldown(
  p_company_id uuid,p_version_id uuid,p_page integer default 1,p_page_size integer default 25
)returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.bi_budget_versions%rowtype;parent_location uuid;v_page integer:=greatest(p_page,1);v_size integer:=least(greatest(p_page_size,1),100);v_total bigint;v_items jsonb;
begin
  select*into v from public.bi_budget_versions where id=p_version_id and company_id=p_company_id;
  if not found or not public.bi_can_view_budget_version(v.id)then raise exception'Presupuesto no disponible.';end if;
  if v.metric_code='gross_margin'then raise exception'El margen no dispone de resultado real canónico para drill-down.';end if;
  if v.parent_version_id is not null then select location_id into parent_location from public.bi_budget_versions where id=v.parent_version_id and scope_type='location';end if;
  with matching as(
    select s.id,s.completed_at,l.name location_name,coalesce(c.display_name,'Sin atribución')responsible_name,
      sum(case when v.metric_code='units_sold'then si.quantity else si.taxable_amount end)value
    from public.sales s join public.sale_items si on si.sale_id=s.id join public.products p on p.id=si.product_id
    join public.locations l on l.id=s.location_id left join public.sale_responsibilities sr on sr.sale_id=s.id
    left join public.collaborators c on c.id=sr.collaborator_id
    where s.company_id=p_company_id and s.completed_at::date between v.period_start and least(v.period_end,current_date)
      and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id)and public.can_access_location(s.location_id)
      and(v.location_id is null or s.location_id=v.location_id)and(parent_location is null or s.location_id=parent_location)
      and(v.collaborator_id is null or sr.collaborator_id=v.collaborator_id)and(v.category_id is null or p.category_id=v.category_id)
    group by s.id,s.completed_at,l.name,c.display_name
  )select count(*)into v_total from matching;
  with matching as(
    select s.id,s.completed_at,l.name location_name,coalesce(c.display_name,'Sin atribución')responsible_name,
      sum(case when v.metric_code='units_sold'then si.quantity else si.taxable_amount end)value
    from public.sales s join public.sale_items si on si.sale_id=s.id join public.products p on p.id=si.product_id
    join public.locations l on l.id=s.location_id left join public.sale_responsibilities sr on sr.sale_id=s.id
    left join public.collaborators c on c.id=sr.collaborator_id
    where s.company_id=p_company_id and s.completed_at::date between v.period_start and least(v.period_end,current_date)
      and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id)and public.can_access_location(s.location_id)
      and(v.location_id is null or s.location_id=v.location_id)and(parent_location is null or s.location_id=parent_location)
      and(v.collaborator_id is null or sr.collaborator_id=v.collaborator_id)and(v.category_id is null or p.category_id=v.category_id)
    group by s.id,s.completed_at,l.name,c.display_name
  )select coalesce(jsonb_agg(to_jsonb(x)order by completed_at desc,id),'[]')into v_items from(
    select*from matching order by completed_at desc,id limit v_size offset(v_page-1)*v_size
  )x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end$$;

create or replace function public.bi_stage_budget_import(
  p_company_id uuid,p_client_request_id uuid,p_file_name text,p_file_sha256 text,p_rows jsonb
)returns jsonb language plpgsql security definer set search_path=public as $$
declare b public.bi_budget_import_batches%rowtype;r jsonb;n integer:=0;errs jsonb;loc uuid;col uuid;cat uuid;scope text;metric text;ptype text;unit text;start_on date;amount numeric;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'import_bi_budgets')then raise exception'No autorizado para importar presupuestos.';end if;
  select*into b from public.bi_budget_import_batches where company_id=p_company_id and(client_request_id=p_client_request_id or file_sha256=p_file_sha256);
  if found then return jsonb_build_object('batch_id',b.id,'status',b.status,'idempotent',true,'row_count',b.row_count,'valid_count',b.valid_count,'error_count',b.error_count);end if;
  if jsonb_typeof(p_rows)<>'array'or jsonb_array_length(p_rows)=0 or jsonb_array_length(p_rows)>50000 then raise exception'El archivo debe contener entre 1 y 50,000 filas.';end if;
  insert into public.bi_budget_import_batches(company_id,client_request_id,file_name,file_sha256)values(p_company_id,p_client_request_id,p_file_name,p_file_sha256)returning*into b;
  for r in select value from jsonb_array_elements(p_rows)loop
    n:=n+1;errs:='[]';loc:=null;col:=null;cat:=null;
    scope:=lower(trim(coalesce(r->>'scope_type','')));metric:=lower(trim(coalesce(r->>'metric_code','')));
    ptype:=lower(trim(coalesce(r->>'period_type','')));unit:=upper(trim(coalesce(r->>'unit_code','')));
    begin start_on:=(r->>'period_start')::date;exception when others then start_on:=null;errs:=errs||'"Periodo inicial inválido."'::jsonb;end;
    begin amount:=(r->>'value')::numeric;exception when others then amount:=null;errs:=errs||'"Valor inválido."'::jsonb;end;
    if metric not in('net_sales','gross_margin','units_sold')then errs:=errs||'"Métrica inválida."'::jsonb;end if;
    if ptype not in('monthly','quarterly','annual')then errs:=errs||'"Tipo de periodo inválido."'::jsonb;end if;
    if scope not in('company','location','responsible','category','location_category','responsible_category')then errs:=errs||'"Alcance inválido."'::jsonb;end if;
    if amount is null or amount<0 then errs:=errs||'"El valor debe ser mayor o igual a cero."'::jsonb;end if;
    if(metric in('net_sales','gross_margin')and unit!~'^[A-Z]{3}$')or(metric='units_sold'and lower(unit)<>'unit')then errs:=errs||'"Unidad o moneda inválida."'::jsonb;end if;
    if scope in('location','location_category')then
      select(array_agg(id))[1]into loc from public.locations where company_id=p_company_id and external_code=trim(r->>'location_code')having count(*)=1;
      if loc is null then errs:=errs||'"Ubicación inexistente o ambigua."'::jsonb;end if;
    end if;
    if scope in('responsible','responsible_category')then
      select(array_agg(id))[1]into col from public.collaborators where company_id=p_company_id and code=trim(r->>'responsible_code')having count(*)=1;
      if col is null then errs:=errs||'"Responsable inexistente o ambiguo."'::jsonb;end if;
    end if;
    if scope in('category','location_category','responsible_category')then
      select(array_agg(id))[1]into cat from public.product_categories where company_id=p_company_id and external_code=trim(r->>'category_code')having count(*)=1;
      if cat is null then errs:=errs||'"Categoría inexistente o ambigua."'::jsonb;end if;
    end if;
    insert into public.bi_budget_import_rows(batch_id,company_id,row_number,raw_data,normalized_data,location_id,collaborator_id,category_id,errors)
    values(b.id,p_company_id,n,r,jsonb_build_object('name',trim(r->>'name'),'description',nullif(trim(coalesce(r->>'description','')),''),
      'metric_code',metric,'period_type',ptype,'period_start',start_on,'scope_type',scope,'value',amount,'unit_code',case when metric='units_sold'then'unit'else unit end),
      loc,col,cat,errs);
  end loop;
  update public.bi_budget_import_batches set row_count=n,
    valid_count=(select count(*)from public.bi_budget_import_rows where batch_id=b.id and errors='[]'),
    error_count=(select count(*)from public.bi_budget_import_rows where batch_id=b.id and errors<>'[]'),
    status=case when exists(select 1 from public.bi_budget_import_rows where batch_id=b.id and errors<>'[]')then'validation_failed'else'staged'end
  where id=b.id returning*into b;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'bi.budget_import_staged','bi_budget_import_batch',b.id,jsonb_build_object('rows',n,'valid',b.valid_count,'errors',b.error_count));
  return jsonb_build_object('batch_id',b.id,'status',b.status,'idempotent',false,'row_count',b.row_count,'valid_count',b.valid_count,'error_count',b.error_count);
end$$;

create or replace function public.bi_budget_import_preview(p_company_id uuid,p_batch_id uuid,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare b public.bi_budget_import_batches%rowtype;items jsonb;v_page integer:=greatest(p_page,1);v_size integer:=least(greatest(p_page_size,1),100);
begin
  select*into b from public.bi_budget_import_batches where id=p_batch_id and company_id=p_company_id;
  if not found or not public.has_company_permission(p_company_id,'import_bi_budgets')then raise exception'Lote no disponible.';end if;
  select coalesce(jsonb_agg(to_jsonb(x)order by row_number),'[]')into items from(
    select*from public.bi_budget_import_rows where batch_id=b.id order by row_number limit v_size offset(v_page-1)*v_size
  )x;
  return jsonb_build_object('batch',to_jsonb(b),'items',items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',b.row_count));
end$$;

create or replace function public.bi_promote_budget_import(p_company_id uuid,p_batch_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare b public.bi_budget_import_batches%rowtype;r public.bi_budget_import_rows%rowtype;budget uuid;v public.bi_budget_versions%rowtype;v_end date;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'import_bi_budgets')or not public.has_company_permission(p_company_id,'create_bi_budget_drafts')then raise exception'No autorizado para promover presupuestos.';end if;
  if nullif(trim(coalesce(p_reason,'')),'')is null then raise exception'El motivo de promoción es obligatorio.';end if;
  select*into b from public.bi_budget_import_batches where id=p_batch_id and company_id=p_company_id for update;
  if not found then raise exception'Lote no disponible.';end if;
  if b.status='promoted'then return jsonb_build_object('batch_id',b.id,'status',b.status,'promoted_count',b.promoted_count,'idempotent',true);end if;
  if b.error_count>0 then raise exception'Corrige todas las filas inválidas antes de promover.';end if;
  for r in select*from public.bi_budget_import_rows where batch_id=b.id order by row_number for update loop
    if r.promoted_version_id is not null then continue;end if;
    if r.normalized_data->>'period_type'='monthly'then v_end:=(date_trunc('month',(r.normalized_data->>'period_start')::date)+interval'1 month'-interval'1 day')::date;
    elsif r.normalized_data->>'period_type'='quarterly'then v_end:=(date_trunc('quarter',(r.normalized_data->>'period_start')::date)+interval'3 months'-interval'1 day')::date;
    else v_end:=(date_trunc('year',(r.normalized_data->>'period_start')::date)+interval'1 year'-interval'1 day')::date;end if;
    insert into public.bi_budgets(company_id)values(p_company_id)returning id into budget;
    insert into public.bi_budget_versions(budget_id,company_id,version,name,description,metric_code,period_type,period_start,period_end,scope_type,
      location_id,collaborator_id,category_id,value,unit_code,owner_user_id)
    values(budget,p_company_id,1,r.normalized_data->>'name',r.normalized_data->>'description',r.normalized_data->>'metric_code',r.normalized_data->>'period_type',
      (r.normalized_data->>'period_start')::date,v_end,r.normalized_data->>'scope_type',r.location_id,r.collaborator_id,r.category_id,
      (r.normalized_data->>'value')::numeric,r.normalized_data->>'unit_code',auth.uid())returning*into v;
    update public.bi_budget_import_rows set promoted_version_id=v.id where id=r.id;
    insert into public.bi_budget_version_events(company_id,version_id,action,reason,snapshot)values(p_company_id,v.id,'imported',trim(p_reason),to_jsonb(v));
  end loop;
  update public.bi_budget_import_batches set status='promoted',promoted_count=row_count,promoted_at=now()where id=b.id returning*into b;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'bi.budget_import_promoted','bi_budget_import_batch',b.id,jsonb_build_object('rows',b.promoted_count,'reason',trim(p_reason)));
  return jsonb_build_object('batch_id',b.id,'status',b.status,'promoted_count',b.promoted_count,'idempotent',false);
end$$;

-- Catálogo: se conserva la implementación Fase 3/4 y sólo se agregan contratos.
alter function public.bi_get_metric_catalog(uuid) rename to bi_get_metric_catalog_phase4;
create or replace function public.bi_get_metric_catalog(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare c jsonb;m jsonb;target text;label text;unit text;suffix text;
begin
  c:=public.bi_get_metric_catalog_phase4(p_company_id);
  c:=jsonb_set(c,'{dimensions}',(c->'dimensions')||jsonb_build_array(jsonb_build_object('code','responsible','name','Responsable comercial')));
  m:=c->'metrics';
  foreach target in array array['net_sales','gross_margin','units_sold']loop
    label:=case target when'net_sales'then'Venta neta'when'gross_margin'then'Margen'else'Unidades vendidas'end;
    unit:=case when target='units_sold'then'quantity'else'currency'end;
    foreach suffix in array array['budget','actual','variance','projection','attainment']loop
      m:=m||jsonb_build_array(jsonb_build_object(
        'code',target||'_'||suffix,
        'name',label||case suffix when'budget'then' · presupuesto'when'actual'then' · resultado'when'variance'then' · diferencia'when'projection'then' · proyección'else' · cumplimiento'end,
        'module','Metas y presupuestos',
        'formula',case suffix when'budget'then'Versión aprobada vigente'when'actual'then'Resultado real desde el catálogo BI'
          when'variance'then'Presupuesto − resultado acumulado'when'projection'then'Ritmo acumulado proyectado al cierre'else'Resultado acumulado ÷ presupuesto × 100'end,
        'unit',case when suffix='attainment'then'percent'else unit end,
        'source','bi_budget_versions + catálogo BI canónico','grain','budget_period',
        'dimensions',jsonb_build_array('period','location','responsible','category'),
        'kind',case when target='units_sold'then'operational'else'accrual'end,
        'visualizations',jsonb_build_array('line','bar','area','scatter'),'drilldown',suffix='actual',
        'available',target<>'gross_margin'or suffix='budget',
        'unavailable_reason',case when target='gross_margin'and suffix<>'budget'then'El margen real permanece no disponible hasta conservar costo reconocido por partida vendida y fecha.'end,
        'limitations','No suma porcentajes ni mezcla presupuestos superiores con sus distribuciones.'
      ));
    end loop;
  end loop;
  return jsonb_set(c,'{metrics}',m);
end$$;

create or replace function public.bi_budget_explorer_query(
  p_company_id uuid,p_metric_codes text[],p_dimension text,p_visualization text,p_date_from date,p_date_to date,
  p_page integer,p_page_size integer
)returns jsonb language plpgsql security definer set search_path=public as $$
declare v_page integer:=greatest(p_page,1);v_size integer:=least(greatest(p_page_size,1),100);v_total bigint;items jsonb;chart jsonb;first_code text;target text;suffix text;
begin
  if not public.has_company_permission(p_company_id,'view_bi_budgets')then raise exception'No autorizado para consultar presupuestos.';end if;
  first_code:=p_metric_codes[1];target:=regexp_replace(first_code,'_(budget|actual|variance|projection|attainment)$','');
  if exists(select 1 from unnest(p_metric_codes)c where regexp_replace(c,'_(budget|actual|variance|projection|attainment)$','')<>target)then raise exception'Combina indicadores del mismo objetivo base.';end if;
  if target='gross_margin'and exists(select 1 from unnest(p_metric_codes)c where c!~'_budget$')then raise exception'El margen real permanece no disponible en el catálogo BI.';end if;
  if p_dimension not in('period','location','responsible','category')then raise exception'Dimensión no compatible con presupuestos.';end if;
  drop table if exists pg_temp.bi_budget_explorer_result;
  create temporary table bi_budget_explorer_result(metric_code text,group_key text,group_label text,current_value numeric,previous_value numeric,available boolean,reason text)on commit drop;
  foreach first_code in array p_metric_codes loop
    suffix:=regexp_replace(first_code,'^.*_(budget|actual|variance|projection|attainment)$','\1');
    insert into bi_budget_explorer_result
    select first_code,
      case p_dimension when'period'then v.period_start::text when'location'then coalesce(v.location_id::text,'company')
        when'responsible'then coalesce(v.collaborator_id::text,'unassigned')else coalesce(v.category_id::text,'all')end,
      case p_dimension when'period'then to_char(v.period_start,'Mon YYYY')when'location'then coalesce(l.name,'Empresa')
        when'responsible'then coalesce(c.display_name,'Sin responsable')else coalesce(pc.name,'Todas las categorías')end,
      case suffix when'budget'then v.value when'actual'then a.value when'variance'then v.value-a.value
        when'projection'then case when current_date>=v.period_end then a.value else round(a.value/greatest(current_date-v.period_start+1,1)*(v.period_end-v.period_start+1),6)end
        else case when v.value=0 then null else round(a.value/v.value*100,2)end end,
      null,true,null
    from public.bi_budget_versions v left join public.locations l on l.id=v.location_id
    left join public.collaborators c on c.id=v.collaborator_id left join public.product_categories pc on pc.id=v.category_id
    cross join lateral(select(public.bi_budget_actual(v.id,v.period_start,least(current_date,v.period_end))->>'value')::numeric value)a
    where v.company_id=p_company_id and v.status='approved'and v.metric_code=target and v.budget_kind='independent'
      and v.period_end>=p_date_from and v.period_start<=p_date_to and public.bi_can_view_budget_version(v.id);
  end loop;
  select count(*)into v_total from bi_budget_explorer_result;
  select coalesce(jsonb_agg(to_jsonb(x)order by group_label,metric_code),'[]')into items from(
    select*from bi_budget_explorer_result order by group_label,metric_code limit v_size offset(v_page-1)*v_size
  )x;
  select coalesce(jsonb_agg(to_jsonb(x)order by group_key,metric_code),'[]')into chart from(select*from bi_budget_explorer_result order by group_key,metric_code limit 500)x;
  return jsonb_build_object('query',jsonb_build_object('metric_codes',p_metric_codes,'dimension',p_dimension,'visualization',p_visualization),
    'period',jsonb_build_object('from',p_date_from,'to',p_date_to),'currency_code',(public.bi_get_metric_catalog_phase4(p_company_id)->>'currency_code'),
    'updated_at',now(),'chart',chart,'items',items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total),
    'trace',jsonb_build_object('query','bi_budget_explorer_query','company_id',p_company_id));
end$$;

alter function public.bi_explorer_query(uuid,text[],text,text,date,date,uuid,uuid,uuid,uuid,boolean,integer,integer)
rename to bi_explorer_query_phase4;
create or replace function public.bi_explorer_query(
  p_company_id uuid,p_metric_codes text[],p_dimension text,p_visualization text,p_date_from date,p_date_to date,
  p_location_id uuid default null,p_product_id uuid default null,p_customer_id uuid default null,p_supplier_id uuid default null,
  p_compare_previous boolean default true,p_page integer default 1,p_page_size integer default 25
)returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if exists(select 1 from unnest(p_metric_codes)c where c~'^(net_sales|gross_margin|units_sold)_(budget|actual|variance|projection|attainment)$')then
    if exists(select 1 from unnest(p_metric_codes)c where c!~'^(net_sales|gross_margin|units_sold)_(budget|actual|variance|projection|attainment)$')then raise exception'No mezcles métricas presupuestales y operativas en la misma consulta.';end if;
    return public.bi_budget_explorer_query(p_company_id,p_metric_codes,p_dimension,p_visualization,p_date_from,p_date_to,p_page,p_page_size);
  end if;
  return public.bi_explorer_query_phase4(p_company_id,p_metric_codes,p_dimension,p_visualization,p_date_from,p_date_to,
    p_location_id,p_product_id,p_customer_id,p_supplier_id,p_compare_previous,p_page,p_page_size);
end$$;

alter table public.collaborator_user_links enable row level security;
alter table public.sale_responsibilities enable row level security;
alter table public.bi_budgets enable row level security;
alter table public.bi_budget_versions enable row level security;
alter table public.bi_budget_import_batches enable row level security;
alter table public.bi_budget_import_rows enable row level security;
alter table public.bi_budget_version_events enable row level security;

create policy collaborator_user_links_read on public.collaborator_user_links for select to authenticated
using(public.has_company_permission(company_id,'view_collaborators')or user_id=auth.uid());
create policy sale_responsibilities_read on public.sale_responsibilities for select to authenticated
using(public.has_company_permission(company_id,'view_bi_budgets')
  and(not public.bi_user_is_field_engineer(company_id)or collaborator_id=public.bi_current_collaborator_id(company_id,current_date))
  and exists(select 1 from public.sales s where s.id=sale_id and public.can_access_location(s.location_id)));
create policy bi_budgets_read on public.bi_budgets for select to authenticated using(
  exists(select 1 from public.bi_budget_versions v where v.budget_id=id and public.bi_can_view_budget_version(v.id))
);
create policy bi_budget_versions_read on public.bi_budget_versions for select to authenticated using(public.bi_can_view_budget_version(id));
create policy bi_budget_import_batches_read on public.bi_budget_import_batches for select to authenticated using(
  created_by=auth.uid()and public.has_company_permission(company_id,'import_bi_budgets')
);
create policy bi_budget_import_rows_read on public.bi_budget_import_rows for select to authenticated using(
  exists(select 1 from public.bi_budget_import_batches b where b.id=batch_id)
);
create policy bi_budget_version_events_read on public.bi_budget_version_events for select to authenticated using(
  public.bi_can_view_budget_version(version_id)
);

revoke all on public.collaborator_user_links,public.sale_responsibilities,public.bi_budgets,public.bi_budget_versions,
  public.bi_budget_import_batches,public.bi_budget_import_rows,public.bi_budget_version_events from public,anon,authenticated;
grant select on public.collaborator_user_links,public.sale_responsibilities,public.bi_budgets,public.bi_budget_versions,
  public.bi_budget_import_batches,public.bi_budget_import_rows,public.bi_budget_version_events to authenticated;

do $$declare r record;begin
  for r in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'and p.proname in(
      'bi_user_is_field_engineer','bi_user_is_direction','bi_current_collaborator_id','bi_can_view_budget_version','link_collaborator_user',
      'assign_sale_responsible','bi_save_budget_draft','bi_approve_budget_version','bi_budget_actual',
      'bi_list_budget_performance','bi_search_budget_scope_options','bi_get_budget_detail','bi_budget_drilldown','bi_stage_budget_import',
      'bi_budget_import_preview','bi_promote_budget_import','bi_get_metric_catalog','bi_budget_explorer_query','bi_explorer_query'
    )
  loop execute format('revoke all on function %s from public,anon',r.signature);execute format('grant execute on function %s to authenticated',r.signature);end loop;
end$$;

notify pgrst,'reload schema';
