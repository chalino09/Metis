begin;

do $sales_missing_sku_review$
declare
  v_company uuid := '8a120008-0000-4000-8000-000000000001';
  v_user uuid := '8a120008-0000-4000-8000-000000000010';
  v_batch uuid;
  v_product uuid;
  v_result jsonb;
begin
  insert into public.companies(id, legal_name, display_name)
  values(v_company, 'SKU faltante QA', 'SKU faltante QA');
  insert into auth.users(id, aud, role, email, encrypted_password)
  values(v_user, 'authenticated', 'authenticated', 'sales-missing-sku@example.com', '');
  insert into public.user_roles(user_id, role_id, company_id)
  select v_user, id, v_company from public.roles where code = 'direccion_admin';
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', v_user::text, true);

  insert into public.products(company_id, alpha_sku, name, unit)
  values(v_company, 'CAN-001', 'Producto canónico', 'PZA')
  returning id into v_product;

  v_result := public.begin_alpha_sales_evidence_file(v_company, 'manual_upload', 'sales', 'nvtadesg_20260812_SKU.xls', 'xls', repeat('8', 64), date '2026-08-12');
  v_batch := (v_result ->> 'batch_id')::uuid;
  perform public.stage_alpha_sales_staging_rows(v_batch, jsonb_build_array(
    jsonb_build_object('row_number', 20, 'source_file', 'nvtadesg_20260812_SKU.xls', 'detected_type', 'sales', 'raw_data', '{}'::jsonb, 'validation_status', 'error', 'normalized_data', jsonb_build_object('evidenceKind', 'sale_line', 'description', 'Producto sin clave', 'unit', 'PZA', 'lineTotal', 50, 'sourceInvoice', 'F-20')),
    jsonb_build_object('row_number', 21, 'source_file', 'nvtadesg_20260812_SKU.xls', 'detected_type', 'sales', 'raw_data', '{}'::jsonb, 'validation_status', 'error', 'normalized_data', jsonb_build_object('evidenceKind', 'sale_line', 'description', 'Producto sin clave', 'unit', 'PZA', 'lineTotal', 75, 'sourceInvoice', 'F-21'))
  ), jsonb_build_array(
    jsonb_build_object('severity', 'error', 'error_code', 'SKU_FALTANTE', 'message', 'Partida de venta sin Clave Prod.', 'row_number', 20),
    jsonb_build_object('severity', 'error', 'error_code', 'SKU_FALTANTE', 'message', 'Partida de venta sin Clave Prod.', 'row_number', 21)
  ));
  perform public.finish_alpha_sales_evidence_file(v_batch, '[]'::jsonb);

  v_result := public.get_alpha_sales_missing_sku_review(v_batch);
  if (v_result ->> 'total_rows')::integer <> 2 or (v_result -> 'groups' -> 0 ->> 'row_count')::integer <> 2 then
    raise exception 'La revisión no agrupó las partidas sin SKU: %', v_result;
  end if;

  v_result := public.resolve_alpha_sales_missing_sku(v_batch, 'Producto sin clave', 'PZA', v_product, 'Mismo producto identificado por descripción y unidad.');
  if (v_result ->> 'rows')::integer <> 2 then raise exception 'El vínculo no cubrió ambas partidas: %', v_result; end if;
  if exists(select 1 from public.import_staging_errors where import_batch_id = v_batch and error_code = 'SKU_FALTANTE' and resolved_at is null) then
    raise exception 'Quedaron SKU_FALTANTE sin resolver.';
  end if;
  if exists(select 1 from public.import_staging_rows where import_batch_id = v_batch and resolved_product_id <> v_product) then
    raise exception 'No se guardó el producto canónico en las partidas.';
  end if;
  if (select blocking_error_count from public.import_batches where id = v_batch) <> 0 then
    raise exception 'El resumen del lote no se actualizó.';
  end if;
  if not exists(select 1 from public.audit_log where entity_id = v_batch and action = 'sales_evidence.missing_sku_mapped') then
    raise exception 'No quedó auditoría del vínculo.';
  end if;
  raise notice 'SKU faltante: revisión agrupada, vínculo canónico y auditoría comprobados.';
end;
$sales_missing_sku_review$;

rollback;
