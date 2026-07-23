-- Satrapy · Module 1 hardening: persistent staging and atomic Alpha imports.
-- import_batches is the canonical staging-batch record; a duplicate staging
-- header table would only duplicate its audit and lifecycle data.

alter table public.import_batches
  add column if not exists snapshot_date date,
  add column if not exists retry_of_batch_id uuid references public.import_batches(id) on delete set null;

alter table public.import_batches
  drop constraint if exists import_batches_import_type_check,
  drop constraint if exists import_batches_status_check,
  drop constraint if exists import_batches_company_type_file_sha256_key;

alter table public.import_batches
  add constraint import_batches_import_type_check
  check (import_type in ('products', 'inventory', 'unsupported')),
  add constraint import_batches_status_check
  check (status in ('staged', 'processing', 'completed', 'failed', 'validation_failed'));

-- Exact source files are blocked only after a successful completion. A failed
-- file can be staged again and retains its retry link for auditability.
create unique index if not exists import_batches_completed_file_sha256_key
  on public.import_batches(company_id, import_type, file_sha256)
  where status = 'completed';

create table public.import_staging_rows (
  id uuid primary key default gen_random_uuid(),
  import_batch_id uuid not null references public.import_batches(id) on delete cascade,
  row_number integer not null check (row_number > 0),
  source_file text not null,
  detected_type text not null check (detected_type in ('products', 'inventory')),
  raw_data jsonb not null,
  normalized_data jsonb not null,
  validation_status text not null check (validation_status in ('valid', 'warning', 'error')),
  created_at timestamptz not null default now(),
  unique (import_batch_id, row_number)
);

create table public.import_staging_errors (
  id uuid primary key default gen_random_uuid(),
  import_batch_id uuid not null references public.import_batches(id) on delete cascade,
  staging_row_id uuid references public.import_staging_rows(id) on delete cascade,
  severity text not null check (severity in ('error', 'warning')),
  error_code text not null,
  message text not null,
  row_number integer,
  alpha_sku text,
  location_code text,
  created_at timestamptz not null default now()
);

create index import_staging_rows_batch_status_idx
  on public.import_staging_rows(import_batch_id, validation_status, row_number);
create index import_staging_errors_batch_severity_idx
  on public.import_staging_errors(import_batch_id, severity, error_code);
create index import_staging_errors_batch_location_idx
  on public.import_staging_errors(import_batch_id, location_code)
  where location_code is not null;

alter table public.import_staging_rows enable row level security;
alter table public.import_staging_errors enable row level security;

create policy staging_rows_read on public.import_staging_rows
  for select to authenticated
  using (public.can_access_import_batch(import_batch_id));
create policy staging_errors_read on public.import_staging_errors
  for select to authenticated
  using (public.can_access_import_batch(import_batch_id));

