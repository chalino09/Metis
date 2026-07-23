-- Satrapy · Module 1 · Task 2.5
-- Operational closure for staging: quarantine, controlled resolution, lifecycle,
-- pagination, permanent summaries and automatic retention.

alter table public.import_batches
  add column if not exists valid_rows integer not null default 0,
  add column if not exists warning_rows integer not null default 0,
  add column if not exists error_rows integer not null default 0,
  add column if not exists blocking_error_count integer not null default 0,
  add column if not exists pending_warning_count integer not null default 0,
  add column if not exists error_summary jsonb not null default '{}'::jsonb,
  add column if not exists last_activity_at timestamptz not null default now(),
  add column if not exists closed_at timestamptz,
  add column if not exists staging_purged_at timestamptz,
  add column if not exists discard_reason text;

alter table public.import_batches drop constraint if exists import_batches_status_check;
alter table public.import_batches add constraint import_batches_status_check
  check (status in ('staged', 'processing', 'completed', 'failed', 'validation_failed', 'discarded', 'expired'));

alter table public.import_batches alter column error_summary set default '[]'::jsonb;

-- Closed batches created before this migration need a retention anchor too.
update public.import_batches
set closed_at = coalesce(completed_at, started_at),
    last_activity_at = coalesce(completed_at, started_at, last_activity_at)
where status in ('completed', 'failed', 'discarded', 'expired')
  and closed_at is null;

alter table public.import_staging_rows
  add column if not exists resolved_product_id uuid references public.products(id) on delete restrict,
  add column if not exists resolved_by uuid references auth.users(id) on delete set null,
  add column if not exists resolved_at timestamptz,
  add column if not exists resolution_reason text;

alter table public.import_staging_errors
  add column if not exists resolved_by uuid references auth.users(id) on delete set null,
  add column if not exists resolved_at timestamptz,
  add column if not exists resolution_note text,
  add column if not exists acknowledged_by uuid references auth.users(id) on delete set null,
  add column if not exists acknowledged_at timestamptz,
  add column if not exists acknowledgement_note text;

alter table public.inventory_snapshot_items
  add column if not exists source_alpha_sku text,
  add column if not exists product_mapping_applied boolean not null default false;

update public.inventory_snapshot_items item
set source_alpha_sku = product.alpha_sku
from public.products product
where product.id = item.product_id and item.source_alpha_sku is null;

alter table public.inventory_snapshot_items alter column source_alpha_sku set not null;
grant select (source_alpha_sku, product_mapping_applied) on public.inventory_snapshot_items to authenticated;

update public.import_staging_errors error_data
set staging_row_id = row_data.id
from public.import_staging_rows row_data
where error_data.staging_row_id is null
  and row_data.import_batch_id = error_data.import_batch_id
  and row_data.row_number = error_data.row_number;

create index if not exists import_staging_rows_resolved_product_idx
  on public.import_staging_rows(resolved_product_id)
  where resolved_product_id is not null;
create index if not exists import_batches_staging_maintenance_idx
  on public.import_batches(status, last_activity_at, closed_at)
  where staging_purged_at is null;

create or replace function public.refresh_import_staging_batch(p_import_batch_id uuid, p_touch boolean default true)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_valid integer;
  v_warning integer;
  v_error integer;
  v_blocking integer;
  v_pending_warnings integer;
  v_summary jsonb;
