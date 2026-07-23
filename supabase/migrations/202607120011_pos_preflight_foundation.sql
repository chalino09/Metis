-- Satrapy · POS preflight foundation
-- Alpha remains an import adapter. Products, locations, assortments and POS
-- queries use Satrapy's canonical UUIDs and durable external references.

insert into public.permissions (code, description) values
  ('manage_assortments', 'Crear, configurar y activar surtidos comerciales.'),
  ('view_pos_readiness', 'Consultar la preparación de productos para POS.')
on conflict (code) do update set description = excluded.description;

insert into public.role_permissions (role_id, permission_id)
select role_data.id, permission_data.id
from public.roles role_data
cross join public.permissions permission_data
where role_data.code in ('super_admin', 'direccion_admin')
  and permission_data.code in ('manage_assortments', 'view_pos_readiness')
on conflict do nothing;

create table if not exists public.product_external_references (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  source_system text not null check (length(trim(source_system)) > 0),
  external_code text not null check (length(trim(external_code)) > 0),
  is_primary boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, source_system, external_code)
);

create unique index if not exists product_external_references_primary_source_idx
  on public.product_external_references(product_id, source_system)
  where is_primary;
create index if not exists product_external_references_lookup_idx
  on public.product_external_references(company_id, external_code);

create table if not exists public.location_external_references (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete cascade,
  source_system text not null check (length(trim(source_system)) > 0),
  external_code text not null check (length(trim(external_code)) > 0),
  is_primary boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, source_system, external_code)
);

create unique index if not exists location_external_references_primary_source_idx
  on public.location_external_references(location_id, source_system)
  where is_primary;
create index if not exists location_external_references_lookup_idx
  on public.location_external_references(company_id, external_code);

create or replace function public.assert_external_reference_company_match()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entity_company_id uuid;
begin
  if tg_table_name = 'product_external_references' then
    select company_id into v_entity_company_id from public.products where id = new.product_id;
  else
    select company_id into v_entity_company_id from public.locations where id = new.location_id;
  end if;

  if v_entity_company_id is null or v_entity_company_id <> new.company_id then
    raise exception 'La referencia externa debe pertenecer a la misma empresa de su entidad.';
  end if;

  return new;
end;
$$;

create trigger product_external_references_company_match
  before insert or update on public.product_external_references
  for each row execute function public.assert_external_reference_company_match();
create trigger location_external_references_company_match
  before insert or update on public.location_external_references
  for each row execute function public.assert_external_reference_company_match();

-- Backfill only the existing compatibility data. Future consumers resolve these
-- references, not products.alpha_sku or locations.external_code directly.
insert into public.product_external_references (
  company_id, product_id, source_system, external_code, is_primary, metadata
)
select company_id, id, 'alpha', alpha_sku, true,
  jsonb_strip_nulls(jsonb_build_object('legacy_class', alpha_class))
from public.products
on conflict (company_id, source_system, external_code) do nothing;

insert into public.location_external_references (
  company_id, location_id, source_system, external_code, is_primary
)
select company_id, id, 'alpha', external_code, true
from public.locations
on conflict (company_id, source_system, external_code) do nothing;

create table if not exists public.sales_assortments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null check (length(trim(code)) > 0),
  name text not null check (length(trim(name)) > 0),
  status text not null default 'draft' check (status in ('draft', 'active', 'inactive')),
  valid_from timestamptz,
  valid_to timestamptz,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (valid_to is null or valid_from is null or valid_to > valid_from),
  unique (company_id, code)
);