-- The server route parses the XLS, but this RPC persists all staging data in a
-- single database transaction under the authenticated user's permissions.
create or replace function public.stage_alpha_import(
  p_company_id uuid,
  p_import_type text,
  p_source text,
  p_file_name text,
  p_file_type text,
  p_file_sha256 text,
  p_snapshot_date date,
  p_rows jsonb,
  p_errors jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch_id uuid;
  v_completed_batch_id uuid;
  v_retry_of_batch_id uuid;
  v_error_count integer := 0;
  v_warning_count integer := 0;
  v_valid_count integer := 0;
  v_received integer := 0;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'import_data') then
    raise exception 'No autorizado para preparar importaciones.';
  end if;
  if p_import_type not in ('products', 'inventory', 'unsupported') then
    raise exception 'Tipo de importación no permitido.';
  end if;
  if p_source not in ('manual_upload', 'local_development') then
    raise exception 'Origen de importación no permitido.';
  end if;

  select id into v_completed_batch_id
  from public.import_batches
  where company_id = p_company_id
    and import_type = p_import_type
    and file_sha256 = p_file_sha256
    and status = 'completed'
  limit 1;

  if v_completed_batch_id is not null then
    insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
    values (p_company_id, auth.uid(), 'import.duplicate_detected', 'import_batch', v_completed_batch_id,
      jsonb_build_object('original_name', p_file_name, 'file_sha256', p_file_sha256, 'import_type', p_import_type));
    return jsonb_build_object('status', 'duplicate', 'batch_id', v_completed_batch_id,
      'message', 'Este archivo ya fue importado correctamente para esta empresa.');
  end if;

  select id into v_retry_of_batch_id
  from public.import_batches
  where company_id = p_company_id
    and import_type = p_import_type
    and file_sha256 = p_file_sha256
    and status in ('failed', 'validation_failed')
  order by started_at desc
  limit 1;

  select
    count(*) filter (where severity = 'error'),
    count(*) filter (where severity = 'warning')
  into v_error_count, v_warning_count
  from jsonb_to_recordset(coalesce(p_errors, '[]'::jsonb))
    as error_row(severity text, error_code text, message text, row_number integer, alpha_sku text, location_code text);
  select count(*) into v_received from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb));
  select count(*) into v_valid_count
  from jsonb_to_recordset(coalesce(p_rows, '[]'::jsonb))
    as row_data(validation_status text)
  where validation_status = 'valid';

  insert into public.import_batches (
    company_id, import_type, source, file_sha256, status, records_received,
    imported_by, snapshot_date, retry_of_batch_id
  ) values (
    p_company_id, p_import_type, p_source, p_file_sha256,
    case when v_error_count > 0 then 'validation_failed' else 'staged' end,
    v_received, auth.uid(), p_snapshot_date, v_retry_of_batch_id
  ) returning id into v_batch_id;

  insert into public.import_files (import_batch_id, original_name, file_type, file_sha256, row_count)
  values (v_batch_id, p_file_name, p_file_type, p_file_sha256, v_received);

  insert into public.import_staging_rows (
    import_batch_id, row_number, source_file, detected_type, raw_data, normalized_data, validation_status
  )
  select
    v_batch_id,
    (row_data.value ->> 'row_number')::integer,
    row_data.value ->> 'source_file',
    row_data.value ->> 'detected_type',
    coalesce(row_data.value -> 'raw_data', '{}'::jsonb),
    coalesce(row_data.value -> 'normalized_data', '{}'::jsonb),
    row_data.value ->> 'validation_status'
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) as row_data(value);

  insert into public.import_staging_errors (
    import_batch_id, severity, error_code, message, row_number, alpha_sku, location_code
  )
  select
    v_batch_id,
    error_data.value ->> 'severity',
    error_data.value ->> 'error_code',
    error_data.value ->> 'message',
    nullif(error_data.value ->> 'row_number', '')::integer,
    nullif(error_data.value ->> 'alpha_sku', ''),
    nullif(error_data.value ->> 'location_code', '')
  from jsonb_array_elements(coalesce(p_errors, '[]'::jsonb)) as error_data(value);

  insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
  values
    (p_company_id, auth.uid(), 'import.file_uploaded', 'import_batch', v_batch_id,
      jsonb_build_object('original_name', p_file_name, 'file_sha256', p_file_sha256, 'import_type', p_import_type)),
    (p_company_id, auth.uid(), 'import.preview_generated', 'import_batch', v_batch_id,
      jsonb_build_object('records_received', v_received, 'valid_rows', v_valid_count,
        'errors', v_error_count, 'warnings', v_warning_count, 'snapshot_date', p_snapshot_date));
  if v_retry_of_batch_id is not null then
    insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
    values (p_company_id, auth.uid(), 'import.retry_staged', 'import_batch', v_batch_id,
      jsonb_build_object('retry_of_batch_id', v_retry_of_batch_id));
  end if;

  return jsonb_build_object(
    'status', case when v_error_count > 0 then 'validation_failed' else 'staged' end,
    'batch_id', v_batch_id,
    'records_received', v_received,
    'valid_rows', v_valid_count,
    'errors', v_error_count,
    'warnings', v_warning_count
  );
end;
$$;

create or replace function public.review_staged_location(
  p_import_batch_id uuid,
  p_external_code text,
  p_location_type text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch public.import_batches%rowtype;
  v_error_count integer;
begin
  select * into v_batch from public.import_batches where id = p_import_batch_id for update;
  if not found then raise exception 'Lote de staging no encontrado.'; end if;
  if auth.uid() is null or not public.has_company_permission(v_batch.company_id, 'import_data') then
    raise exception 'No autorizado para revisar ubicaciones.';
  end if;
  if v_batch.status not in ('staged', 'validation_failed') then
    raise exception 'El lote ya no admite cambios de staging.';
  end if;
  if p_location_type not in ('sucursal', 'almacen_central', 'almacen_operativo', 'campo') then
    raise exception 'Tipo de ubicación no válido.';
  end if;

  update public.import_staging_rows
  set normalized_data = jsonb_set(
    jsonb_set(normalized_data, '{locationType}', to_jsonb(p_location_type), true),
    '{classificationSource}', '"manual_review"'::jsonb, true
  )
  where import_batch_id = p_import_batch_id
    and detected_type = 'inventory'
    and normalized_data ->> 'locationCode' = p_external_code;

  delete from public.import_staging_errors
  where import_batch_id = p_import_batch_id
    and error_code = 'UBICACION_DESCONOCIDA'
    and location_code = p_external_code;

  update public.import_staging_rows row_data
  set validation_status = case
    when exists (
      select 1 from public.import_staging_errors error_data
      where error_data.import_batch_id = row_data.import_batch_id
        and error_data.row_number = row_data.row_number
        and error_data.severity = 'error'
    ) then 'error'
    when exists (
      select 1 from public.import_staging_errors error_data
      where error_data.import_batch_id = row_data.import_batch_id
        and error_data.row_number = row_data.row_number
        and error_data.severity = 'warning'
    ) then 'warning'
    else 'valid'
  end
  where row_data.import_batch_id = p_import_batch_id;

  select count(*) into v_error_count
  from public.import_staging_errors
  where import_batch_id = p_import_batch_id and severity = 'error';
  update public.import_batches
  set status = case when v_error_count > 0 then 'validation_failed' else 'staged' end
  where id = p_import_batch_id;

  insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_batch.company_id, auth.uid(), 'import.location_reviewed', 'import_batch', p_import_batch_id,
    jsonb_build_object('external_code', p_external_code, 'location_type', p_location_type));
  return jsonb_build_object('status', case when v_error_count > 0 then 'validation_failed' else 'staged' end);