begin
  update public.import_staging_rows row_data
  set validation_status = case
    when exists (
      select 1 from public.import_staging_errors error_data
      where error_data.import_batch_id = row_data.import_batch_id
        and error_data.staging_row_id = row_data.id
        and error_data.severity = 'error'
        and error_data.resolved_at is null
    ) then 'error'
    when exists (
      select 1 from public.import_staging_errors error_data
      where error_data.import_batch_id = row_data.import_batch_id
        and error_data.staging_row_id = row_data.id
        and error_data.severity = 'warning'
    ) then 'warning'
    else 'valid'
  end
  where row_data.import_batch_id = p_import_batch_id;

  select
    count(*) filter (where validation_status = 'valid'),
    count(*) filter (where validation_status = 'warning'),
    count(*) filter (where validation_status = 'error')
  into v_valid, v_warning, v_error
  from public.import_staging_rows where import_batch_id = p_import_batch_id;

  select
    count(*) filter (where severity = 'error' and resolved_at is null),
    count(*) filter (where severity = 'warning' and acknowledged_at is null)
  into v_blocking, v_pending_warnings
  from public.import_staging_errors where import_batch_id = p_import_batch_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'error_code', summary.error_code,
    'severity', summary.severity,
    'total', summary.total_count,
    'pending', summary.pending_count
  ) order by summary.severity, summary.error_code), '[]'::jsonb)
  into v_summary
  from (
    select error_code, min(severity) as severity, count(*) as total_count,
      count(*) filter (where
        (severity = 'error' and resolved_at is null)
        or (severity = 'warning' and acknowledged_at is null)
      ) as pending_count
    from public.import_staging_errors
    where import_batch_id = p_import_batch_id
    group by error_code, severity
  ) summary;

  update public.import_batches
  set valid_rows = coalesce(v_valid, 0),
      warning_rows = coalesce(v_warning, 0),
      error_rows = coalesce(v_error, 0),
      blocking_error_count = coalesce(v_blocking, 0),
      pending_warning_count = coalesce(v_pending_warnings, 0),
      error_summary = coalesce(v_summary, '[]'::jsonb),
      last_activity_at = case when p_touch then now() else last_activity_at end,
      status = case
        when status in ('staged', 'validation_failed') and coalesce(v_blocking, 0) > 0 then 'validation_failed'
        when status in ('staged', 'validation_failed') then 'staged'
        else status
      end
  where id = p_import_batch_id;
end;
$$;

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
  v_received integer := 0;
  v_batch public.import_batches%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'import_data') then
    raise exception 'No autorizado para preparar importaciones.';
  end if;
  if p_import_type not in ('products', 'inventory', 'unsupported') then raise exception 'Tipo de importación no permitido.'; end if;
  if p_source not in ('manual_upload', 'local_development') then raise exception 'Origen de importación no permitido.'; end if;

  select id into v_completed_batch_id from public.import_batches
  where company_id = p_company_id and import_type = p_import_type
    and file_sha256 = p_file_sha256 and status = 'completed' limit 1;
  if v_completed_batch_id is not null then
    insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
    values (p_company_id, auth.uid(), 'import.duplicate_detected', 'import_batch', v_completed_batch_id,
      jsonb_build_object('original_name', p_file_name, 'file_sha256', p_file_sha256, 'import_type', p_import_type));
    return jsonb_build_object('status', 'duplicate', 'batch_id', v_completed_batch_id,
      'message', 'Este archivo ya fue importado correctamente para esta empresa.');
  end if;

  select id into v_retry_of_batch_id from public.import_batches
  where company_id = p_company_id and import_type = p_import_type and file_sha256 = p_file_sha256
    and status in ('failed', 'validation_failed', 'discarded', 'expired')
  order by started_at desc limit 1;
  select count(*) into v_received from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb));

  insert into public.import_batches (
    company_id, import_type, source, file_sha256, status, records_received,
    imported_by, snapshot_date, retry_of_batch_id, last_activity_at
  ) values (
    p_company_id, p_import_type, p_source, p_file_sha256, 'staged', v_received,
    auth.uid(), p_snapshot_date, v_retry_of_batch_id, now()
  ) returning id into v_batch_id;

  insert into public.import_files (import_batch_id, original_name, file_type, file_sha256, row_count)
  values (v_batch_id, p_file_name, p_file_type, p_file_sha256, v_received);

  insert into public.import_staging_rows (
    import_batch_id, row_number, source_file, detected_type, raw_data, normalized_data, validation_status
  )
  select v_batch_id, (item ->> 'row_number')::integer, item ->> 'source_file', item ->> 'detected_type',
    coalesce(item -> 'raw_data', '{}'::jsonb), coalesce(item -> 'normalized_data', '{}'::jsonb),
    item ->> 'validation_status'
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) item;

  insert into public.import_staging_errors (
    import_batch_id, severity, error_code, message, row_number, alpha_sku, location_code
  )
  select v_batch_id, item ->> 'severity', item ->> 'error_code', item ->> 'message',
    nullif(item ->> 'row_number', '')::integer, nullif(item ->> 'alpha_sku', ''), nullif(item ->> 'location_code', '')
  from jsonb_array_elements(coalesce(p_errors, '[]'::jsonb)) item;

  update public.import_staging_errors error_data
  set staging_row_id = row_data.id
  from public.import_staging_rows row_data
  where error_data.import_batch_id = v_batch_id and row_data.import_batch_id = v_batch_id
    and error_data.row_number = row_data.row_number;
  perform public.refresh_import_staging_batch(v_batch_id, false);
  select * into v_batch from public.import_batches where id = v_batch_id;

  insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
  values
    (p_company_id, auth.uid(), 'import.file_uploaded', 'import_batch', v_batch_id,
      jsonb_build_object('original_name', p_file_name, 'file_sha256', p_file_sha256, 'import_type', p_import_type)),
    (p_company_id, auth.uid(), 'import.preview_generated', 'import_batch', v_batch_id,
      jsonb_build_object('records_received', v_received, 'valid_rows', v_batch.valid_rows,
        'warning_rows', v_batch.warning_rows, 'error_rows', v_batch.error_rows,
        'blocking_errors', v_batch.blocking_error_count, 'pending_warnings', v_batch.pending_warning_count,
        'snapshot_date', p_snapshot_date));
  if v_retry_of_batch_id is not null then
    insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
    values (p_company_id, auth.uid(), 'import.retry_staged', 'import_batch', v_batch_id,
      jsonb_build_object('retry_of_batch_id', v_retry_of_batch_id));
  end if;
  return jsonb_build_object('status', v_batch.status, 'batch_id', v_batch_id,
    'records_received', v_received, 'valid_rows', v_batch.valid_rows,
    'warning_rows', v_batch.warning_rows, 'error_rows', v_batch.error_rows,
    'blocking_errors', v_batch.blocking_error_count, 'pending_warnings', v_batch.pending_warning_count);
