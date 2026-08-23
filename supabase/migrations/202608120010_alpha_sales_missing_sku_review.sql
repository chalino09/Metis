-- A sales line without Alpha's source SKU can be linked to a canonical
-- product in staging. The missing source value is never manufactured or
-- overwritten; this is an auditable evidence mapping only.

create or replace function public.get_alpha_sales_missing_sku_review(
  p_import_batch_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch public.import_batches%rowtype;
  v_groups jsonb;
  v_total integer;
begin
  select * into v_batch
  from public.import_batches
  where id = p_import_batch_id;

  if not found then raise exception 'Lote no encontrado.'; end if;
  if v_batch.import_type <> 'sales' then raise exception 'Esta revisión solo está disponible para ventas históricas.'; end if;
  if auth.uid() is null or not public.can_import_commercial(v_batch.company_id, 'sales') then
    raise exception 'No autorizado para revisar partidas de ventas.';
  end if;

  with missing_rows as (
    select
      row_data.id,
      row_data.row_number,
      coalesce(nullif(trim(row_data.normalized_data ->> 'description'), ''), '') as source_description,
      coalesce(nullif(trim(row_data.normalized_data ->> 'unit'), ''), '') as source_unit,
      coalesce(nullif(row_data.normalized_data ->> 'lineTotal', '')::numeric, 0) as line_total,
      nullif(row_data.normalized_data ->> 'sourceInvoice', '') as source_invoice
    from public.import_staging_rows row_data
    where row_data.import_batch_id = p_import_batch_id
      and row_data.detected_type = 'sales'
      and exists (
        select 1
        from public.import_staging_errors error_data
        where error_data.import_batch_id = p_import_batch_id
          and error_data.staging_row_id = row_data.id
          and error_data.error_code = 'SKU_FALTANTE'
          and error_data.severity = 'error'
          and error_data.resolved_at is null
      )
  ), grouped as (
    select
      source_description,
      source_unit,
      count(*)::integer as row_count,
      coalesce(sum(line_total), 0) as amount,
      array_agg(row_number order by row_number) as row_numbers,
      array_agg(distinct source_invoice) filter (where source_invoice is not null) as source_invoices
    from missing_rows
    group by source_description, source_unit
  )
  select
    coalesce(sum(row_count), 0)::integer,
    coalesce(jsonb_agg(jsonb_build_object(
      'description', source_description,
      'unit', nullif(source_unit, ''),
      'row_count', row_count,
      'amount', amount,
      'row_numbers', to_jsonb(row_numbers),
      'source_invoices', coalesce(to_jsonb(source_invoices), '[]'::jsonb),
      'can_map', source_description <> ''
    ) order by row_count desc, source_description), '[]'::jsonb)
  into v_total, v_groups
  from grouped;

  return jsonb_build_object('total_rows', v_total, 'groups', v_groups);
end;
$$;

create or replace function public.resolve_alpha_sales_missing_sku(
  p_import_batch_id uuid,
  p_source_description text,
  p_source_unit text default null,
  p_product_id uuid default null,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch public.import_batches%rowtype;
  v_product public.products%rowtype;
  v_row_ids uuid[];
  v_before_valid integer;
  v_before_warning integer;
  v_before_error integer;
  v_after_valid integer;
  v_after_warning integer;
  v_after_error integer;
  v_updated integer;
begin
  if nullif(trim(p_source_description), '') is null then
    raise exception 'La partida no tiene descripción; no se puede vincular con seguridad.';
  end if;
  if p_product_id is null then raise exception 'Selecciona un producto canónico.'; end if;
  if nullif(trim(p_reason), '') is null then raise exception 'Indica el motivo del mapeo.'; end if;

  select * into v_batch
  from public.import_batches
  where id = p_import_batch_id
  for update;

  if not found then raise exception 'Lote no encontrado.'; end if;
  if v_batch.import_type <> 'sales' then raise exception 'Esta revisión solo está disponible para ventas históricas.'; end if;
  if auth.uid() is null or not public.can_import_commercial(v_batch.company_id, 'sales') then
    raise exception 'No autorizado para revisar partidas de ventas.';
  end if;
  if v_batch.status not in ('staged', 'validation_failed') then raise exception 'El lote ya no admite cambios.'; end if;

  select * into v_product
  from public.products
  where id = p_product_id
    and company_id = v_batch.company_id
    and is_active = true;

  if not found then raise exception 'El producto seleccionado no pertenece a la empresa o está inactivo.'; end if;

  with target_rows as (
    select row_data.id, row_data.validation_status
    from public.import_staging_rows row_data
    where row_data.import_batch_id = p_import_batch_id
      and row_data.detected_type = 'sales'
      and coalesce(nullif(trim(row_data.normalized_data ->> 'description'), ''), '') = trim(p_source_description)
      and coalesce(nullif(trim(row_data.normalized_data ->> 'unit'), ''), '') = coalesce(nullif(trim(p_source_unit), ''), '')
      and exists (
        select 1
        from public.import_staging_errors error_data
        where error_data.import_batch_id = p_import_batch_id
          and error_data.staging_row_id = row_data.id
          and error_data.error_code = 'SKU_FALTANTE'
          and error_data.severity = 'error'
          and error_data.resolved_at is null
      )
  )
  select
    array_agg(id),
    count(*) filter (where validation_status = 'valid')::integer,
    count(*) filter (where validation_status = 'warning')::integer,
    count(*) filter (where validation_status = 'error')::integer
  into v_row_ids, v_before_valid, v_before_warning, v_before_error
  from target_rows;

  if coalesce(array_length(v_row_ids, 1), 0) = 0 then
    raise exception 'No hay partidas pendientes para esta descripción y unidad.';
  end if;

  update public.import_staging_errors
  set resolved_by = auth.uid(),
      resolved_at = now(),
      resolution_note = trim(p_reason)
  where import_batch_id = p_import_batch_id
    and staging_row_id = any(v_row_ids)
    and error_code = 'SKU_FALTANTE'
    and severity = 'error'
    and resolved_at is null;

  update public.import_staging_rows row_data
  set resolved_product_id = p_product_id,
      resolved_by = auth.uid(),
      resolved_at = now(),
      resolution_reason = trim(p_reason),
      validation_status = case
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
            and error_data.acknowledged_at is null
        ) then 'warning'
        else 'valid'
      end
  where row_data.id = any(v_row_ids);

  get diagnostics v_updated = row_count;

  select
    count(*) filter (where validation_status = 'valid')::integer,
    count(*) filter (where validation_status = 'warning')::integer,
    count(*) filter (where validation_status = 'error')::integer
  into v_after_valid, v_after_warning, v_after_error
  from public.import_staging_rows
  where id = any(v_row_ids);

  update public.import_batches
  set valid_rows = greatest(0, valid_rows - coalesce(v_before_valid, 0) + coalesce(v_after_valid, 0)),
      warning_rows = greatest(0, warning_rows - coalesce(v_before_warning, 0) + coalesce(v_after_warning, 0)),
      error_rows = greatest(0, error_rows - coalesce(v_before_error, 0) + coalesce(v_after_error, 0))
  where id = p_import_batch_id;

  perform public.refresh_import_staging_issue_summary(p_import_batch_id, true);

  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values (
    v_batch.company_id,
    auth.uid(),
    'sales_evidence.missing_sku_mapped',
    'import_batch',
    p_import_batch_id,
    jsonb_build_object(
      'source_description', trim(p_source_description),
      'source_unit', nullif(trim(coalesce(p_source_unit, '')), ''),
      'rows', v_updated,
      'product_id', v_product.id,
      'product_alpha_sku', v_product.alpha_sku,
      'reason', trim(p_reason),
      'source_sku_preserved_as_missing', true
    )
  );

  return jsonb_build_object(
    'status', 'resolved',
    'rows', v_updated,
    'product_id', v_product.id,
    'product_alpha_sku', v_product.alpha_sku
  );
end;
$$;

revoke all on function public.get_alpha_sales_missing_sku_review(uuid) from public, anon;
revoke all on function public.resolve_alpha_sales_missing_sku(uuid, text, text, uuid, text) from public, anon;
grant execute on function public.get_alpha_sales_missing_sku_review(uuid) to authenticated;
grant execute on function public.resolve_alpha_sales_missing_sku(uuid, text, text, uuid, text) to authenticated;