end;
$$;

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
  v_has_errors boolean;
begin
  select * into v_batch from public.import_batches where id = p_import_batch_id for update;
  if not found then raise exception 'Lote de importación no encontrado.'; end if;
  if auth.uid() is null or not public.has_company_permission(v_batch.company_id, 'import_data') then
    raise exception 'No autorizado para confirmar importaciones.';
  end if;
  if v_batch.status = 'completed' then
    return jsonb_build_object('status', 'completed', 'records_imported', v_batch.records_imported, 'batch_id', v_batch.id);
  end if;

  select exists(
    select 1 from public.import_staging_errors
    where import_batch_id = p_import_batch_id and severity = 'error'
  ) into v_has_errors;
  if v_has_errors or v_batch.status = 'validation_failed' then
    update public.import_batches set status = 'validation_failed' where id = p_import_batch_id;
    insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
    values (v_batch.company_id, auth.uid(), 'import.confirmation_blocked', 'import_batch', p_import_batch_id,
      jsonb_build_object('reason', 'validation_errors'));
    return jsonb_build_object('status', 'validation_failed', 'message', 'Corrige los errores del staging antes de confirmar.');
  end if;
  if v_batch.status <> 'staged' then
    return jsonb_build_object('status', v_batch.status, 'message', 'El lote no está listo para confirmarse.');
  end if;

  select original_name into v_file_name
  from public.import_files where import_batch_id = p_import_batch_id order by created_at limit 1;

  begin
    if v_batch.import_type = 'products' then
      insert into public.products (
        company_id, alpha_sku, alpha_class, name, attribute, unit, product_group, subgroup, product_type
      )
      select
        v_batch.company_id,
        row_data.normalized_data ->> 'alphaSku',
        nullif(row_data.normalized_data ->> 'alphaClass', ''),
        row_data.normalized_data ->> 'name',
        nullif(row_data.normalized_data ->> 'attribute', ''),
        nullif(row_data.normalized_data ->> 'unit', ''),
        nullif(row_data.normalized_data ->> 'productGroup', ''),
        nullif(row_data.normalized_data ->> 'subgroup', ''),
        nullif(row_data.normalized_data ->> 'productType', '')
      from public.import_staging_rows row_data
      where row_data.import_batch_id = p_import_batch_id and row_data.detected_type = 'products'
      on conflict (company_id, alpha_sku) do update set
        alpha_class = excluded.alpha_class,
        name = excluded.name,
        attribute = excluded.attribute,
        unit = excluded.unit,
        product_group = excluded.product_group,
        subgroup = excluded.subgroup,
        product_type = excluded.product_type;
      get diagnostics v_records = row_count;
    elsif v_batch.import_type = 'inventory' then
      if v_batch.snapshot_date is null then raise exception 'El reporte no tiene fecha efectiva.'; end if;
      if exists (
        select 1 from public.import_staging_rows row_data
        where row_data.import_batch_id = p_import_batch_id
          and row_data.detected_type = 'inventory'
          and nullif(row_data.normalized_data ->> 'locationType', '') is null
      ) then raise exception 'Existen ubicaciones sin clasificación.'; end if;
      if exists (
        select 1 from public.import_staging_rows row_data
        where row_data.import_batch_id = p_import_batch_id
          and row_data.detected_type = 'inventory'
          and not exists (
            select 1 from public.products product
            where product.company_id = v_batch.company_id
              and product.alpha_sku = row_data.normalized_data ->> 'alphaSku'
          )
      ) then raise exception 'Existen existencias sin producto válido.'; end if;

      insert into public.locations (
        company_id, external_code, name, location_type, classification_source,
        classification_reviewed_at, classification_reviewed_by, is_active
      )
      select distinct
        v_batch.company_id,
        row_data.normalized_data ->> 'locationCode',
        row_data.normalized_data ->> 'locationName',
        row_data.normalized_data ->> 'locationType',
        coalesce(nullif(row_data.normalized_data ->> 'classificationSource', ''), 'manual_review'),
        now(),
        case when row_data.normalized_data ->> 'classificationSource' = 'manual_review' then auth.uid() else null end,
        true
      from public.import_staging_rows row_data
      where row_data.import_batch_id = p_import_batch_id and row_data.detected_type = 'inventory'
      on conflict (company_id, external_code) do nothing;

      insert into public.inventory_snapshots (
        company_id, import_batch_id, source_file_name, snapshot_date, status, created_by
      ) values (
        v_batch.company_id, p_import_batch_id, v_file_name, v_batch.snapshot_date, 'completed', auth.uid()
      ) returning id into v_snapshot_id;

      insert into public.inventory_snapshot_items (
        snapshot_id, product_id, location_id, quantity, unit, physical_quantity,
        available_quantity, reserved_quantity, field_assigned_quantity, in_transit_quantity,
        average_cost, reported_total_cost, alpha_class, import_batch_id, source_file_name
      )
      select
        v_snapshot_id,
        product.id,
        location.id,
        (row_data.normalized_data ->> 'quantity')::numeric,
        nullif(row_data.normalized_data ->> 'unit', ''),
        (row_data.normalized_data ->> 'quantity')::numeric,
        case when location.location_type = 'campo' then 0 else (row_data.normalized_data ->> 'quantity')::numeric end,
        0,
        case when location.location_type = 'campo' then (row_data.normalized_data ->> 'quantity')::numeric else 0 end,
        0,
        case
          when nullif(row_data.normalized_data ->> 'reportedValue', '') is not null
            and (row_data.normalized_data ->> 'quantity')::numeric <> 0
          then (row_data.normalized_data ->> 'reportedValue')::numeric / (row_data.normalized_data ->> 'quantity')::numeric
          else nullif(row_data.normalized_data ->> 'replacementCost', '')::numeric
        end,
        nullif(row_data.normalized_data ->> 'reportedValue', '')::numeric,
        nullif(row_data.normalized_data ->> 'alphaClass', ''),
        p_import_batch_id,
        v_file_name
      from public.import_staging_rows row_data
      join public.products product
        on product.company_id = v_batch.company_id
        and product.alpha_sku = row_data.normalized_data ->> 'alphaSku'
      join public.locations location
        on location.company_id = v_batch.company_id
        and location.external_code = row_data.normalized_data ->> 'locationCode'
      where row_data.import_batch_id = p_import_batch_id and row_data.detected_type = 'inventory';
      get diagnostics v_records = row_count;
    else
      raise exception 'El tipo de archivo no es compatible con una importación final.';
    end if;

    update public.import_batches
    set status = 'completed', records_imported = v_records, completed_at = now(), notes = null
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
    set status = 'failed', completed_at = now(), notes = v_error
    where id = p_import_batch_id;
    insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
    values (v_batch.company_id, auth.uid(), 'import.failed', 'import_batch', p_import_batch_id,
      jsonb_build_object('import_type', v_batch.import_type, 'original_name', v_file_name, 'error', v_error));
    return jsonb_build_object('status', 'failed', 'message', v_error, 'batch_id', p_import_batch_id);
  end if;

  return jsonb_build_object('status', 'completed', 'records_imported', v_records, 'batch_id', p_import_batch_id);
end;
$$;

-- Final business writes happen only through the guarded security-definer RPC.
revoke insert, update, delete on public.products, public.locations,
  public.inventory_snapshots, public.inventory_snapshot_items,
  public.import_batches, public.import_files, public.import_errors, public.audit_log
from authenticated;
grant select on public.import_staging_rows, public.import_staging_errors to authenticated;
revoke all on function public.stage_alpha_import(uuid, text, text, text, text, text, date, jsonb, jsonb) from public;
revoke all on function public.review_staged_location(uuid, text, text) from public;
revoke all on function public.confirm_staged_import(uuid) from public;
grant execute on function public.stage_alpha_import(uuid, text, text, text, text, text, date, jsonb, jsonb) to authenticated;
grant execute on function public.review_staged_location(uuid, text, text) to authenticated;
grant execute on function public.confirm_staged_import(uuid) to authenticated;
