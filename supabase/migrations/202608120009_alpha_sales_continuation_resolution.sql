-- Some Alpha XLS rows contain a product description wrapped onto a second
-- physical row. The continuation has no SKU, quantity or amount of its own.
-- Resolve only when the preceding row carries a canonical SKU and all sale
-- context is identical. The concatenated description is reported as evidence
-- and compared to the catalog when available, but the source SKU remains the
-- canonical identifier of the preceding line.

create or replace function public.get_alpha_sales_missing_sku_continuation_review(
  p_import_batch_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch public.import_batches%rowtype;
  v_items jsonb;
  v_total integer;
  v_eligible integer;
begin
  select * into v_batch from public.import_batches where id = p_import_batch_id;
  if not found then raise exception 'Lote no encontrado.'; end if;
  if v_batch.import_type <> 'sales' then raise exception 'Esta revisión solo está disponible para ventas históricas.'; end if;
  if auth.uid() is null or not public.can_import_commercial(v_batch.company_id, 'sales') then
    raise exception 'No autorizado para revisar partidas de ventas.';
  end if;

  with candidates as (
    select
      missing.row_number,
      missing.normalized_data as missing_data,
      previous.row_number as previous_row_number,
      previous.normalized_data as previous_data,
      product.id as product_id,
      product.alpha_sku as product_alpha_sku,
      product.name as product_name,
      product.unit as product_unit,
      regexp_replace(lower(trim(coalesce(previous.normalized_data ->> 'description', '') || ' ' || coalesce(missing.normalized_data ->> 'description', ''))), '\\s+', ' ', 'g') = regexp_replace(lower(trim(product.name)), '\\s+', ' ', 'g') as catalog_match
    from public.import_staging_rows missing
    join public.import_staging_rows previous
      on previous.import_batch_id = missing.import_batch_id
     and previous.row_number = missing.row_number - 1
    join public.products product
      on product.company_id = v_batch.company_id
     and product.is_active = true
     and product.alpha_sku = nullif(trim(previous.normalized_data ->> 'alphaSku'), '')
    where missing.import_batch_id = p_import_batch_id
      and missing.detected_type = 'sales'
      and missing.validation_status = 'error'
      and nullif(trim(missing.normalized_data ->> 'description'), '') is not null
      and not (missing.normalized_data ? 'quantity')
      and not (missing.normalized_data ? 'lineTotal')
      and not (missing.normalized_data ? 'lineAmount')
      and not (missing.normalized_data ? 'unitPrice')
      and previous.validation_status in ('valid', 'warning')
      and nullif(trim(previous.normalized_data ->> 'alphaSku'), '') is not null
      and coalesce(missing.normalized_data ->> 'saleDate', '') = coalesce(previous.normalized_data ->> 'saleDate', '')
      and coalesce(missing.normalized_data ->> 'sourceFolio', '') = coalesce(previous.normalized_data ->> 'sourceFolio', '')
      and coalesce(missing.normalized_data ->> 'sourceInvoice', '') = coalesce(previous.normalized_data ->> 'sourceInvoice', '')
      and coalesce(missing.normalized_data ->> 'customerName', '') = coalesce(previous.normalized_data ->> 'customerName', '')
      and coalesce(missing.normalized_data ->> 'locationCode', '') = coalesce(previous.normalized_data ->> 'locationCode', '')
  ), shaped as (
    select *, count(*) over ()::integer as total_count,
      count(*) filter (where catalog_match) over ()::integer as eligible_count
    from candidates
  )
  select
    coalesce(max(total_count), 0),
    coalesce(max(eligible_count), 0),
    coalesce(jsonb_agg(jsonb_build_object(
      'row_number', row_number,
      'previous_row_number', previous_row_number,
      'fragment', missing_data ->> 'description',
      'previous_description', previous_data ->> 'description',
      'full_description', trim(coalesce(previous_data ->> 'description', '') || ' ' || coalesce(missing_data ->> 'description', '')),
      'product_id', product_id,
      'product_alpha_sku', product_alpha_sku,
      'product_name', product_name,
      'product_unit', product_unit,
      'catalog_match', catalog_match,
      'source_invoice', missing_data ->> 'sourceInvoice',
      'source_folio', missing_data ->> 'sourceFolio'
    ) order by row_number), '[]'::jsonb)
  into v_total, v_eligible, v_items
  from shaped;

  return jsonb_build_object('total_rows', v_total, 'eligible_rows', v_eligible, 'items', v_items);
end;
$$;

create or replace function public.resolve_alpha_sales_missing_sku_continuations(
  p_import_batch_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch public.import_batches%rowtype;
  v_ids uuid[];
  v_before_valid integer;
  v_before_warning integer;
  v_before_error integer;
  v_after_valid integer;
  v_after_warning integer;
  v_after_error integer;
  v_updated integer;
begin
  if nullif(trim(p_reason), '') is null then raise exception 'Indica el motivo del vínculo.'; end if;
  select * into v_batch from public.import_batches where id = p_import_batch_id for update;
  if not found then raise exception 'Lote no encontrado.'; end if;
  if v_batch.import_type <> 'sales' then raise exception 'Esta revisión solo está disponible para ventas históricas.'; end if;
  if auth.uid() is null or not public.can_import_commercial(v_batch.company_id, 'sales') then raise exception 'No autorizado para revisar partidas de ventas.'; end if;
  if v_batch.status not in ('staged', 'validation_failed') then raise exception 'El lote ya no admite cambios.'; end if;

  create temporary table if not exists _alpha_missing_continuations (
    row_id uuid primary key,
    row_number integer not null,
    product_id uuid not null
  ) on commit drop;
  truncate _alpha_missing_continuations;

  insert into _alpha_missing_continuations(row_id, row_number, product_id)
  select missing.id, missing.row_number, product.id
  from public.import_staging_rows missing
  join public.import_staging_rows previous
    on previous.import_batch_id = missing.import_batch_id
   and previous.row_number = missing.row_number - 1
  join public.products product
    on product.company_id = v_batch.company_id
   and product.is_active = true
   and product.alpha_sku = nullif(trim(previous.normalized_data ->> 'alphaSku'), '')
  where missing.import_batch_id = p_import_batch_id
    and missing.detected_type = 'sales'
    and missing.validation_status = 'error'
    and not (missing.normalized_data ? 'quantity')
    and not (missing.normalized_data ? 'lineTotal')
    and not (missing.normalized_data ? 'lineAmount')
    and not (missing.normalized_data ? 'unitPrice')
    and previous.validation_status in ('valid', 'warning')
    and nullif(trim(previous.normalized_data ->> 'alphaSku'), '') is not null
    and nullif(trim(missing.normalized_data ->> 'description'), '') is not null
    and coalesce(missing.normalized_data ->> 'saleDate', '') = coalesce(previous.normalized_data ->> 'saleDate', '')
    and coalesce(missing.normalized_data ->> 'sourceFolio', '') = coalesce(previous.normalized_data ->> 'sourceFolio', '')
    and coalesce(missing.normalized_data ->> 'sourceInvoice', '') = coalesce(previous.normalized_data ->> 'sourceInvoice', '')
    and coalesce(missing.normalized_data ->> 'customerName', '') = coalesce(previous.normalized_data ->> 'customerName', '')
    and coalesce(missing.normalized_data ->> 'locationCode', '') = coalesce(previous.normalized_data ->> 'locationCode', '');

  select array_agg(row_id), count(*)::integer into v_ids, v_updated from _alpha_missing_continuations;
  if coalesce(v_updated, 0) = 0 then raise exception 'No hay continuaciones de descripción verificables para este lote.'; end if;

  select count(*) filter (where validation_status = 'valid')::integer, count(*) filter (where validation_status = 'warning')::integer, count(*) filter (where validation_status = 'error')::integer
    into v_before_valid, v_before_warning, v_before_error
  from public.import_staging_rows where id = any(v_ids);

  update public.import_staging_errors error_data
  set resolved_by = auth.uid(), resolved_at = now(), resolution_note = trim(p_reason)
  where error_data.import_batch_id = p_import_batch_id and error_data.staging_row_id = any(v_ids) and error_data.error_code = 'SKU_FALTANTE' and error_data.severity = 'error' and error_data.resolved_at is null;

  update public.import_staging_rows row_data
  set resolved_product_id = target.product_id, resolved_by = auth.uid(), resolved_at = now(), resolution_reason = trim(p_reason), validation_status = case
    when exists (select 1 from public.import_staging_errors e where e.import_batch_id = row_data.import_batch_id and e.staging_row_id = row_data.id and e.severity = 'error' and e.resolved_at is null) then 'error'
    when exists (select 1 from public.import_staging_errors e where e.import_batch_id = row_data.import_batch_id and e.staging_row_id = row_data.id and e.severity = 'warning' and e.acknowledged_at is null) then 'warning'
    else 'valid' end
  from _alpha_missing_continuations target
  where row_data.id = target.row_id;

  select count(*) filter (where validation_status = 'valid')::integer, count(*) filter (where validation_status = 'warning')::integer, count(*) filter (where validation_status = 'error')::integer
    into v_after_valid, v_after_warning, v_after_error
  from public.import_staging_rows where id = any(v_ids);

  update public.import_batches set valid_rows = greatest(0, valid_rows - coalesce(v_before_valid, 0) + coalesce(v_after_valid, 0)), warning_rows = greatest(0, warning_rows - coalesce(v_before_warning, 0) + coalesce(v_after_warning, 0)), error_rows = greatest(0, error_rows - coalesce(v_before_error, 0) + coalesce(v_after_error, 0)) where id = p_import_batch_id;
  perform public.refresh_import_staging_issue_summary(p_import_batch_id, true);

  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_batch.company_id, auth.uid(), 'sales_evidence.missing_sku_continuations_mapped', 'import_batch', p_import_batch_id, jsonb_build_object('rows', v_updated, 'row_numbers', (select jsonb_agg(row_number order by row_number) from _alpha_missing_continuations), 'reason', trim(p_reason), 'method', 'previous_row_canonical_sku_plus_catalog_description', 'source_sku_preserved_as_missing', true));

  return jsonb_build_object('status', 'resolved', 'rows', v_updated, 'method', 'previous_row_canonical_sku_plus_catalog_description');
end;
$$;

revoke all on function public.get_alpha_sales_missing_sku_continuation_review(uuid) from public, anon;
revoke all on function public.resolve_alpha_sales_missing_sku_continuations(uuid, text) from public, anon;
grant execute on function public.get_alpha_sales_missing_sku_continuation_review(uuid) to authenticated;
grant execute on function public.resolve_alpha_sales_missing_sku_continuations(uuid, text) to authenticated;