end;
$$;

create or replace function public.review_staged_location(
  p_import_batch_id uuid, p_external_code text, p_location_type text
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_batch public.import_batches%rowtype; v_updated integer;
begin
  select * into v_batch from public.import_batches where id = p_import_batch_id for update;
  if not found then raise exception 'Lote de staging no encontrado.'; end if;
  if auth.uid() is null or not public.has_company_permission(v_batch.company_id, 'import_data') then raise exception 'No autorizado.'; end if;
  if v_batch.status not in ('staged', 'validation_failed') then raise exception 'El lote ya no admite cambios.'; end if;
  if p_location_type not in ('sucursal', 'almacen_central', 'almacen_operativo', 'campo') then raise exception 'Tipo de ubicación no válido.'; end if;
  update public.import_staging_rows set normalized_data = jsonb_set(
    jsonb_set(normalized_data, '{locationType}', to_jsonb(p_location_type), true),
    '{classificationSource}', '"manual_review"'::jsonb, true)
  where import_batch_id = p_import_batch_id and detected_type = 'inventory'
    and normalized_data ->> 'locationCode' = p_external_code;
  get diagnostics v_updated = row_count;
  if v_updated = 0 then raise exception 'Ubicación de staging no encontrada.'; end if;
  update public.import_staging_errors set resolved_by = auth.uid(), resolved_at = now(),
    resolution_note = 'Ubicación clasificada manualmente'
  where import_batch_id = p_import_batch_id and error_code = 'UBICACION_DESCONOCIDA'
    and location_code = p_external_code and resolved_at is null;
  perform public.refresh_import_staging_batch(p_import_batch_id, true);
  insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_batch.company_id, auth.uid(), 'import.location_reviewed', 'import_batch', p_import_batch_id,
    jsonb_build_object('external_code', p_external_code, 'location_type', p_location_type, 'rows', v_updated));
  return jsonb_build_object('status', (select status from public.import_batches where id = p_import_batch_id));
end;
$$;