create table if not exists public.sales_assortment_items (
  assortment_id uuid not null references public.sales_assortments(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  primary key (assortment_id, product_id)
);

create table if not exists public.location_sales_assortments (
  id uuid primary key default gen_random_uuid(),
  location_id uuid not null references public.locations(id) on delete cascade,
  assortment_id uuid not null references public.sales_assortments(id) on delete cascade,
  valid_from timestamptz not null default now(),
  valid_to timestamptz,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (valid_to is null or valid_to > valid_from),
  unique (location_id, assortment_id, valid_from)
);

create unique index if not exists location_sales_assortments_current_idx
  on public.location_sales_assortments(location_id, assortment_id)
  where valid_to is null;
create index if not exists sales_assortment_items_product_idx
  on public.sales_assortment_items(product_id);
create index if not exists location_sales_assortments_location_validity_idx
  on public.location_sales_assortments(location_id, valid_from, valid_to);

create trigger product_external_references_set_updated_at
  before update on public.product_external_references
  for each row execute procedure public.set_updated_at();
create trigger location_external_references_set_updated_at
  before update on public.location_external_references
  for each row execute procedure public.set_updated_at();
create trigger sales_assortments_set_updated_at
  before update on public.sales_assortments
  for each row execute procedure public.set_updated_at();
create trigger location_sales_assortments_set_updated_at
  before update on public.location_sales_assortments
  for each row execute procedure public.set_updated_at();

create or replace function public.assert_sales_assortment_company_match()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_assortment_company_id uuid;
  v_related_company_id uuid;
begin
  select company_id into v_assortment_company_id
  from public.sales_assortments
  where id = new.assortment_id;

  if not found then
    raise exception 'Surtido no encontrado.';
  end if;

  if tg_table_name = 'sales_assortment_items' then
    select company_id into v_related_company_id from public.products where id = new.product_id;
  else
    select company_id into v_related_company_id from public.locations where id = new.location_id;
  end if;

  if v_related_company_id is null or v_related_company_id <> v_assortment_company_id then
    raise exception 'Producto o ubicación debe pertenecer a la misma empresa del surtido.';
  end if;

  return new;
end;
$$;

create trigger sales_assortment_items_company_match
  before insert or update on public.sales_assortment_items
  for each row execute function public.assert_sales_assortment_company_match();
create trigger location_sales_assortments_company_match
  before insert or update on public.location_sales_assortments
  for each row execute function public.assert_sales_assortment_company_match();

create or replace function public.product_pos_readiness_detail(
  p_company_id uuid,
  p_product_id uuid,
  p_price_list_id uuid default null,
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_product public.products%rowtype;
  v_policy text;
  v_default_price_list_id uuid;
  v_price_list_id uuid;
  v_price numeric;
  v_currency text;
  v_has_tax boolean;
  v_has_cost boolean;
  v_blockers jsonb;
  v_warnings jsonb;
begin
  if auth.uid() is null or not public.has_company_access(p_company_id) then
    raise exception 'No autorizado.';
  end if;

  select * into v_product
  from public.products
  where id = p_product_id and company_id = p_company_id;

  if not found then
    raise exception 'Producto no encontrado.';
  end if;

  select default_price_policy, default_price_list_id
  into v_policy, v_default_price_list_id
  from public.companies
  where id = p_company_id;

  v_price_list_id := coalesce(
    p_price_list_id,
    case when v_policy = 'specific_list' then v_default_price_list_id else null end
  );

  select price.amount, price.currency_code
  into v_price, v_currency
  from public.product_prices price
  where price.product_id = p_product_id
    and price.valid_from <= p_at
    and (price.valid_to is null or price.valid_to > p_at)
    and (v_price_list_id is null or price.price_list_id = v_price_list_id)
  order by
    case when v_price_list_id is null then price.amount end desc nulls last,
    price.valid_from desc
  limit 1;

  select exists (
    select 1
    from public.tax_rates rate
    where rate.tax_category_id = v_product.tax_category_id
      and rate.valid_from <= p_at
      and (rate.valid_to is null or rate.valid_to > p_at)
  ) into v_has_tax;

  select exists (
    select 1
    from public.product_costs cost
    where cost.company_id = p_company_id
      and cost.product_id = p_product_id
      and cost.valid_from <= p_at
      and (cost.valid_to is null or cost.valid_to > p_at)
  ) into v_has_cost;

  select coalesce(jsonb_agg(check_data.code), '[]'::jsonb)
  into v_blockers
  from (
    values
      ('inactive'::text, not v_product.is_active),
      ('not_sellable'::text, not v_product.is_sellable),
      ('commercial_review_required'::text, v_product.commercial_review_required),
      ('missing_sales_unit'::text, v_product.sales_unit_id is null),
      ('missing_tax_category'::text, v_product.tax_category_id is null),
      ('missing_current_tax_rate'::text, not coalesce(v_has_tax, false)),
      ('missing_or_zero_price'::text, coalesce(v_price, 0) <= 0)
  ) as check_data(code, is_blocked)
  where check_data.is_blocked;

  v_warnings := case
    when v_has_cost then '[]'::jsonb
    else jsonb_build_array('missing_current_cost')
  end;

  return jsonb_build_object(
    'product_id', v_product.id,
    'is_active', v_product.is_active,
    'is_sellable', v_product.is_sellable,
    'sales_unit_valid', v_product.sales_unit_id is not null,
    'tax_configured', v_product.tax_category_id is not null and coalesce(v_has_tax, false),
    'price_configured', coalesce(v_price, 0) > 0,
    'price_amount', v_price,
    'currency_code', v_currency,
    'classification_resolved', not v_product.commercial_review_required,
    'cost_available_for_margin', case when public.has_company_permission(p_company_id, 'view_costs') then v_has_cost else null end,
    'blockers', v_blockers,
    'warnings', v_warnings,
    'pos_ready', jsonb_array_length(v_blockers) = 0
  );
end;
$$;

create or replace function public.enforce_sales_assortment_activation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item_count integer;
  v_blocked_count integer;
begin
  if new.status <> 'active' then
    return new;
  end if;

  select count(*) into v_item_count
  from public.sales_assortment_items
  where assortment_id = new.id;

  if v_item_count = 0 then
    raise exception 'No se puede activar un surtido sin productos.';
  end if;

  select count(*) into v_blocked_count
  from public.sales_assortment_items item
  cross join lateral public.product_pos_readiness_detail(new.company_id, item.product_id) readiness
  where item.assortment_id = new.id
    and coalesce((readiness ->> 'pos_ready')::boolean, false) = false;

  if v_blocked_count > 0 then
    raise exception 'No se puede activar el surtido: % productos no están listos para POS.', v_blocked_count;
  end if;

  return new;
end;
$$;

create trigger sales_assortments_activation_guard
  before insert or update of status on public.sales_assortments
  for each row execute function public.enforce_sales_assortment_activation();

create or replace function public.get_pos_readiness_overview(
  p_company_id uuid,
  p_assortment_id uuid default null,
  p_page integer default 1,
  p_page_size integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 100), 1), 250);
  v_total integer;
  v_ready integer;
  v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_pos_readiness') then
    raise exception 'No autorizado para consultar la preparación POS.';
  end if;

  if p_assortment_id is not null and not exists (
    select 1 from public.sales_assortments
    where id = p_assortment_id and company_id = p_company_id
  ) then
    raise exception 'Surtido no encontrado.';
  end if;

  with scoped_products as (
    select product.id, product.name, product.internal_sku, product.unit
    from public.products product
    where product.company_id = p_company_id
      and (
        p_assortment_id is null
        or exists (
          select 1 from public.sales_assortment_items item
          where item.assortment_id = p_assortment_id and item.product_id = product.id
        )
      )
  ), detailed as (
    select scoped_products.*, readiness,
      coalesce(
        scoped_products.internal_sku,
        (
          select reference.external_code
          from public.product_external_references reference
          where reference.product_id = scoped_products.id
          order by reference.is_primary desc, reference.created_at asc
          limit 1
        )
      ) as display_code
    from scoped_products
    cross join lateral public.product_pos_readiness_detail(p_company_id, scoped_products.id) readiness
  )
  select count(*), count(*) filter (where coalesce((readiness ->> 'pos_ready')::boolean, false))
  into v_total, v_ready
  from detailed;

  with scoped_products as (
    select product.id, product.name, product.internal_sku, product.unit
    from public.products product
    where product.company_id = p_company_id
      and (
        p_assortment_id is null
        or exists (
          select 1 from public.sales_assortment_items item
          where item.assortment_id = p_assortment_id and item.product_id = product.id
        )
      )
  ), detailed as (
    select scoped_products.*, readiness,
      coalesce(
        scoped_products.internal_sku,
        (
          select reference.external_code
          from public.product_external_references reference
          where reference.product_id = scoped_products.id
          order by reference.is_primary desc, reference.created_at asc
          limit 1
        )
      ) as display_code
    from scoped_products
    cross join lateral public.product_pos_readiness_detail(p_company_id, scoped_products.id) readiness
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'product_id', id,
    'code', display_code,
    'name', name,
    'unit', unit,
    'pos_ready', coalesce((readiness ->> 'pos_ready')::boolean, false),
    'blockers', readiness -> 'blockers',
    'warnings', readiness -> 'warnings',
    'price_amount', readiness -> 'price_amount',
    'currency_code', readiness -> 'currency_code'
  ) order by pos_ready desc, name), '[]'::jsonb)
  into v_items
  from (
    select * from detailed
    order by coalesce((readiness ->> 'pos_ready')::boolean, false) desc, name
    limit v_size offset (v_page - 1) * v_size
  ) paged;

  return jsonb_build_object(
    'summary', jsonb_build_object(
      'total', coalesce(v_total, 0),
      'ready', coalesce(v_ready, 0),
      'blocked', greatest(coalesce(v_total, 0) - coalesce(v_ready, 0), 0)
    ),
    'items', v_items,
    'page', v_page,
    'page_size', v_size
  );
