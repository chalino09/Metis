-- Clasificación fiscal de CAT PROD en el flujo de staging ya existente.
-- No crea un importador paralelo ni altera readiness, surtidos o POS.

begin;

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
      -- The parser only stages IVA16 and IVA0. Re-check the payload here so
      -- hand-edited staging cannot bypass the fiscal interpretation.
      if exists (
        select 1
        from public.import_staging_rows row_data
        where row_data.import_batch_id = p_import_batch_id
          and row_data.detected_type = 'products'
          and coalesce((row_data.normalized_data ->> 'rejected')::boolean, false) = false
          and (
            (row_data.normalized_data ->> 'taxCategoryCode', row_data.normalized_data ->> 'taxRate') not in (
              ('IVA16', '0.16'), ('IVA16', '0.160000'), ('IVA0', '0')
            )
          )
      ) then
        raise exception 'El staging de productos contiene una clasificación fiscal inválida.';
      end if;

      insert into public.tax_categories (company_id, code, name, is_active)
      select distinct v_batch.company_id,
        row_data.normalized_data ->> 'taxCategoryCode',
        case row_data.normalized_data ->> 'taxCategoryCode'
          when 'IVA16' then 'IVA 16%'
          when 'IVA0' then 'IVA tasa 0%'
        end,
        true
      from public.import_staging_rows row_data
      where row_data.import_batch_id = p_import_batch_id
        and row_data.detected_type = 'products'
        and coalesce((row_data.normalized_data ->> 'rejected')::boolean, false) = false
      on conflict (company_id, code) do update set
        name = excluded.name,
        is_active = true;

      if exists (
        select 1
        from public.tax_categories category
        join public.tax_rates rate on rate.tax_category_id = category.id
        join (values ('IVA16'::text, 0.16::numeric), ('IVA0'::text, 0::numeric)) expected(code, tax_rate)
          on expected.code = category.code
        where category.company_id = v_batch.company_id
          and rate.jurisdiction_code = 'MX'
          and rate.valid_from <= now()
          and (rate.valid_to is null or rate.valid_to > now())
          and rate.rate <> expected.tax_rate
      ) then
        raise exception 'Una categoría fiscal canónica tiene una tasa vigente incompatible; corrígela antes de importar.';
      end if;

      insert into public.tax_rates (tax_category_id, jurisdiction_code, rate, valid_from, created_by)
      select category.id, 'MX', expected.tax_rate, now(), auth.uid()
      from public.tax_categories category
      join (values ('IVA16'::text, 0.16::numeric), ('IVA0'::text, 0::numeric)) expected(code, tax_rate)
        on expected.code = category.code
      where category.company_id = v_batch.company_id
        and exists (
          select 1 from public.import_staging_rows row_data
          where row_data.import_batch_id = p_import_batch_id
            and row_data.detected_type = 'products'
            and coalesce((row_data.normalized_data ->> 'rejected')::boolean, false) = false
            and row_data.normalized_data ->> 'taxCategoryCode' = category.code
        )
        and not exists (
          select 1 from public.tax_rates rate
          where rate.tax_category_id = category.id
            and rate.jurisdiction_code = 'MX'
            and rate.valid_from <= now()
            and (rate.valid_to is null or rate.valid_to > now())
        );

      insert into public.products (
        company_id, alpha_sku, alpha_class, name, attribute, unit, product_group, subgroup, product_type, tax_category_id
      )
      select v_batch.company_id, row_data.normalized_data ->> 'alphaSku', nullif(row_data.normalized_data ->> 'alphaClass', ''),
        row_data.normalized_data ->> 'name', nullif(row_data.normalized_data ->> 'attribute', ''),
        nullif(row_data.normalized_data ->> 'unit', ''), nullif(row_data.normalized_data ->> 'productGroup', ''),
        nullif(row_data.normalized_data ->> 'subgroup', ''), nullif(row_data.normalized_data ->> 'productType', ''), category.id
      from public.import_staging_rows row_data
      join public.tax_categories category on category.company_id = v_batch.company_id
        and category.code = row_data.normalized_data ->> 'taxCategoryCode'
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
        product_type = excluded.product_type,
        tax_category_id = excluded.tax_category_id;
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

create or replace function public.get_staged_product_tax_summary(p_import_batch_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_batch public.import_batches%rowtype;
begin
  select * into v_batch from public.import_batches where id = p_import_batch_id;
  if not found then raise exception 'Lote de importación no encontrado.'; end if;
  if auth.uid() is null or not public.has_company_permission(v_batch.company_id, 'import_data') then
    raise exception 'No autorizado.';
  end if;
  if v_batch.import_type <> 'products' then return '[]'::jsonb; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object('tax_category_code', tax_category_code, 'total', total)
      order by tax_category_code)
    from (
      select row_data.normalized_data ->> 'taxCategoryCode' as tax_category_code, count(*) as total
      from public.import_staging_rows row_data
      where row_data.import_batch_id = p_import_batch_id
        and row_data.detected_type = 'products'
        and coalesce((row_data.normalized_data ->> 'rejected')::boolean, false) = false
      group by row_data.normalized_data ->> 'taxCategoryCode'
    ) summary
  ), '[]'::jsonb);
end;
$$;

commit;
