-- Satrapy · Module 1: Productos, Inventario y Ubicaciones
-- Apply with Supabase CLI or in the Supabase SQL editor. No business data is seeded.

create extension if not exists pgcrypto;

create table public.companies (
  id uuid primary key default gen_random_uuid(),
  legal_name text not null,
  display_name text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  default_company_id uuid references public.companies(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.roles (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  display_name text not null,
  description text not null,
  created_at timestamptz not null default now(),
  constraint roles_code_check check (code in (
    'super_admin', 'direccion_admin', 'sucursal', 'ingeniero_campo', 'almacen', 'punto_venta'
  ))
);

create table public.permissions (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  description text not null,
  created_at timestamptz not null default now()
);

create table public.role_permissions (
  role_id uuid not null references public.roles(id) on delete cascade,
  permission_id uuid not null references public.permissions(id) on delete cascade,
  primary key (role_id, permission_id)
);

create table public.user_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  role_id uuid not null references public.roles(id) on delete cascade,
  company_id uuid references public.companies(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (user_id, role_id, company_id)
);

create unique index user_roles_global_role_unique
  on public.user_roles(user_id, role_id)
  where company_id is null;

create table public.locations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  external_code text not null,
  name text not null,
  location_type text not null default 'almacen',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, external_code)
);

create table public.user_location_access (
  user_id uuid not null references auth.users(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete cascade,
  access_type text not null default 'inventory',
  created_at timestamptz not null default now(),
  primary key (user_id, location_id)
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  alpha_sku text not null,
  alpha_class text,
  name text not null,
  attribute text,
  unit text,
  product_group text,
  subgroup text,
  product_type text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, alpha_sku)
);

create index products_company_sku_idx on public.products(company_id, alpha_sku);
create index products_company_name_idx on public.products(company_id, name);

create table public.price_lists (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  external_code text not null,
  name text not null,
  currency_code text not null default 'MXN',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, external_code)
);

create table public.product_prices (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  price_list_id uuid not null references public.price_lists(id) on delete cascade,
  amount numeric(18, 6) not null check (amount >= 0),
  currency_code text not null default 'MXN',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (product_id, price_list_id)
);