create or replace function public.resolve_staged_product(
  p_import_batch_id uuid, p_staging_row_id uuid, p_product_id uuid, p_reason text
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_batch public.import_batches%rowtype; v_row public.import_staging_rows%rowtype; v_product public.products%rowtype;
begin
  if nullif(trim(p_reason), '') is null then raise exception 'Indica el motivo del mapeo.'; end if;
  select * into v_batch from public.import_batches where id = p_import_batch_id for update;
  if not found then raise exception 'Lote no encontrado.'; end if;
  if auth.uid() is null or not public.has_company_permission(v_batch.company_id, 'import_data') then raise exception 'No autorizado.'; end if;
  if v_batch.status not in ('staged', 'validation_failed') then raise exception 'El lote ya no admite cambios.'; end if;
  select * into v_row from public.import_staging_rows
  where id = p_staging_row_id and import_batch_id = p_import_batch_id and detected_type = 'inventory' for update;
  if not found then raise exception 'Fila de inventario no encontrada.'; end if;
  if not exists (select 1 from public.import_staging_errors where import_batch_id = p_import_batch_id
    and staging_row_id = p_staging_row_id and error_code = 'PRODUCTO_INEXISTENTE' and resolved_at is null) then
    raise exception 'La fila no tiene un producto pendiente de resolución.';
  end if;
  select * into v_product from public.products where id = p_product_id
    and company_id = v_batch.company_id and is_active = true;
  if not found then raise exception 'El producto seleccionado no pertenece a la empresa o está inactivo.'; end if;
  update public.import_staging_rows set resolved_product_id = p_product_id, resolved_by = auth.uid(),
    resolved_at = now(), resolution_reason = trim(p_reason)
  where id = p_staging_row_id;
  update public.import_staging_errors set resolved_by = auth.uid(), resolved_at = now(), resolution_note = trim(p_reason)
  where import_batch_id = p_import_batch_id and staging_row_id = p_staging_row_id
    and error_code = 'PRODUCTO_INEXISTENTE' and resolved_at is null;
  perform public.refresh_import_staging_batch(p_import_batch_id, true);
  insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_batch.company_id, auth.uid(), 'import.product_mapped', 'import_batch', p_import_batch_id,
    jsonb_build_object('staging_row_id', p_staging_row_id, 'source_alpha_sku', v_row.normalized_data ->> 'alphaSku',
      'product_id', v_product.id, 'resolved_alpha_sku', v_product.alpha_sku, 'reason', trim(p_reason)));
  return jsonb_build_object('status', 'resolved', 'product_id', v_product.id, 'alpha_sku', v_product.alpha_sku);
end;
$$;

create or replace function public.acknowledge_staged_warnings(
  p_import_batch_id uuid, p_error_code text, p_note text
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_batch public.import_batches%rowtype; v_count integer;
begin
  if nullif(trim(p_note), '') is null then raise exception 'Indica una nota de reconocimiento.'; end if;
  select * into v_batch from public.import_batches where id = p_import_batch_id for update;
  if not found then raise exception 'Lote no encontrado.'; end if;
  if auth.uid() is null or not public.has_company_permission(v_batch.company_id, 'import_data') then raise exception 'No autorizado.'; end if;
  if v_batch.status not in ('staged', 'validation_failed') then raise exception 'El lote ya no admite cambios.'; end if;
  update public.import_staging_errors set acknowledged_by = auth.uid(), acknowledged_at = now(),
    acknowledgement_note = trim(p_note)
  where import_batch_id = p_import_batch_id and severity = 'warning'
    and error_code = p_error_code and acknowledged_at is null;
  get diagnostics v_count = row_count;
  if v_count = 0 then raise exception 'No hay warnings pendientes de ese tipo.'; end if;
  perform public.refresh_import_staging_batch(p_import_batch_id, true);
  insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_batch.company_id, auth.uid(), 'import.warnings_acknowledged', 'import_batch', p_import_batch_id,
    jsonb_build_object('error_code', p_error_code, 'count', v_count, 'note', trim(p_note)));
  return jsonb_build_object('status', 'acknowledged', 'count', v_count);
end;
$$;

create or replace function public.discard_staged_import(p_import_batch_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_batch public.import_batches%rowtype;
begin
  if nullif(trim(p_reason), '') is null then raise exception 'Indica el motivo del descarte.'; end if;
  select * into v_batch from public.import_batches where id = p_import_batch_id for update;
  if not found then raise exception 'Lote no encontrado.'; end if;
  if auth.uid() is null or not public.has_company_permission(v_batch.company_id, 'import_data') then raise exception 'No autorizado.'; end if;
  if v_batch.status not in ('staged', 'validation_failed') then raise exception 'Solo se puede descartar staging activo.'; end if;
  update public.import_batches set status = 'discarded', discard_reason = trim(p_reason),
    closed_at = now(), completed_at = coalesce(completed_at, now()), last_activity_at = now()
  where id = p_import_batch_id;
  insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_batch.company_id, auth.uid(), 'import.discarded', 'import_batch', p_import_batch_id,
    jsonb_build_object('reason', trim(p_reason)));
  return jsonb_build_object('status', 'discarded', 'batch_id', p_import_batch_id);
end;
$$;

