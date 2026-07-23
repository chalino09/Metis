-- Satrapy · Task 2.5 acceptance test
-- Run only after migration 006. Every fixture and business write is rolled back.
begin;

do $test$
declare
  v_actor uuid;
  v_company uuid;
  v_other_company uuid;
  v_product uuid;
  v_other_product uuid;
  v_batch uuid;
  v_failed_batch uuid;
  v_retry_batch uuid;
  v_completed_batch uuid;
  v_expired_batch uuid;
  v_result jsonb;
  v_locations_before bigint;
  v_snapshots_before bigint;
  v_items_before bigint;
  v_audit_before bigint;
begin
  select ur.user_id into v_actor
  from public.user_roles ur join public.roles role_data on role_data.id = ur.role_id
  where role_data.code = 'super_admin' limit 1;
  if v_actor is null then raise exception 'La prueba requiere un usuario Super Admin existente.'; end if;
  perform set_config('request.jwt.claim.sub', v_actor::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  insert into public.companies (legal_name, display_name)
  values ('Satrapy prueba transaccional', 'Satrapy prueba transaccional') returning id into v_company;
  insert into public.companies (legal_name, display_name)
  values ('Satrapy prueba otra empresa', 'Satrapy prueba otra empresa') returning id into v_other_company;
  insert into public.products (company_id, alpha_sku, name, unit)
  values (v_company, 'T25-PRODUCTO', 'Producto de prueba transaccional', 'PZA') returning id into v_product;
  insert into public.products (company_id, alpha_sku, name, unit)
  values (v_other_company, 'T25-OTRO', 'Producto de otra empresa', 'PZA') returning id into v_other_product;

  -- Quarantine: a rejected row keeps its original cells and row number.
  v_result := public.stage_alpha_import(v_company, 'products', 'manual_upload', 'cata_prd_t25_rejected.XLS',
    'xls', encode(gen_random_bytes(32), 'hex'), null,
    jsonb_build_array(jsonb_build_object('row_number', 7, 'source_file', 'cata_prd_t25_rejected.XLS',
      'detected_type', 'products', 'raw_data', jsonb_build_object('cells', jsonb_build_array('', 'SIN SKU')),
      'normalized_data', jsonb_build_object('alphaSku', null, 'name', 'SIN SKU', 'rejected', true),
      'validation_status', 'error')),
    jsonb_build_array(jsonb_build_object('severity', 'error', 'error_code', 'SKU_FALTANTE',
      'message', 'Producto sin SKU', 'row_number', 7)));
  v_batch := (v_result ->> 'batch_id')::uuid;
  if not exists (select 1 from public.import_staging_rows where import_batch_id = v_batch
      and row_number = 7 and raw_data -> 'cells' = jsonb_build_array('', 'SIN SKU')) then
    raise exception 'Falló la conservación de raw_data para una fila rechazada.';
  end if;
  if not exists (select 1 from public.import_staging_errors where import_batch_id = v_batch
      and staging_row_id is not null and error_code = 'SKU_FALTANTE') then
    raise exception 'La incidencia no quedó relacionada con staging_row_id.';
  end if;

  -- Controlled mapping rejects another company and accepts an active product in the batch company.
  v_result := public.stage_alpha_import(v_company, 'inventory', 'manual_upload', 'reexic2_t25_mapping.XLS',
    'xls', encode(gen_random_bytes(32), 'hex'), date '2026-07-07',
    jsonb_build_array(jsonb_build_object('row_number', 9, 'source_file', 'reexic2_t25_mapping.XLS',
      'detected_type', 'inventory', 'raw_data', jsonb_build_object('cells', jsonb_build_array('ORIGINAL-X')),
      'normalized_data', jsonb_build_object('alphaSku', 'ORIGINAL-X', 'description', 'No catalogado',
        'locationCode', 'T25-A', 'locationName', 'Almacén prueba', 'locationType', 'almacen_operativo',
        'classificationSource', 'manual_review', 'quantity', 1, 'unit', 'PZA'), 'validation_status', 'error')),
    jsonb_build_array(jsonb_build_object('severity', 'error', 'error_code', 'PRODUCTO_INEXISTENTE',
      'message', 'Producto inexistente', 'row_number', 9, 'alpha_sku', 'ORIGINAL-X')));
  v_batch := (v_result ->> 'batch_id')::uuid;
  begin
    perform public.resolve_staged_product(v_batch,
      (select id from public.import_staging_rows where import_batch_id = v_batch), v_other_product, 'Prueba empresa incorrecta');
    raise exception 'El mapeo permitió un producto de otra empresa.';
  exception when others then
    if sqlerrm = 'El mapeo permitió un producto de otra empresa.' then raise; end if;
  end;
  perform public.resolve_staged_product(v_batch,
    (select id from public.import_staging_rows where import_batch_id = v_batch), v_product, 'Correspondencia revisada');
  if (select blocking_error_count from public.import_batches where id = v_batch) <> 0 then
    raise exception 'El mapeo válido no resolvió el error pendiente.';
  end if;

  -- Warning acknowledgement remains visible but is no longer pending.
  insert into public.import_staging_errors (import_batch_id, staging_row_id, severity, error_code, message, row_number)
  select v_batch, id, 'warning', 'TOTAL_NO_CUADRA', 'Total no cuadra', row_number
  from public.import_staging_rows where import_batch_id = v_batch;
  perform public.refresh_import_staging_batch(v_batch, true);
  perform public.acknowledge_staged_warnings(v_batch, 'TOTAL_NO_CUADRA', 'Revisado contra el reporte fuente');
  if (select pending_warning_count from public.import_batches where id = v_batch) <> 0
    or (select warning_rows from public.import_batches where id = v_batch) <> 1 then
    raise exception 'El reconocimiento de warnings no conservó el historial correctamente.';
  end if;

  -- Atomic rollback: duplicate product/location rows force the final item insert to fail.
  v_result := public.stage_alpha_import(v_company, 'inventory', 'manual_upload', 'reexic2_t25_atomic.XLS',
    'xls', encode(gen_random_bytes(32), 'hex'), date '2026-07-07',
    jsonb_build_array(
      jsonb_build_object('row_number', 10, 'source_file', 'reexic2_t25_atomic.XLS', 'detected_type', 'inventory',
        'raw_data', jsonb_build_object('cells', jsonb_build_array('T25-PRODUCTO', 1)),
        'normalized_data', jsonb_build_object('alphaSku', 'T25-PRODUCTO', 'description', 'Producto',
          'locationCode', 'T25-ATOMIC', 'locationName', 'Almacén atómico', 'locationType', 'almacen_operativo',
          'classificationSource', 'manual_review', 'quantity', 1, 'unit', 'PZA'), 'validation_status', 'valid'),
      jsonb_build_object('row_number', 11, 'source_file', 'reexic2_t25_atomic.XLS', 'detected_type', 'inventory',
        'raw_data', jsonb_build_object('cells', jsonb_build_array('T25-PRODUCTO', 2)),
        'normalized_data', jsonb_build_object('alphaSku', 'T25-PRODUCTO', 'description', 'Producto',
          'locationCode', 'T25-ATOMIC', 'locationName', 'Almacén atómico', 'locationType', 'almacen_operativo',
          'classificationSource', 'manual_review', 'quantity', 2, 'unit', 'PZA'), 'validation_status', 'valid')),
    '[]'::jsonb);
  v_failed_batch := (v_result ->> 'batch_id')::uuid;
  select count(*) into v_locations_before from public.locations;
  select count(*) into v_snapshots_before from public.inventory_snapshots;
  select count(*) into v_items_before from public.inventory_snapshot_items;
  v_result := public.confirm_staged_import(v_failed_batch);
  if v_result ->> 'status' <> 'failed' then raise exception 'No se produjo el fallo transaccional esperado.'; end if;
  if v_locations_before <> (select count(*) from public.locations)
    or v_snapshots_before <> (select count(*) from public.inventory_snapshots)
    or v_items_before <> (select count(*) from public.inventory_snapshot_items) then
    raise exception 'La importación fallida dejó datos de negocio parciales.';
  end if;

  v_result := public.retry_staged_import(v_failed_batch, 'Reintento después de validar atomicidad');
  v_retry_batch := (v_result ->> 'batch_id')::uuid;
  if (select retry_of_batch_id from public.import_batches where id = v_retry_batch) <> v_failed_batch
    or not exists (select 1 from public.import_staging_rows where import_batch_id = v_retry_batch) then
    raise exception 'El reintento no conservó trazabilidad o staging.';
  end if;
  perform public.discard_staged_import(v_retry_batch, 'Cierre de prueba');

  -- Completed hashes are idempotent.
  v_result := public.stage_alpha_import(v_company, 'products', 'manual_upload', 'cata_prd_t25_duplicate.XLS',
    'xls', repeat('a', 64), null,
    jsonb_build_array(jsonb_build_object('row_number', 7, 'source_file', 'cata_prd_t25_duplicate.XLS',
      'detected_type', 'products', 'raw_data', jsonb_build_object('cells', jsonb_build_array('T25-NEW')),
      'normalized_data', jsonb_build_object('alphaSku', 'T25-NEW', 'name', 'Producto idempotente', 'unit', 'PZA'),
      'validation_status', 'valid')), '[]'::jsonb);
  v_completed_batch := (v_result ->> 'batch_id')::uuid;
  v_result := public.confirm_staged_import(v_completed_batch);
  if v_result ->> 'status' <> 'completed' then raise exception 'No se completó el lote para probar duplicados.'; end if;
  v_result := public.stage_alpha_import(v_company, 'products', 'manual_upload', 'cata_prd_t25_duplicate.XLS',
    'xls', repeat('a', 64), null, '[]'::jsonb, '[]'::jsonb);
  if v_result ->> 'status' <> 'duplicate' then raise exception 'No se bloqueó el hash ya completado.'; end if;

  -- Expiry after 30 days and purge after 90 days keep batch and audit permanently.
  v_result := public.stage_alpha_import(v_company, 'products', 'manual_upload', 'cata_prd_t25_expiry.XLS',
    'xls', encode(gen_random_bytes(32), 'hex'), null,
    jsonb_build_array(jsonb_build_object('row_number', 7, 'source_file', 'cata_prd_t25_expiry.XLS',
      'detected_type', 'products', 'raw_data', jsonb_build_object('cells', jsonb_build_array('EXPIRA')),
      'normalized_data', jsonb_build_object('alphaSku', 'EXPIRA', 'name', 'Expira'), 'validation_status', 'valid')),
    '[]'::jsonb);
  v_expired_batch := (v_result ->> 'batch_id')::uuid;
  update public.import_batches set last_activity_at = now() - interval '31 days' where id = v_expired_batch;
  perform public.maintain_import_staging();
  if (select status from public.import_batches where id = v_expired_batch) <> 'expired' then
    raise exception 'El staging inactivo no venció a los 30 días.';
  end if;
  select count(*) into v_audit_before from public.audit_log where entity_id = v_expired_batch;
  update public.import_batches set closed_at = now() - interval '91 days' where id = v_expired_batch;
  perform public.maintain_import_staging();
  if exists (select 1 from public.import_staging_rows where import_batch_id = v_expired_batch)
    or (select staging_purged_at from public.import_batches where id = v_expired_batch) is null
    or (select count(*) from public.audit_log where entity_id = v_expired_batch) <= v_audit_before then
    raise exception 'La purga no eliminó solo staging o no conservó/amplió auditoría.';
  end if;

  -- Permission matrix for staging operations.
  if exists (
    select 1 from public.roles role_data
    join public.role_permissions rp on rp.role_id = role_data.id
    join public.permissions permission_data on permission_data.id = rp.permission_id
    where role_data.code in ('sucursal', 'ingeniero_campo', 'almacen', 'punto_venta')
      and permission_data.code = 'import_data'
  ) then raise exception 'Un rol operativo conserva import_data.'; end if;
  if not exists (
    select 1 from public.roles role_data
    join public.role_permissions rp on rp.role_id = role_data.id
    join public.permissions permission_data on permission_data.id = rp.permission_id
    where role_data.code = 'direccion_admin' and permission_data.code = 'import_data'
  ) then raise exception 'Dirección/Admin no tiene import_data.'; end if;

  raise notice 'Tarea 2.5: pruebas transaccionales, staging, idempotencia, retención y permisos aprobadas.';
end;
$test$;

rollback;