end;
$$;

-- Keep Alpha-specific parsing at the boundary, but resolve inventory facts with
-- durable external references before they reach the canonical model.
create or replace function public.confirm_staged_import(p_import_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch public.import_batches%rowtype;
  v_file_name text;
  v_snapshot_id uuid;
  v_records integer := 0;
  v_error text;
  v_duplicate uuid;
begin
  select * into v_batch from public.import_batches where id = p_import_batch_id for update;
  if not found then raise exception 'Lote de importación no encontrado.'; end if;
  if auth.uid() is null or not public.has_company_permission(v_batch.company_id, 'import_data') then
    raise exception 'No autorizado.';
  end if;
  if v_batch.status = 'completed' then
    return jsonb_build_object('status', 'completed', 'records_imported', v_batch.records_imported, 'batch_id', v_batch.id);
  end if;

  perform public.refresh_import_staging_batch(p_import_batch_id, false);
  select * into v_batch from public.import_batches where id = p_import_batch_id;
  if v_batch.blocking_error_count > 0 or v_batch.pending_warning_count > 0 then
    insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
    values (v_batch.company_id, auth.uid(), 'import.confirmation_blocked', 'import_batch', p_import_batch_id,
      jsonb_build_object('blocking_errors', v_batch.blocking_error_count, 'pending_warnings', v_batch.pending_warning_count));
    return jsonb_build_object('status', 'validation_failed', 'message', 'Resuelve errores y reconoce warnings antes de confirmar.');
  end if;
  if v_batch.status <> 'staged' then
    return jsonb_build_object('status', v_batch.status, 'message', 'El lote no está listo.');
  end if;

  select id into v_duplicate from public.import_batches
  where company_id = v_batch.company_id
    and import_type = v_batch.import_type
    and file_sha256 = v_batch.file_sha256
    and status = 'completed'
    and id <> v_batch.id
  limit 1;
  if v_duplicate is not null then return jsonb_build_object('status', 'duplicate', 'batch_id', v_duplicate); end if;

  select original_name into v_file_name from public.import_files
  where import_batch_id = p_import_batch_id
  order by created_at
  limit 1;

  begin
    if v_batch.import_type = 'products' then
      -- alpha_sku remains a compatibility value only. The canonical cross-source
      -- identity is registered immediately after the upsert.
      insert into public.products (company_id, alpha_sku, alpha_class, name, attribute, unit, product_group, subgroup, product_type)
      select v_batch.company_id, row_data.normalized_data ->> 'alphaSku', nullif(row_data.normalized_data ->> 'alphaClass', ''),
        row_data.normalized_data ->> 'name', nullif(row_data.normalized_data ->> 'attribute', ''),
        nullif(row_data.normalized_data ->> 'unit', ''), nullif(row_data.normalized_data ->> 'productGroup', ''),
        nullif(row_data.normalized_data ->> 'subgroup', ''), nullif(row_data.normalized_data ->> 'productType', '')
      from public.import_staging_rows row_data
      where row_data.import_batch_id = p_import_batch_id
        and row_data.detected_type = 'products'
        and coalesce((row_data.normalized_data ->> 'rejected')::boolean, false) = false
      on conflict (company_id, alpha_sku) do update set
        alpha_class = excluded.alpha_class,
        name = excluded.name,
        attribute = excluded.attribute,
        unit = excluded.unit,
        product_group = excluded.product_group,
        subgroup = excluded.subgroup,
        product_type = excluded.product_type;
      get diagnostics v_records = row_count;

      insert into public.product_external_references (company_id, product_id, source_system, external_code, is_primary, metadata)
      select distinct v_batch.company_id, product.id, 'alpha', row_data.normalized_data ->> 'alphaSku', true,
        jsonb_strip_nulls(jsonb_build_object('legacy_class', nullif(row_data.normalized_data ->> 'alphaClass', '')))
      from public.import_staging_rows row_data
      join public.products product on product.company_id = v_batch.company_id
        and product.alpha_sku = row_data.normalized_data ->> 'alphaSku'
      where row_data.import_batch_id = p_import_batch_id
        and row_data.detected_type = 'products'
        and coalesce((row_data.normalized_data ->> 'rejected')::boolean, false) = false
      on conflict (company_id, source_system, external_code) do update set
        product_id = excluded.product_id,
        is_primary = true,
        metadata = excluded.metadata,
        updated_at = now();

    elsif v_batch.import_type = 'inventory' then
      if v_batch.snapshot_date is null then raise exception 'El reporte no tiene fecha efectiva.'; end if;
      if exists (
        select 1 from public.import_staging_rows row_data
        where row_data.import_batch_id = p_import_batch_id
          and row_data.detected_type = 'inventory'
          and coalesce((row_data.normalized_data ->> 'rejected')::boolean, false) = false
          and nullif(row_data.normalized_data ->> 'locationType', '') is null
      ) then raise exception 'Existen ubicaciones sin clasificación.'; end if;
      if exists (
        select 1 from public.import_staging_rows row_data
        where row_data.import_batch_id = p_import_batch_id
          and row_data.detected_type = 'inventory'
          and coalesce((row_data.normalized_data ->> 'rejected')::boolean, false) = false
          and row_data.resolved_product_id is null
          and not exists (
            select 1
            from public.product_external_references reference
            join public.products product on product.id = reference.product_id and product.is_active
            where reference.company_id = v_batch.company_id
              and reference.source_system = 'alpha'
              and reference.external_code = row_data.normalized_data ->> 'alphaSku'
          )
      ) then raise exception 'Existen existencias sin producto válido.'; end if;

      insert into public.locations (company_id, external_code, name, location_type, classification_source,
        classification_reviewed_at, classification_reviewed_by, is_active)
      select distinct v_batch.company_id, row_data.normalized_data ->> 'locationCode', row_data.normalized_data ->> 'locationName',
        row_data.normalized_data ->> 'locationType', coalesce(nullif(row_data.normalized_data ->> 'classificationSource', ''), 'manual_review'),
        now(), case when row_data.normalized_data ->> 'classificationSource' = 'manual_review' then auth.uid() else null end, true
      from public.import_staging_rows row_data
      where row_data.import_batch_id = p_import_batch_id
        and row_data.detected_type = 'inventory'
        and coalesce((row_data.normalized_data ->> 'rejected')::boolean, false) = false
      on conflict (company_id, external_code) do nothing;

      insert into public.location_external_references (company_id, location_id, source_system, external_code, is_primary)
      select distinct v_batch.company_id, location.id, 'alpha', row_data.normalized_data ->> 'locationCode', true
      from public.import_staging_rows row_data
      join public.locations location on location.company_id = v_batch.company_id
        and location.external_code = row_data.normalized_data ->> 'locationCode'
      where row_data.import_batch_id = p_import_batch_id
        and row_data.detected_type = 'inventory'
        and coalesce((row_data.normalized_data ->> 'rejected')::boolean, false) = false
      on conflict (company_id, source_system, external_code) do update set
        location_id = excluded.location_id,
        is_primary = true,
        updated_at = now();

      insert into public.inventory_snapshots (company_id, import_batch_id, source_file_name, snapshot_date, status, created_by)
      values (v_batch.company_id, p_import_batch_id, v_file_name, v_batch.snapshot_date, 'completed', auth.uid())
      returning id into v_snapshot_id;

      insert into public.inventory_snapshot_items (snapshot_id, product_id, location_id, quantity, unit, physical_quantity,
        available_quantity, reserved_quantity, field_assigned_quantity, in_transit_quantity, average_cost,
        reported_total_cost, alpha_class, import_batch_id, source_file_name, source_alpha_sku, product_mapping_applied)
      select v_snapshot_id, product.id, location.id, (row_data.normalized_data ->> 'quantity')::numeric,
        nullif(row_data.normalized_data ->> 'unit', ''), (row_data.normalized_data ->> 'quantity')::numeric,
        case when location.location_type = 'campo' then 0 else (row_data.normalized_data ->> 'quantity')::numeric end,
        0, case when location.location_type = 'campo' then (row_data.normalized_data ->> 'quantity')::numeric else 0 end, 0,
        case when nullif(row_data.normalized_data ->> 'reportedValue', '') is not null
          and (row_data.normalized_data ->> 'quantity')::numeric <> 0
          then (row_data.normalized_data ->> 'reportedValue')::numeric / (row_data.normalized_data ->> 'quantity')::numeric
          else nullif(row_data.normalized_data ->> 'replacementCost', '')::numeric end,
        nullif(row_data.normalized_data ->> 'reportedValue', '')::numeric,
        nullif(row_data.normalized_data ->> 'alphaClass', ''), p_import_batch_id, v_file_name,
        row_data.normalized_data ->> 'alphaSku', row_data.resolved_product_id is not null
      from public.import_staging_rows row_data
      join public.products product on product.company_id = v_batch.company_id
        and product.is_active
        and (
          (row_data.resolved_product_id is not null and product.id = row_data.resolved_product_id)
          or (
            row_data.resolved_product_id is null
            and exists (
              select 1 from public.product_external_references reference
              where reference.company_id = v_batch.company_id
                and reference.product_id = product.id
                and reference.source_system = 'alpha'
                and reference.external_code = row_data.normalized_data ->> 'alphaSku'
            )
          )
        )
      join public.location_external_references location_reference on location_reference.company_id = v_batch.company_id
        and location_reference.source_system = 'alpha'
        and location_reference.external_code = row_data.normalized_data ->> 'locationCode'
      join public.locations location on location.id = location_reference.location_id
      where row_data.import_batch_id = p_import_batch_id
        and row_data.detected_type = 'inventory'
        and coalesce((row_data.normalized_data ->> 'rejected')::boolean, false) = false;
      get diagnostics v_records = row_count;
    else
      raise exception 'Tipo de archivo no compatible.';
    end if;

    update public.import_batches
    set status = 'completed', records_imported = v_records, completed_at = now(), closed_at = now(), last_activity_at = now(), notes = null
    where id = p_import_batch_id;
    insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
    values (v_batch.company_id, auth.uid(), 'import.completed', 'import_batch', p_import_batch_id,
      jsonb_build_object('import_type', v_batch.import_type, 'records_imported', v_records,
        'original_name', v_file_name, 'snapshot_date', v_batch.snapshot_date));
  exception when others then
    v_error := sqlerrm;
  end;

  if v_error is not null then
    update public.import_batches
    set status = 'failed', completed_at = now(), closed_at = now(), last_activity_at = now(), notes = v_error
    where id = p_import_batch_id;
    insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
    values (v_batch.company_id, auth.uid(), 'import.failed', 'import_batch', p_import_batch_id,
      jsonb_build_object('import_type', v_batch.import_type, 'original_name', v_file_name, 'error', v_error));
    return jsonb_build_object('status', 'failed', 'message', v_error, 'batch_id', p_import_batch_id);
  end if;

  return jsonb_build_object('status', 'completed', 'records_imported', v_records, 'batch_id', v_batch.id);
end;
$$;

create or replace function public.search_assortment_products(
  p_company_id uuid,
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 20), 1), 100);
  v_query text := lower(trim(coalesce(p_query, '')));
  v_total integer;
  v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_assortments') then
    raise exception 'No autorizado para configurar surtidos.';
  end if;

  with filtered as (
    select product.id, product.name,
      coalesce(product.internal_sku, (
        select reference.external_code
        from public.product_external_references reference
        where reference.product_id = product.id
        order by reference.is_primary desc, reference.created_at asc
        limit 1
      )) as code
    from public.products product
    where product.company_id = p_company_id
      and (
        v_query = ''
        or lower(product.name) like '%' || v_query || '%'
        or lower(coalesce(product.internal_sku, '')) like '%' || v_query || '%'
        or lower(coalesce(product.barcode, '')) = v_query
        or exists (
          select 1 from public.product_aliases alias
          where alias.product_id = product.id
            and lower(alias.normalized_value) like '%' || v_query || '%'
        )
        or exists (
          select 1 from public.product_external_references reference
          where reference.product_id = product.id
            and lower(reference.external_code) like '%' || v_query || '%'
        )
      )
  )
  select count(*) into v_total from filtered;

  with filtered as (
    select product.id, product.name,
      coalesce(product.internal_sku, (
        select reference.external_code
        from public.product_external_references reference
        where reference.product_id = product.id
        order by reference.is_primary desc, reference.created_at asc
        limit 1
      )) as code
    from public.products product
    where product.company_id = p_company_id
      and (
        v_query = ''
        or lower(product.name) like '%' || v_query || '%'
        or lower(coalesce(product.internal_sku, '')) like '%' || v_query || '%'
        or lower(coalesce(product.barcode, '')) = v_query
        or exists (
          select 1 from public.product_aliases alias
          where alias.product_id = product.id
            and lower(alias.normalized_value) like '%' || v_query || '%'
        )
        or exists (
          select 1 from public.product_external_references reference
          where reference.product_id = product.id
            and lower(reference.external_code) like '%' || v_query || '%'
        )
      )
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'code', code, 'name', name) order by name), '[]'::jsonb)
  into v_items
  from (
    select * from filtered
    order by name
    limit v_size offset (v_page - 1) * v_size
  ) paged;

  return jsonb_build_object('items', v_items, 'total', coalesce(v_total, 0), 'page', v_page, 'page_size', v_size);