create or replace function public.retry_staged_import(p_import_batch_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_source public.import_batches%rowtype; v_new_id uuid; v_completed uuid; v_file public.import_files%rowtype;
begin
  if nullif(trim(p_reason), '') is null then raise exception 'Indica el motivo del reintento.'; end if;
  select * into v_source from public.import_batches where id = p_import_batch_id for update;
  if not found then raise exception 'Lote no encontrado.'; end if;
  if auth.uid() is null or not public.has_company_permission(v_source.company_id, 'import_data') then raise exception 'No autorizado.'; end if;
  if v_source.status <> 'failed' then raise exception 'Solo los lotes fallidos pueden reintentarse.'; end if;
  if v_source.staging_purged_at is not null then raise exception 'El staging del lote ya fue purgado.'; end if;
  select id into v_completed from public.import_batches where company_id = v_source.company_id
    and import_type = v_source.import_type and file_sha256 = v_source.file_sha256 and status = 'completed' limit 1;
  if v_completed is not null then return jsonb_build_object('status', 'duplicate', 'batch_id', v_completed); end if;
  insert into public.import_batches (company_id, import_type, source, file_sha256, status, records_received,
    imported_by, snapshot_date, retry_of_batch_id, last_activity_at)
  values (v_source.company_id, v_source.import_type, v_source.source, v_source.file_sha256, 'staged',
    v_source.records_received, auth.uid(), v_source.snapshot_date, v_source.id, now()) returning id into v_new_id;
  insert into public.import_files (import_batch_id, original_name, file_type, file_sha256, row_count)
  select v_new_id, original_name, file_type, file_sha256, row_count from public.import_files
  where import_batch_id = p_import_batch_id;
  insert into public.import_staging_rows (import_batch_id, row_number, source_file, detected_type, raw_data,
    normalized_data, validation_status, resolved_product_id, resolved_by, resolved_at, resolution_reason)
  select v_new_id, row_number, source_file, detected_type, raw_data, normalized_data, validation_status,
    resolved_product_id, resolved_by, resolved_at, resolution_reason
  from public.import_staging_rows where import_batch_id = p_import_batch_id;
  insert into public.import_staging_errors (import_batch_id, severity, error_code, message, row_number,
    alpha_sku, location_code, resolved_by, resolved_at, resolution_note,
    acknowledged_by, acknowledged_at, acknowledgement_note)
  select v_new_id, severity, error_code, message, row_number, alpha_sku, location_code,
    resolved_by, resolved_at, resolution_note, acknowledged_by, acknowledged_at, acknowledgement_note
  from public.import_staging_errors where import_batch_id = p_import_batch_id;
  update public.import_staging_errors error_data set staging_row_id = row_data.id
  from public.import_staging_rows row_data
  where error_data.import_batch_id = v_new_id and row_data.import_batch_id = v_new_id
    and error_data.row_number = row_data.row_number;
  perform public.refresh_import_staging_batch(v_new_id, false);
  insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_source.company_id, auth.uid(), 'import.retry_created', 'import_batch', v_new_id,
    jsonb_build_object('retry_of_batch_id', p_import_batch_id, 'reason', trim(p_reason)));
  return jsonb_build_object('status', (select status from public.import_batches where id = v_new_id), 'batch_id', v_new_id);
end;
$$;