create table public.inventory_snapshots (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  import_batch_id uuid,
  source_file_name text not null,
  snapshot_date date,
  status text not null default 'processing' check (status in ('processing', 'completed', 'failed')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.inventory_snapshot_items (
  id uuid primary key default gen_random_uuid(),
  snapshot_id uuid not null references public.inventory_snapshots(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  location_id uuid not null references public.locations(id) on delete restrict,
  quantity numeric(18, 6) not null,
  unit text,
  imported_at timestamptz not null default now(),
  unique (snapshot_id, product_id, location_id)
);

create index inventory_items_location_idx on public.inventory_snapshot_items(location_id, imported_at desc);
create index inventory_items_product_idx on public.inventory_snapshot_items(product_id, imported_at desc);

create table public.import_batches (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  import_type text not null check (import_type in ('products', 'inventory')),
  source text not null check (source in ('manual_upload', 'local_development')),
  file_sha256 text not null,
  status text not null default 'processing' check (status in ('processing', 'completed', 'failed', 'validation_failed')),
  records_received integer not null default 0,
  records_imported integer not null default 0,
  imported_by uuid not null references auth.users(id) on delete restrict,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  notes text,
  constraint import_batches_company_type_file_sha256_key unique (company_id, import_type, file_sha256)
);

alter table public.inventory_snapshots
  add constraint inventory_snapshots_import_batch_id_fkey
  foreign key (import_batch_id) references public.import_batches(id) on delete set null;

create table public.import_files (
  id uuid primary key default gen_random_uuid(),
  import_batch_id uuid not null references public.import_batches(id) on delete cascade,
  original_name text not null,
  file_type text not null,
  file_sha256 text not null,
  row_count integer not null default 0,
  created_at timestamptz not null default now(),
  unique (import_batch_id, original_name)
);

create table public.import_errors (
  id uuid primary key default gen_random_uuid(),
  import_batch_id uuid not null references public.import_batches(id) on delete cascade,
  severity text not null check (severity in ('error', 'warning')),
  error_code text not null,
  message text not null,
  row_number integer,
  alpha_sku text,
  created_at timestamptz not null default now()
);

create table public.audit_log (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.companies(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index audit_log_company_created_idx on public.audit_log(company_id, created_at desc);

-- System configuration only: no company, user, location, product, or inventory rows are inserted.
insert into public.roles (code, display_name, description) values
  ('super_admin', 'Super Admin', 'Acceso global y pruebas de rol.'),
  ('direccion_admin', 'Dirección / Admin General', 'Administra toda la información de su empresa.'),
  ('sucursal', 'Sucursal', 'Consulta existencias de sus ubicaciones asignadas.'),
  ('ingeniero_campo', 'Ingeniero de Campo', 'Consulta inventario de sus ubicaciones asignadas.'),
  ('almacen', 'Almacén', 'Opera inventario y ubicaciones de su empresa.'),
  ('punto_venta', 'Punto de Venta', 'Consulta productos y existencias locales.')
on conflict (code) do update set display_name = excluded.display_name, description = excluded.description;

insert into public.permissions (code, description) values
  ('manage_products', 'Crear y actualizar productos.'),
  ('manage_locations', 'Crear y actualizar ubicaciones.'),
  ('import_data', 'Confirmar importaciones de Alpha.'),
  ('view_import_audit', 'Consultar auditoría de importaciones.'),
  ('view_costs', 'Consultar costos cuando un módulo futuro los incorpore.')
on conflict (code) do update set description = excluded.description;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.code in ('super_admin', 'direccion_admin')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p on p.code = 'manage_locations'
where r.code = 'almacen'
on conflict do nothing;

-- These functions are SECURITY DEFINER so RLS checks do not recurse through RBAC tables.
create or replace function public.is_super_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.user_roles ur
    join public.roles r on r.id = ur.role_id
    where ur.user_id = auth.uid() and r.code = 'super_admin'
  );
$$;

create or replace function public.has_company_access(target_company_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_super_admin() or exists (
    select 1 from public.user_roles ur
    where ur.user_id = auth.uid() and ur.company_id = target_company_id
  );
$$;

create or replace function public.has_company_permission(target_company_id uuid, requested_permission text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_super_admin() or exists (
    select 1
    from public.user_roles ur
    join public.role_permissions rp on rp.role_id = ur.role_id
    join public.permissions p on p.id = rp.permission_id
    where ur.user_id = auth.uid()
      and ur.company_id = target_company_id
      and p.code = requested_permission
  );
$$;

create or replace function public.can_access_location(target_location_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_super_admin()
    or exists (
      select 1
      from public.locations l
      join public.user_roles ur on ur.company_id = l.company_id and ur.user_id = auth.uid()
      join public.roles r on r.id = ur.role_id
      where l.id = target_location_id and r.code in ('direccion_admin', 'almacen')
    )
    or exists (
      select 1 from public.user_location_access ula
      where ula.user_id = auth.uid() and ula.location_id = target_location_id
    );
$$;

create or replace function public.can_access_import_batch(target_batch_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.import_batches b
    where b.id = target_batch_id
      and public.has_company_permission(b.company_id, 'view_import_audit')
  );
$$;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger companies_set_updated_at before update on public.companies for each row execute procedure public.set_updated_at();
create trigger profiles_set_updated_at before update on public.profiles for each row execute procedure public.set_updated_at();
create trigger locations_set_updated_at before update on public.locations for each row execute procedure public.set_updated_at();
create trigger products_set_updated_at before update on public.products for each row execute procedure public.set_updated_at();
create trigger price_lists_set_updated_at before update on public.price_lists for each row execute procedure public.set_updated_at();
create trigger product_prices_set_updated_at before update on public.product_prices for each row execute procedure public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', new.email))
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

alter table public.companies enable row level security;
alter table public.profiles enable row level security;
alter table public.roles enable row level security;
alter table public.permissions enable row level security;
alter table public.role_permissions enable row level security;
alter table public.user_roles enable row level security;
alter table public.locations enable row level security;
alter table public.user_location_access enable row level security;
alter table public.products enable row level security;
alter table public.price_lists enable row level security;
alter table public.product_prices enable row level security;
alter table public.inventory_snapshots enable row level security;
alter table public.inventory_snapshot_items enable row level security;
alter table public.import_batches enable row level security;
alter table public.import_files enable row level security;
alter table public.import_errors enable row level security;
alter table public.audit_log enable row level security;

create policy companies_read on public.companies for select to authenticated using (public.has_company_access(id));
create policy companies_manage on public.companies for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());

create policy profiles_read on public.profiles for select to authenticated using (id = auth.uid() or public.is_super_admin());
create policy profiles_update on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy roles_read on public.roles for select to authenticated using (true);
create policy permissions_read on public.permissions for select to authenticated using (true);
create policy role_permissions_read on public.role_permissions for select to authenticated using (true);
create policy rbac_manage_roles on public.roles for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy rbac_manage_permissions on public.permissions for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy rbac_manage_role_permissions on public.role_permissions for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy user_roles_read on public.user_roles for select to authenticated using (user_id = auth.uid() or public.is_super_admin());
create policy user_roles_manage on public.user_roles for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());

create policy locations_read on public.locations for select to authenticated using (public.can_access_location(id));
create policy locations_write on public.locations for all to authenticated using (public.has_company_permission(company_id, 'manage_locations')) with check (public.has_company_permission(company_id, 'manage_locations'));
create policy location_access_read on public.user_location_access for select to authenticated using (user_id = auth.uid() or public.is_super_admin());
create policy location_access_manage on public.user_location_access for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());

create policy products_read on public.products for select to authenticated using (public.has_company_access(company_id));
create policy products_write on public.products for all to authenticated using (public.has_company_permission(company_id, 'manage_products')) with check (public.has_company_permission(company_id, 'manage_products'));
create policy price_lists_read on public.price_lists for select to authenticated using (public.has_company_access(company_id));
create policy price_lists_write on public.price_lists for all to authenticated using (public.has_company_permission(company_id, 'manage_products')) with check (public.has_company_permission(company_id, 'manage_products'));
create policy product_prices_read on public.product_prices for select to authenticated using (
  exists (select 1 from public.products p where p.id = product_id and public.has_company_access(p.company_id))
);
create policy product_prices_write on public.product_prices for all to authenticated using (
  exists (select 1 from public.products p where p.id = product_id and public.has_company_permission(p.company_id, 'manage_products'))
) with check (
  exists (select 1 from public.products p where p.id = product_id and public.has_company_permission(p.company_id, 'manage_products'))
);

create policy snapshots_read on public.inventory_snapshots for select to authenticated using (public.has_company_access(company_id));
create policy snapshots_write on public.inventory_snapshots for all to authenticated using (public.has_company_permission(company_id, 'import_data')) with check (public.has_company_permission(company_id, 'import_data'));
create policy inventory_items_read on public.inventory_snapshot_items for select to authenticated using (public.can_access_location(location_id));
create policy inventory_items_write on public.inventory_snapshot_items for all to authenticated using (
  exists (
    select 1 from public.inventory_snapshots s
    where s.id = snapshot_id and public.has_company_permission(s.company_id, 'import_data')
  )
) with check (
  exists (
    select 1 from public.inventory_snapshots s
    where s.id = snapshot_id and public.has_company_permission(s.company_id, 'import_data')
  )
);

create policy batches_read on public.import_batches for select to authenticated using (public.has_company_permission(company_id, 'view_import_audit'));
create policy batches_write on public.import_batches for all to authenticated using (public.has_company_permission(company_id, 'import_data')) with check (public.has_company_permission(company_id, 'import_data'));
create policy import_files_read on public.import_files for select to authenticated using (public.can_access_import_batch(import_batch_id));
create policy import_files_write on public.import_files for all to authenticated using (
  exists (select 1 from public.import_batches b where b.id = import_batch_id and public.has_company_permission(b.company_id, 'import_data'))
) with check (
  exists (select 1 from public.import_batches b where b.id = import_batch_id and public.has_company_permission(b.company_id, 'import_data'))
);
create policy import_errors_read on public.import_errors for select to authenticated using (public.can_access_import_batch(import_batch_id));
create policy import_errors_write on public.import_errors for all to authenticated using (
  exists (select 1 from public.import_batches b where b.id = import_batch_id and public.has_company_permission(b.company_id, 'import_data'))
) with check (
  exists (select 1 from public.import_batches b where b.id = import_batch_id and public.has_company_permission(b.company_id, 'import_data'))
);

create policy audit_read on public.audit_log for select to authenticated using (public.has_company_permission(company_id, 'view_import_audit'));
create policy audit_write on public.audit_log for insert to authenticated with check (public.has_company_permission(company_id, 'import_data'));

grant usage on schema public to authenticated;
grant select on public.companies, public.profiles, public.roles, public.permissions, public.role_permissions, public.user_roles, public.locations, public.user_location_access, public.products, public.price_lists, public.product_prices, public.inventory_snapshots, public.inventory_snapshot_items, public.import_batches, public.import_files, public.import_errors, public.audit_log to authenticated;
grant insert, update, delete on public.companies, public.roles, public.permissions, public.role_permissions, public.user_roles, public.locations, public.user_location_access, public.products, public.price_lists, public.product_prices, public.inventory_snapshots, public.inventory_snapshot_items, public.import_batches, public.import_files, public.import_errors to authenticated;
grant update (default_company_id) on public.profiles to authenticated;
grant insert on public.audit_log to authenticated;
grant execute on all functions in schema public to authenticated;