end;
$$;

create or replace function public.search_pos_products(
  p_company_id uuid,
  p_location_id uuid,
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 50,
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 50), 1), 100);
  v_query text := lower(trim(coalesce(p_query, '')));
  v_total integer;
  v_items jsonb;
begin
  if auth.uid() is null or not public.can_access_location(p_location_id) then
    raise exception 'No autorizado para consultar esta ubicación.';
  end if;

  if not exists (
    select 1 from public.locations
    where id = p_location_id and company_id = p_company_id
  ) then
    raise exception 'Ubicación no encontrada.';
  end if;

  with eligible_products as (
    select distinct product.id, product.name, product.internal_sku, product.barcode, product.unit
    from public.sales_assortment_items item
    join public.sales_assortments assortment on assortment.id = item.assortment_id
    join public.location_sales_assortments assignment on assignment.assortment_id = assortment.id
    join public.products product on product.id = item.product_id
    cross join lateral public.product_pos_readiness_detail(p_company_id, product.id, null, p_at) readiness
    where assignment.location_id = p_location_id
      and assignment.valid_from <= p_at
      and (assignment.valid_to is null or assignment.valid_to > p_at)
      and assortment.status = 'active'
      and (assortment.valid_from is null or assortment.valid_from <= p_at)
      and (assortment.valid_to is null or assortment.valid_to > p_at)
      and product.company_id = p_company_id
      and coalesce((readiness ->> 'pos_ready')::boolean, false)
      and (
        v_query = ''
        or lower(product.name) like '%' || v_query || '%'
        or lower(coalesce(product.internal_sku, '')) like '%' || v_query || '%'
        or lower(coalesce(product.barcode, '')) = v_query
        or exists (
          select 1 from public.product_aliases alias
          where alias.product_id = product.id
            and lower(alias.normalized_value) like '%' || v_query || '%'
        )
        or exists (
          select 1 from public.product_external_references reference
          where reference.product_id = product.id
            and lower(reference.external_code) like '%' || v_query || '%'
        )
      )
  )
  select count(*) into v_total from eligible_products;

  with eligible_products as (
    select distinct product.id, product.name, product.internal_sku, product.barcode, product.unit,
      public.resolve_product_sale_price(p_company_id, product.id, null, p_at) as price
    from public.sales_assortment_items item
    join public.sales_assortments assortment on assortment.id = item.assortment_id
    join public.location_sales_assortments assignment on assignment.assortment_id = assortment.id
    join public.products product on product.id = item.product_id
    cross join lateral public.product_pos_readiness_detail(p_company_id, product.id, null, p_at) readiness
    where assignment.location_id = p_location_id
      and assignment.valid_from <= p_at
      and (assignment.valid_to is null or assignment.valid_to > p_at)
      and assortment.status = 'active'
      and (assortment.valid_from is null or assortment.valid_from <= p_at)
      and (assortment.valid_to is null or assortment.valid_to > p_at)
      and product.company_id = p_company_id
      and coalesce((readiness ->> 'pos_ready')::boolean, false)
      and (
        v_query = ''
        or lower(product.name) like '%' || v_query || '%'
        or lower(coalesce(product.internal_sku, '')) like '%' || v_query || '%'
        or lower(coalesce(product.barcode, '')) = v_query
        or exists (
          select 1 from public.product_aliases alias
          where alias.product_id = product.id
            and lower(alias.normalized_value) like '%' || v_query || '%'
        )
        or exists (
          select 1 from public.product_external_references reference
          where reference.product_id = product.id
            and lower(reference.external_code) like '%' || v_query || '%'
        )
      )
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'product_id', id,
    'code', coalesce(internal_sku, (
      select reference.external_code
      from public.product_external_references reference
      where reference.product_id = paged.id
      order by reference.is_primary desc, reference.created_at asc
      limit 1
    )),
    'name', name,
    'unit', unit,
    'price_amount', price -> 'amount',
    'currency_code', price -> 'currency_code'
  ) order by name), '[]'::jsonb)
  into v_items
  from (
    select * from eligible_products
    order by name
    limit v_size offset (v_page - 1) * v_size
  ) paged;

  return jsonb_build_object('items', v_items, 'total', coalesce(v_total, 0), 'page', v_page, 'page_size', v_size);