create or replace function public.get_import_staging_preview(
  p_import_batch_id uuid, p_page integer default 1, p_page_size integer default 50,
  p_status text default null, p_error_code text default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_batch public.import_batches%rowtype; v_page integer; v_size integer; v_total integer;
  v_rows jsonb; v_groups jsonb; v_file jsonb; v_pending_locations jsonb;
begin
  select * into v_batch from public.import_batches where id = p_import_batch_id;
  if not found then raise exception 'Lote no encontrado.'; end if;
  if auth.uid() is null or not public.has_company_permission(v_batch.company_id, 'import_data') then raise exception 'No autorizado.'; end if;
  if p_status is not null and p_status not in ('valid', 'warning', 'error') then raise exception 'Filtro de estado no válido.'; end if;
  v_page := greatest(coalesce(p_page, 1), 1); v_size := least(greatest(coalesce(p_page_size, 50), 1), 200);
  select to_jsonb(file_data) into v_file from (
    select original_name, file_type, file_sha256, row_count from public.import_files
    where import_batch_id = p_import_batch_id order by created_at limit 1
  ) file_data;
  select count(*) into v_total from public.import_staging_rows row_data
  where row_data.import_batch_id = p_import_batch_id
    and (p_status is null or row_data.validation_status = p_status)
    and (p_error_code is null or exists (select 1 from public.import_staging_errors error_data
      where error_data.staging_row_id = row_data.id and error_data.error_code = p_error_code));
  select coalesce(jsonb_agg(to_jsonb(page_data) order by page_data.row_number), '[]'::jsonb) into v_rows
  from (
    select row_data.id, row_data.row_number, row_data.source_file, row_data.detected_type,
      row_data.raw_data, row_data.normalized_data, row_data.validation_status,
      row_data.resolved_product_id, row_data.resolved_at, row_data.resolution_reason,
      coalesce((select jsonb_agg(jsonb_build_object('id', error_data.id, 'severity', error_data.severity,
        'error_code', error_data.error_code, 'message', error_data.message,
        'resolved_at', error_data.resolved_at, 'acknowledged_at', error_data.acknowledged_at))
        from public.import_staging_errors error_data where error_data.staging_row_id = row_data.id), '[]'::jsonb) as issues
    from public.import_staging_rows row_data
    where row_data.import_batch_id = p_import_batch_id
      and (p_status is null or row_data.validation_status = p_status)
      and (p_error_code is null or exists (select 1 from public.import_staging_errors error_data
        where error_data.staging_row_id = row_data.id and error_data.error_code = p_error_code))
    order by row_data.row_number limit v_size offset ((v_page - 1) * v_size)
  ) page_data;
  select coalesce(jsonb_agg(jsonb_build_object('error_code', groups.error_code, 'severity', groups.severity,
    'total', groups.total_count, 'pending', groups.pending_count) order by groups.severity, groups.error_code), '[]'::jsonb)
  into v_groups from (
    select error_code, min(severity) severity, count(*) total_count,
      count(*) filter (where (severity = 'error' and resolved_at is null)
        or (severity = 'warning' and acknowledged_at is null)) pending_count
    from public.import_staging_errors where import_batch_id = p_import_batch_id group by error_code, severity
  ) groups;
  select coalesce(jsonb_agg(to_jsonb(location_data) order by location_data.external_code), '[]'::jsonb)
  into v_pending_locations from (
    select row_data.normalized_data ->> 'locationCode' as external_code,
      min(row_data.normalized_data ->> 'locationName') as name,
      count(*) as row_count
    from public.import_staging_rows row_data
    where row_data.import_batch_id = p_import_batch_id
      and row_data.detected_type = 'inventory'
      and coalesce((row_data.normalized_data ->> 'rejected')::boolean, false) = false
      and nullif(row_data.normalized_data ->> 'locationCode', '') is not null
      and nullif(row_data.normalized_data ->> 'locationType', '') is null
    group by row_data.normalized_data ->> 'locationCode'
  ) location_data;
  return jsonb_build_object('batch', jsonb_build_object('id', v_batch.id, 'import_type', v_batch.import_type,
    'status', v_batch.status, 'records_received', v_batch.records_received, 'snapshot_date', v_batch.snapshot_date,
    'valid_rows', v_batch.valid_rows, 'warning_rows', v_batch.warning_rows, 'error_rows', v_batch.error_rows,
    'blocking_error_count', v_batch.blocking_error_count, 'pending_warning_count', v_batch.pending_warning_count,
    'error_summary', v_batch.error_summary, 'staging_purged_at', v_batch.staging_purged_at,
    'retry_of_batch_id', v_batch.retry_of_batch_id), 'file', v_file, 'rows', v_rows,
    'error_groups', v_groups, 'pending_locations', v_pending_locations,
    'pagination', jsonb_build_object('page', v_page, 'page_size', v_size, 'total', v_total));
end;
$$;

create or replace function public.confirm_staged_import(p_import_batch_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_batch public.import_batches%rowtype; v_file_name text; v_snapshot_id uuid;
  v_records integer := 0; v_error text; v_duplicate uuid;
begin
  select * into v_batch from public.import_batches where id = p_import_batch_id for update;
  if not found then raise exception 'Lote de importación no encontrado.'; end if;
  if auth.uid() is null or not public.has_company_permission(v_batch.company_id, 'import_data') then raise exception 'No autorizado.'; end if;
  if v_batch.status = 'completed' then return jsonb_build_object('status', 'completed', 'records_imported', v_batch.records_imported, 'batch_id', v_batch.id); end if;
  perform public.refresh_import_staging_batch(p_import_batch_id, false);
  select * into v_batch from public.import_batches where id = p_import_batch_id;
  if v_batch.blocking_error_count > 0 or v_batch.pending_warning_count > 0 then
    insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
    values (v_batch.company_id, auth.uid(), 'import.confirmation_blocked', 'import_batch', p_import_batch_id,
      jsonb_build_object('blocking_errors', v_batch.blocking_error_count, 'pending_warnings', v_batch.pending_warning_count));
    return jsonb_build_object('status', 'validation_failed', 'message', 'Resuelve errores y reconoce warnings antes de confirmar.');
  end if;
  if v_batch.status <> 'staged' then return jsonb_build_object('status', v_batch.status, 'message', 'El lote no está listo.'); end if;
  select id into v_duplicate from public.import_batches where company_id = v_batch.company_id
    and import_type = v_batch.import_type and file_sha256 = v_batch.file_sha256
    and status = 'completed' and id <> v_batch.id limit 1;
  if v_duplicate is not null then return jsonb_build_object('status', 'duplicate', 'batch_id', v_duplicate); end if;
  select original_name into v_file_name from public.import_files
  where import_batch_id = p_import_batch_id order by created_at limit 1;
  begin
    if v_batch.import_type = 'products' then
      insert into public.products (company_id, alpha_sku, alpha_class, name, attribute, unit, product_group, subgroup, product_type)
      select v_batch.company_id, row_data.normalized_data ->> 'alphaSku', nullif(row_data.normalized_data ->> 'alphaClass', ''),
        row_data.normalized_data ->> 'name', nullif(row_data.normalized_data ->> 'attribute', ''),
        nullif(row_data.normalized_data ->> 'unit', ''), nullif(row_data.normalized_data ->> 'productGroup', ''),
        nullif(row_data.normalized_data ->> 'subgroup', ''), nullif(row_data.normalized_data ->> 'productType', '')
      from public.import_staging_rows row_data where row_data.import_batch_id = p_import_batch_id
        and row_data.detected_type = 'products' and coalesce((row_data.normalized_data ->> 'rejected')::boolean, false) = false
      on conflict (company_id, alpha_sku) do update set alpha_class = excluded.alpha_class, name = excluded.name,
        attribute = excluded.attribute, unit = excluded.unit, product_group = excluded.product_group,
        subgroup = excluded.subgroup, product_type = excluded.product_type;
      get diagnostics v_records = row_count;
    elsif v_batch.import_type = 'inventory' then
      if v_batch.snapshot_date is null then raise exception 'El reporte no tiene fecha efectiva.'; end if;
      if exists (select 1 from public.import_staging_rows row_data where row_data.import_batch_id = p_import_batch_id
        and row_data.detected_type = 'inventory' and coalesce((row_data.normalized_data ->> 'rejected')::boolean, false) = false
        and nullif(row_data.normalized_data ->> 'locationType', '') is null) then raise exception 'Existen ubicaciones sin clasificación.'; end if;
      if exists (select 1 from public.import_staging_rows row_data where row_data.import_batch_id = p_import_batch_id
        and row_data.detected_type = 'inventory' and coalesce((row_data.normalized_data ->> 'rejected')::boolean, false) = false
        and row_data.resolved_product_id is null and not exists (select 1 from public.products product
          where product.company_id = v_batch.company_id and product.alpha_sku = row_data.normalized_data ->> 'alphaSku'))
        then raise exception 'Existen existencias sin producto válido.'; end if;
      insert into public.locations (company_id, external_code, name, location_type, classification_source,
        classification_reviewed_at, classification_reviewed_by, is_active)
      select distinct v_batch.company_id, row_data.normalized_data ->> 'locationCode', row_data.normalized_data ->> 'locationName',
        row_data.normalized_data ->> 'locationType', coalesce(nullif(row_data.normalized_data ->> 'classificationSource', ''), 'manual_review'),
        now(), case when row_data.normalized_data ->> 'classificationSource' = 'manual_review' then auth.uid() else null end, true
      from public.import_staging_rows row_data where row_data.import_batch_id = p_import_batch_id
        and row_data.detected_type = 'inventory' and coalesce((row_data.normalized_data ->> 'rejected')::boolean, false) = false
      on conflict (company_id, external_code) do nothing;
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
      join public.products product on product.company_id = v_batch.company_id and product.is_active = true and
        ((row_data.resolved_product_id is not null and product.id = row_data.resolved_product_id)
          or (row_data.resolved_product_id is null and product.alpha_sku = row_data.normalized_data ->> 'alphaSku'))
      join public.locations location on location.company_id = v_batch.company_id
        and location.external_code = row_data.normalized_data ->> 'locationCode'
      where row_data.import_batch_id = p_import_batch_id and row_data.detected_type = 'inventory'
        and coalesce((row_data.normalized_data ->> 'rejected')::boolean, false) = false;
      get diagnostics v_records = row_count;
    else raise exception 'Tipo de archivo no compatible.';
    end if;
    update public.import_batches set status = 'completed', records_imported = v_records,
      completed_at = now(), closed_at = now(), last_activity_at = now(), notes = null where id = p_import_batch_id;
    insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
    values (v_batch.company_id, auth.uid(), 'import.completed', 'import_batch', p_import_batch_id,
      jsonb_build_object('import_type', v_batch.import_type, 'records_imported', v_records,
        'original_name', v_file_name, 'snapshot_date', v_batch.snapshot_date));
  exception when others then v_error := sqlerrm;
  end;
  if v_error is not null then
    update public.import_batches set status = 'failed', completed_at = now(), closed_at = now(),
      last_activity_at = now(), notes = v_error where id = p_import_batch_id;
    insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
    values (v_batch.company_id, auth.uid(), 'import.failed', 'import_batch', p_import_batch_id,
      jsonb_build_object('import_type', v_batch.import_type, 'original_name', v_file_name, 'error', v_error));
    return jsonb_build_object('status', 'failed', 'message', v_error, 'batch_id', p_import_batch_id);
  end if;
  return jsonb_build_object('status', 'completed', 'records_imported', v_records, 'batch_id', p_import_batch_id);
end;
$$;

create or replace function public.maintain_import_staging()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_expired integer := 0; v_purged integer := 0; v_batch record;
begin
  for v_batch in
    with expired_batches as (
      update public.import_batches
      set status = 'expired', closed_at = now(), completed_at = coalesce(completed_at, now())
      where status in ('staged', 'validation_failed')
        and last_activity_at < now() - interval '30 days'
      returning id, company_id
    )
    select id, company_id from expired_batches
  loop
    v_expired := v_expired + 1;
    insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
    values (v_batch.company_id, null, 'import.expired', 'import_batch', v_batch.id,
      jsonb_build_object('inactive_days', 30));
  end loop;
  for v_batch in select id, company_id from public.import_batches
    where status in ('completed', 'failed', 'discarded', 'expired') and staging_purged_at is null
      and closed_at < now() - interval '90 days'
  loop
    insert into public.audit_log (company_id, actor_id, action, entity_type, entity_id, metadata)
    values (v_batch.company_id, null, 'import.staging_purged', 'import_batch', v_batch.id,
      jsonb_build_object('retention_days', 90));
    delete from public.import_staging_errors where import_batch_id = v_batch.id;
    delete from public.import_staging_rows where import_batch_id = v_batch.id;
    update public.import_batches set staging_purged_at = now() where id = v_batch.id;
    v_purged := v_purged + 1;
  end loop;
  return jsonb_build_object('expired', v_expired, 'purged', v_purged);
end;
$$;

revoke all on function public.refresh_import_staging_batch(uuid, boolean) from public, authenticated;
revoke all on function public.maintain_import_staging() from public, authenticated;
revoke all on function public.resolve_staged_product(uuid, uuid, uuid, text) from public;
revoke all on function public.acknowledge_staged_warnings(uuid, text, text) from public;
revoke all on function public.discard_staged_import(uuid, text) from public;
revoke all on function public.retry_staged_import(uuid, text) from public;
revoke all on function public.get_import_staging_preview(uuid, integer, integer, text, text) from public;
grant execute on function public.resolve_staged_product(uuid, uuid, uuid, text) to authenticated;
grant execute on function public.acknowledge_staged_warnings(uuid, text, text) to authenticated;
grant execute on function public.discard_staged_import(uuid, text) to authenticated;
grant execute on function public.retry_staged_import(uuid, text) to authenticated;
grant execute on function public.get_import_staging_preview(uuid, integer, integer, text, text) to authenticated;

create extension if not exists pg_cron with schema pg_catalog;
do $$
declare v_job_id bigint;
begin
  select jobid into v_job_id from cron.job where jobname = 'satrapy-import-staging-maintenance' limit 1;
  if v_job_id is not null then perform cron.unschedule(v_job_id); end if;
  perform cron.schedule('satrapy-import-staging-maintenance', '17 3 * * *',
    'select public.maintain_import_staging();');
end;
$$;

select public.refresh_import_staging_batch(id, false)
from public.import_batches
where status in ('staged', 'validation_failed');
