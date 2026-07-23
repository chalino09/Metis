-- Satrapy · Module 1 hardening: location classification and traceable inventory facts.
-- Existing data is preserved; no business records are deleted or fabricated.

alter table public.locations
  add column if not exists classification_source text not null default 'legacy',
  add column if not exists classification_reviewed_at timestamptz,
  add column if not exists classification_reviewed_by uuid references auth.users(id) on delete set null;

-- Classify the existing Alpha locations deterministically. New/unrecognized values
-- are never auto-created by the application: they require manual review first.
update public.locations
set
  location_type = case
    when lower(external_code) = 'general' or lower(name) ~ 'almacen[[:space:]]+(general|central)|central' then 'almacen_central'
    when lower(name) ~ 'sucursal' or lower(external_code) ~ '^suc' then 'sucursal'
    when lower(name) ~ 'asesor|ingenier|campo' then 'campo'
    when lower(name) ~ 'almacen|bodega' then 'almacen_operativo'
    else 'pendiente_revision'
  end,
  classification_source = 'migration_rule',
  classification_reviewed_at = coalesce(classification_reviewed_at, now())
where location_type = 'almacen';

alter table public.locations
  alter column location_type set default 'pendiente_revision';

alter table public.locations
  drop constraint if exists locations_location_type_check;

alter table public.locations
  add constraint locations_location_type_check
  check (location_type in ('sucursal', 'almacen_central', 'almacen_operativo', 'campo', 'pendiente_revision'));

alter table public.locations
  drop constraint if exists locations_classification_source_check;

alter table public.locations
  add constraint locations_classification_source_check
  check (classification_source in ('legacy', 'migration_rule', 'alpha_rule', 'manual_review'));

alter table public.inventory_snapshot_items
  add column if not exists physical_quantity numeric(18, 6) not null default 0,
  add column if not exists available_quantity numeric(18, 6) not null default 0,
  add column if not exists reserved_quantity numeric(18, 6) not null default 0,
  add column if not exists field_assigned_quantity numeric(18, 6) not null default 0,
  add column if not exists in_transit_quantity numeric(18, 6) not null default 0,
  add column if not exists average_cost numeric(18, 6),
  add column if not exists reported_total_cost numeric(18, 6),
  add column if not exists alpha_class text,
  add column if not exists import_batch_id uuid references public.import_batches(id) on delete set null,
  add column if not exists source_file_name text;

-- Preserve old imports as a coherent initial snapshot while future imports persist
-- all fields directly from Alpha.
update public.inventory_snapshot_items item
set
  physical_quantity = item.quantity,
  available_quantity = case when location.location_type = 'campo' then 0 else item.quantity end,
  reserved_quantity = 0,
  field_assigned_quantity = case when location.location_type = 'campo' then item.quantity else 0 end,
  in_transit_quantity = 0,
  alpha_class = coalesce(item.alpha_class, product.alpha_class),
  import_batch_id = coalesce(item.import_batch_id, snapshot.import_batch_id),
  source_file_name = coalesce(item.source_file_name, snapshot.source_file_name)
from public.inventory_snapshots snapshot
  , public.locations location
  , public.products product
where snapshot.id = item.snapshot_id
  and location.id = item.location_id
  and product.id = item.product_id;

alter table public.inventory_snapshot_items
  drop constraint if exists inventory_snapshot_items_reserved_quantity_check,
  drop constraint if exists inventory_snapshot_items_field_assigned_quantity_check,
  drop constraint if exists inventory_snapshot_items_in_transit_quantity_check;

alter table public.inventory_snapshot_items
  add constraint inventory_snapshot_items_reserved_quantity_check check (reserved_quantity >= 0),
  add constraint inventory_snapshot_items_field_assigned_quantity_check check (field_assigned_quantity >= 0),
  add constraint inventory_snapshot_items_in_transit_quantity_check check (in_transit_quantity >= 0);

-- RLS protects which inventory rows can be read. PostgreSQL grants protect the
-- new sensitive cost columns, so a Punto de Venta cannot obtain them by asking
-- PostgREST for a different column list. A future cost module must expose costs
-- through an explicitly authorized view or RPC tied to view_costs.
revoke select on public.inventory_snapshot_items from authenticated;
grant select (
  id,
  snapshot_id,
  product_id,
  location_id,
  quantity,
  unit,
  imported_at,
  physical_quantity,
  available_quantity,
  reserved_quantity,
  field_assigned_quantity,
  in_transit_quantity,
  alpha_class,
  import_batch_id,
  source_file_name
) on public.inventory_snapshot_items to authenticated;

create index if not exists inventory_snapshots_company_effective_date_idx
  on public.inventory_snapshots(company_id, snapshot_date desc, created_at desc)
  where status = 'completed';

create index if not exists inventory_snapshot_items_import_batch_idx
  on public.inventory_snapshot_items(import_batch_id);

-- Compatibility backfill for the already-imported Alpha report: its export file
-- embeds the report date in reexic2_YYYYMMDD_*. New imports read the report header.
update public.inventory_snapshots
set snapshot_date = to_date(substring(source_file_name from 'reexic2_([0-9]{8})'), 'YYYYMMDD')
where snapshot_date is null
  and source_file_name ~* '^reexic2_[0-9]{8}_.*[.]xlsx?$';

-- A completed inventory snapshot without an effective Alpha date must not enter
-- the model. If an older custom record cannot be backfilled, correct it before
-- applying this migration instead of silently falling back to created_at.
alter table public.inventory_snapshots
  alter column snapshot_date set not null;