end;
$$;

create or replace function public.validate_pos_product_for_location(
  p_company_id uuid,
  p_location_id uuid,
  p_product_id uuid,
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_readiness jsonb;
  v_in_assortment boolean;
begin
  if auth.uid() is null or not public.can_access_location(p_location_id) then
    raise exception 'No autorizado para esta ubicación.';
  end if;

  if not exists (
    select 1 from public.locations
    where id = p_location_id and company_id = p_company_id
  ) or not exists (
    select 1 from public.products
    where id = p_product_id and company_id = p_company_id
  ) then
    raise exception 'Producto o ubicación no encontrados.';
  end if;

  select exists (
    select 1
    from public.sales_assortment_items item
    join public.sales_assortments assortment on assortment.id = item.assortment_id
    join public.location_sales_assortments assignment on assignment.assortment_id = assortment.id
    where item.product_id = p_product_id
      and assignment.location_id = p_location_id
      and assignment.valid_from <= p_at
      and (assignment.valid_to is null or assignment.valid_to > p_at)
      and assortment.status = 'active'
      and (assortment.valid_from is null or assortment.valid_from <= p_at)
      and (assortment.valid_to is null or assortment.valid_to > p_at)
  ) into v_in_assortment;

  v_readiness := public.product_pos_readiness_detail(p_company_id, p_product_id, null, p_at);

  return jsonb_build_object(
    'allowed', v_in_assortment and coalesce((v_readiness ->> 'pos_ready')::boolean, false),
    'in_active_assortment', v_in_assortment,
    'readiness', v_readiness
  );
end;
$$;

create or replace function public.audit_pos_preflight_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_entity_id uuid;
  v_action text;
begin
  case tg_table_name
    when 'product_external_references' then
      if tg_op = 'DELETE' then
        v_company_id := old.company_id;
        v_entity_id := old.id;
      else
        v_company_id := new.company_id;
        v_entity_id := new.id;
      end if;
    when 'location_external_references' then
      if tg_op = 'DELETE' then
        v_company_id := old.company_id;
        v_entity_id := old.id;
      else
        v_company_id := new.company_id;
        v_entity_id := new.id;
      end if;
    when 'sales_assortments' then
      if tg_op = 'DELETE' then
        v_company_id := old.company_id;
        v_entity_id := old.id;
      else
        v_company_id := new.company_id;
        v_entity_id := new.id;
      end if;
    when 'sales_assortment_items' then
      select company_id into v_company_id from public.sales_assortments
      where id = case when tg_op = 'DELETE' then old.assortment_id else new.assortment_id end;
      v_entity_id := case when tg_op = 'DELETE' then old.product_id else new.product_id end;
    when 'location_sales_assortments' then
      select company_id into v_company_id from public.sales_assortments
      where id = case when tg_op = 'DELETE' then old.assortment_id else new.assortment_id end;
      v_entity_id := case when tg_op = 'DELETE' then old.id else new.id end;
    when 'tax_categories' then
      if tg_op = 'DELETE' then
        v_company_id := old.company_id;
        v_entity_id := old.id;
      else
        v_company_id := new.company_id;
        v_entity_id := new.id;
      end if;
    when 'tax_rates' then
      select company_id into v_company_id from public.tax_categories
      where id = case when tg_op = 'DELETE' then old.tax_category_id else new.tax_category_id end;
      v_entity_id := case when tg_op = 'DELETE' then old.id else new.id end;
  end case;

  v_action := case tg_op
    when 'INSERT' then tg_table_name || '.created'
    when 'DELETE' then tg_table_name || '.deleted'
    else tg_table_name || '.updated'
  end;

  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values (
    v_company_id,
    auth.uid(),
    v_action,
    tg_table_name,
    v_entity_id,
    jsonb_build_object('operation', tg_op)
  );

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create trigger product_external_references_audit
  after insert or update or delete on public.product_external_references
  for each row execute function public.audit_pos_preflight_change();
create trigger location_external_references_audit
  after insert or update or delete on public.location_external_references
  for each row execute function public.audit_pos_preflight_change();
create trigger sales_assortments_audit
  after insert or update or delete on public.sales_assortments
  for each row execute function public.audit_pos_preflight_change();
create trigger sales_assortment_items_audit
  after insert or update or delete on public.sales_assortment_items
  for each row execute function public.audit_pos_preflight_change();
create trigger location_sales_assortments_audit
  after insert or update or delete on public.location_sales_assortments
  for each row execute function public.audit_pos_preflight_change();
create trigger tax_categories_audit
  after insert or update or delete on public.tax_categories
  for each row execute function public.audit_pos_preflight_change();
create trigger tax_rates_audit
  after insert or update or delete on public.tax_rates
  for each row execute function public.audit_pos_preflight_change();

create or replace function public.list_import_audit(
  p_company_id uuid,
  p_page integer default 1,
  p_page_size integer default 50,
  p_import_type text default null,
  p_status text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 50), 1), 100);
  v_total integer;
  v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_import_audit') then
    raise exception 'No autorizado para consultar auditoría.';
  end if;

  select count(*) into v_total
  from public.import_batches batch
  where batch.company_id = p_company_id
    and (p_import_type is null or batch.import_type = p_import_type)
    and (p_status is null or batch.status = p_status);

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', audit_data.id,
    'import_type', audit_data.import_type,
    'status', audit_data.status,
    'source', audit_data.source,
    'started_at', audit_data.started_at,
    'completed_at', audit_data.completed_at,
    'records_received', audit_data.records_received,
    'records_imported', audit_data.records_imported,
    'actor_id', audit_data.actor_id,
    'actor_name', audit_data.actor_name,
    'files', audit_data.files,
    'issue_count', audit_data.issue_count,
    'error_summary', audit_data.error_summary
  ) order by audit_data.started_at desc), '[]'::jsonb)
  into v_items
  from (
    select
      batch.id,
      batch.import_type,
      batch.status,
      batch.source,
      batch.started_at,
      batch.completed_at,
      batch.records_received,
      batch.records_imported,
      coalesce(event_data.actor_id, batch.imported_by) as actor_id,
      coalesce(actor.full_name, 'Sistema') as actor_name,
      coalesce(file_data.files, '[]'::jsonb) as files,
      greatest(batch.error_rows, coalesce(issue_data.issue_count, 0)) as issue_count,
      batch.error_summary
    from public.import_batches batch
    left join lateral (
      select log.actor_id
      from public.audit_log log
      where log.entity_type = 'import_batch'
        and log.entity_id = batch.id
        and log.action in ('import.completed', 'price.imported', 'cost.imported', 'import.failed')
      order by log.created_at desc
      limit 1
    ) event_data on true
    left join public.profiles actor on actor.id = coalesce(event_data.actor_id, batch.imported_by)
    left join lateral (
      select jsonb_agg(jsonb_build_object('original_name', file.original_name, 'file_type', file.file_type, 'row_count', file.row_count)) as files
      from public.import_files file
      where file.import_batch_id = batch.id
    ) file_data on true
    left join lateral (
      select count(*)::integer as issue_count
      from public.import_staging_errors issue
      where issue.import_batch_id = batch.id
    ) issue_data on true
    where batch.company_id = p_company_id
      and (p_import_type is null or batch.import_type = p_import_type)
      and (p_status is null or batch.status = p_status)
    order by batch.started_at desc
    limit v_size offset (v_page - 1) * v_size
  ) audit_data;

  return jsonb_build_object('items', v_items, 'total', coalesce(v_total, 0), 'page', v_page, 'page_size', v_size);
