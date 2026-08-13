begin;

do $continuation_resolution$
declare
  v_company uuid := '8a120009-0000-4000-8000-000000000001';
  v_user uuid := '8a120009-0000-4000-8000-000000000010';
  v_batch uuid;
  v_product uuid;
  v_result jsonb;
begin
  insert into public.companies(id, legal_name, display_name) values(v_company, 'Continuación QA', 'Continuación QA');
  insert into auth.users(id, aud, role, email, encrypted_password) values(v_user, 'authenticated', 'authenticated', 'continuation@example.com', '');
  insert into public.user_roles(user_id, role_id, company_id) select v_user, id, v_company from public.roles where code = 'direccion_admin';
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', v_user::text, true);

  insert into public.products(company_id, alpha_sku, name, unit) values(v_company, 'CAN-009', 'MANGUERA DE PRUEBA 2" (metro)', 'METRO') returning id into v_product;
  v_result := public.begin_alpha_sales_evidence_file(v_company, 'manual_upload', 'sales', 'nvtadesg_continuation.xls', 'xls', repeat('9', 64), date '2026-08-12');
  v_batch := (v_result ->> 'batch_id')::uuid;
  perform public.stage_alpha_sales_staging_rows(v_batch, jsonb_build_array(
    jsonb_build_object('row_number', 10, 'source_file', 'nvtadesg_continuation.xls', 'detected_type', 'sales', 'raw_data', '{}'::jsonb, 'validation_status', 'valid', 'normalized_data', jsonb_build_object('evidenceKind', 'sale_line', 'alphaSku', 'CAN-009', 'description', 'MANGUERA DE PRUEBA 2"', 'unit', 'METRO', 'quantity', 1, 'lineTotal', 100, 'saleDate', '2026-08-12', 'sourceFolio', 'F-10', 'sourceInvoice', '10', 'customerName', 'Cliente QA', 'locationCode', 'QA')),
    jsonb_build_object('row_number', 11, 'source_file', 'nvtadesg_continuation.xls', 'detected_type', 'sales', 'raw_data', '{}'::jsonb, 'validation_status', 'error', 'normalized_data', jsonb_build_object('evidenceKind', 'sale_line', 'description', '(metro)', 'saleDate', '2026-08-12', 'sourceFolio', 'F-10', 'sourceInvoice', '10', 'customerName', 'Cliente QA', 'locationCode', 'QA'))
  ), jsonb_build_array(jsonb_build_object('severity', 'error', 'error_code', 'SKU_FALTANTE', 'message', 'Partida de continuación sin Clave Prod.', 'row_number', 11)));
  perform public.finish_alpha_sales_evidence_file(v_batch, '[]'::jsonb);

  v_result := public.get_alpha_sales_missing_sku_continuation_review(v_batch);
  if (v_result ->> 'eligible_rows')::integer <> 1 then raise exception 'No se detectó la continuación verificable: %', v_result; end if;
  v_result := public.resolve_alpha_sales_missing_sku_continuations(v_batch, 'Continuación exacta de la fila anterior y catálogo canónico.');
  if (v_result ->> 'rows')::integer <> 1 then raise exception 'No se resolvió la continuación: %', v_result; end if;
  if (select resolved_product_id from public.import_staging_rows where import_batch_id = v_batch and row_number = 11) <> v_product then raise exception 'No se guardó el producto canónico.'; end if;
  if exists(select 1 from public.import_staging_errors where import_batch_id = v_batch and error_code = 'SKU_FALTANTE' and resolved_at is null) then raise exception 'Quedó la incidencia pendiente.'; end if;
  if not exists(select 1 from public.audit_log where entity_id = v_batch and action = 'sales_evidence.missing_sku_continuations_mapped') then raise exception 'No quedó auditoría de la operación.'; end if;
  raise notice 'Continuación de SKU: coincidencia, vínculo transaccional y auditoría comprobados.';
end;
$continuation_resolution$;

rollback;