end;
$$;

alter table public.product_external_references enable row level security;
alter table public.location_external_references enable row level security;
alter table public.sales_assortments enable row level security;
alter table public.sales_assortment_items enable row level security;
alter table public.location_sales_assortments enable row level security;

create policy product_external_references_read on public.product_external_references
  for select to authenticated using (public.has_company_access(company_id));
create policy product_external_references_manage on public.product_external_references
  for all to authenticated
  using (public.has_company_permission(company_id, 'manage_products'))
  with check (public.has_company_permission(company_id, 'manage_products'));
create policy location_external_references_read on public.location_external_references
  for select to authenticated using (public.can_access_location(location_id));
create policy location_external_references_manage on public.location_external_references
  for all to authenticated
  using (public.has_company_permission(company_id, 'manage_locations'))
  with check (public.has_company_permission(company_id, 'manage_locations'));
create policy sales_assortments_read on public.sales_assortments
  for select to authenticated using (public.has_company_permission(company_id, 'manage_assortments'));
create policy sales_assortments_manage on public.sales_assortments
  for all to authenticated
  using (public.has_company_permission(company_id, 'manage_assortments'))
  with check (public.has_company_permission(company_id, 'manage_assortments'));
create policy sales_assortment_items_read on public.sales_assortment_items
  for select to authenticated using (
    exists (
      select 1 from public.sales_assortments assortment
      where assortment.id = assortment_id
        and public.has_company_permission(assortment.company_id, 'manage_assortments')
    )
  );
create policy sales_assortment_items_manage on public.sales_assortment_items
  for all to authenticated using (
    exists (
      select 1 from public.sales_assortments assortment
      where assortment.id = assortment_id
        and public.has_company_permission(assortment.company_id, 'manage_assortments')
    )
  ) with check (
    exists (
      select 1 from public.sales_assortments assortment
      where assortment.id = assortment_id
        and public.has_company_permission(assortment.company_id, 'manage_assortments')
    )
  );
create policy location_sales_assortments_read on public.location_sales_assortments
  for select to authenticated using (
    exists (
      select 1 from public.sales_assortments assortment
      where assortment.id = assortment_id
        and public.has_company_permission(assortment.company_id, 'manage_assortments')
    )
  );
create policy location_sales_assortments_manage on public.location_sales_assortments
  for all to authenticated using (
    exists (
      select 1 from public.sales_assortments assortment
      where assortment.id = assortment_id
        and public.has_company_permission(assortment.company_id, 'manage_assortments')
    )
  ) with check (
    exists (
      select 1 from public.sales_assortments assortment
      where assortment.id = assortment_id
        and public.has_company_permission(assortment.company_id, 'manage_assortments')
    )
  );

grant select, insert, update, delete on public.product_external_references, public.location_external_references, public.sales_assortments, public.sales_assortment_items, public.location_sales_assortments to authenticated;
revoke all on function public.product_pos_readiness_detail(uuid, uuid, uuid, timestamptz) from public;
revoke all on function public.get_pos_readiness_overview(uuid, uuid, integer, integer) from public;
revoke all on function public.search_assortment_products(uuid, text, integer, integer) from public;
revoke all on function public.search_pos_products(uuid, uuid, text, integer, integer, timestamptz) from public;
revoke all on function public.validate_pos_product_for_location(uuid, uuid, uuid, timestamptz) from public;
revoke all on function public.list_import_audit(uuid, integer, integer, text, text) from public;
grant execute on function public.product_pos_readiness_detail(uuid, uuid, uuid, timestamptz) to authenticated;
grant execute on function public.get_pos_readiness_overview(uuid, uuid, integer, integer) to authenticated;
grant execute on function public.search_assortment_products(uuid, text, integer, integer) to authenticated;
grant execute on function public.search_pos_products(uuid, uuid, text, integer, integer, timestamptz) to authenticated;
grant execute on function public.validate_pos_product_for_location(uuid, uuid, uuid, timestamptz) to authenticated;
grant execute on function public.list_import_audit(uuid, integer, integer, text, text) to authenticated;
