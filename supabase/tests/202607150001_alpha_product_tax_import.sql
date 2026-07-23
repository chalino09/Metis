-- Regression test for 202607150001. Run after its migration; all fixture data rolls back.
begin;

do $test$
declare
  v_actor uuid;
  v_company uuid := '25000000-0000-4000-8000-000000000001';
  v_batch uuid;
  v_invalid_batch uuid;
  v_catalog_batch uuid;
  v_pending_product uuid;
  v_result jsonb;
  v_rate_count integer;
begin
  select ur.user_id into v_actor
  from public.user_roles ur
  join public.roles role_data on role_data.id = ur.role_id
  where role_data.code = 'super_admin'
  limit 1;
  if v_actor is null then raise exception 'La prueba requiere un Super Admin existente.'; end if;
  perform set_config('request.jwt.claim.sub', v_actor::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  insert into public.companies(id, legal_name, display_name)
  values (v_company, 'Empresa prueba impuesto productos', 'Empresa prueba impuesto productos');
  insert into public.user_roles(user_id, role_id, company_id)
  select v_actor, id, v_company from public.roles where code = 'super_admin'
  on conflict do nothing;

  -- The base catalog is valid without inline tax configuration. It creates a
  -- canonical product that readiness blocks until the fiscal source arrives.
  v_result := public.stage_alpha_import(
    v_company, 'products', 'local_development', 'cata_prd_sin_impuestos.xlsx', 'xlsx', repeat('a', 64), null,
    jsonb_build_array(jsonb_build_object('row_number', 7, 'source_file', 'cata_prd_sin_impuestos.xlsx', 'detected_type', 'products',
      'raw_data', jsonb_build_object('cells', jsonb_build_array('P-PENDIENTE')),
      'normalized_data', jsonb_build_object('alphaSku', 'P-PENDIENTE', 'name', 'Producto pendiente fiscal', 'unit', 'PZA'),
      'validation_status', 'valid')),
    '[]'::jsonb
  );
  v_catalog_batch := (v_result ->> 'batch_id')::uuid;
  v_result := public.confirm_staged_import(v_catalog_batch);
  select id into v_pending_product from public.products where company_id = v_company and alpha_sku = 'P-PENDIENTE';
  if v_result ->> 'status' <> 'completed' or v_pending_product is null
    or (select tax_category_id from public.products where id = v_pending_product) is not null then
    raise exception 'cata_prd sin impuestos no promovió el producto pendiente correctamente.';
  end if;
  if not (public.product_pos_readiness_detail(v_company, v_pending_product) -> 'blockers' @> '["missing_tax_category"]'::jsonb) then
    raise exception 'El producto sin fuente fiscal no quedó bloqueado por readiness.';
  end if;

  v_result := public.stage_alpha_import(
    v_company, 'products', 'local_development', 'cata_prd_impuestos.xlsx', 'xlsx', repeat('b', 64), null,
    jsonb_build_array(
      jsonb_build_object('row_number', 7, 'source_file', 'cata_prd_impuestos.xlsx', 'detected_type', 'products',
        'raw_data', jsonb_build_object('cells', jsonb_build_array('P-IVA16')),
        'normalized_data', jsonb_build_object('alphaSku', 'P-IVA16', 'name', 'Producto IVA 16', 'unit', 'PZA',
          'staiva', '2', 'porceniva', '16', 'taxCategoryCode', 'IVA16', 'taxRate', 0.16),
        'validation_status', 'valid'),
      jsonb_build_object('row_number', 8, 'source_file', 'cata_prd_impuestos.xlsx', 'detected_type', 'products',
        'raw_data', jsonb_build_object('cells', jsonb_build_array('P-IVA0')),
        'normalized_data', jsonb_build_object('alphaSku', 'P-IVA0', 'name', 'Producto IVA cero', 'unit', 'PZA',
          'staiva', '2', 'porceniva', '0', 'taxCategoryCode', 'IVA0', 'taxRate', 0),
        'validation_status', 'valid'),
      jsonb_build_object('row_number', 9, 'source_file', 'cata_prd_impuestos.xlsx', 'detected_type', 'products',
        'raw_data', jsonb_build_object('cells', jsonb_build_array('P-PENDIENTE')),
        'normalized_data', jsonb_build_object('alphaSku', 'P-PENDIENTE', 'name', 'Producto pendiente fiscal', 'unit', 'PZA',
          'staiva', '2', 'porceniva', '16', 'taxCategoryCode', 'IVA16', 'taxRate', 0.16),
        'validation_status', 'valid')
    ),
    '[]'::jsonb
  );
  v_batch := (v_result ->> 'batch_id')::uuid;
  v_result := public.confirm_staged_import(v_batch);
  if v_result ->> 'status' <> 'completed' or (v_result ->> 'records_imported')::integer <> 3 then
    raise exception 'La promoción de productos con impuesto no se completó.';
  end if;
  if (select tax_category_id from public.products where id = v_pending_product) is null then
    raise exception 'La fuente fiscal separada no completó el producto previamente importado.';
  end if;
  if not exists (
    select 1 from public.products product
    join public.tax_categories category on category.id = product.tax_category_id
    where product.company_id = v_company and product.alpha_sku = 'P-IVA16' and category.code = 'IVA16'
  ) or not exists (
    select 1 from public.products product
    join public.tax_categories category on category.id = product.tax_category_id
    where product.company_id = v_company and product.alpha_sku = 'P-IVA0' and category.code = 'IVA0'
  ) then
    raise exception 'Los productos no quedaron ligados a su categoría fiscal canónica.';
  end if;
  if not exists (
    select 1 from public.tax_rates rate
    join public.tax_categories category on category.id = rate.tax_category_id
    where category.company_id = v_company and category.code = 'IVA16' and rate.jurisdiction_code = 'MX' and rate.rate = 0.16
  ) or not exists (
    select 1 from public.tax_rates rate
    join public.tax_categories category on category.id = rate.tax_category_id
    where category.company_id = v_company and category.code = 'IVA0' and rate.jurisdiction_code = 'MX' and rate.rate = 0
  ) then
    raise exception 'No se crearon o reutilizaron las tasas fiscales vigentes.';
  end if;
  if public.get_staged_product_tax_summary(v_batch) <> jsonb_build_array(
    jsonb_build_object('tax_category_code', 'IVA0', 'total', 1),
    jsonb_build_object('tax_category_code', 'IVA16', 'total', 2)
  ) then
    raise exception 'El preview no devolvió el resumen fiscal completo del staging.';
  end if;
  select count(*) into v_rate_count
  from public.tax_rates rate join public.tax_categories category on category.id = rate.tax_category_id
  where category.company_id = v_company;
  v_result := public.confirm_staged_import(v_batch);
  if v_result ->> 'status' <> 'completed'
    or v_rate_count <> (select count(*) from public.tax_rates rate join public.tax_categories category on category.id = rate.tax_category_id where category.company_id = v_company) then
    raise exception 'El reintento del mismo lote no fue idempotente.';
  end if;

  v_result := public.stage_alpha_import(
    v_company, 'products', 'local_development', 'cata_prd_impuesto_invalido.xlsx', 'xlsx', repeat('c', 64), null,
    jsonb_build_array(jsonb_build_object('row_number', 7, 'source_file', 'cata_prd_impuesto_invalido.xlsx', 'detected_type', 'products',
      'raw_data', jsonb_build_object('cells', jsonb_build_array('P-INVALIDO')),
      'normalized_data', jsonb_build_object('alphaSku', 'P-INVALIDO', 'name', 'Producto inválido', 'unit', 'PZA',
        'staiva', '2', 'porceniva', '8', 'taxCategoryCode', 'IVA8', 'taxRate', 0.08),
      'validation_status', 'valid')),
    '[]'::jsonb
  );
  v_invalid_batch := (v_result ->> 'batch_id')::uuid;
  v_result := public.confirm_staged_import(v_invalid_batch);
  if v_result ->> 'status' <> 'failed'
    or exists (select 1 from public.products where company_id = v_company and alpha_sku = 'P-INVALIDO') then
    raise exception 'El guardado servidor permitió una clasificación fiscal no reconocida.';
  end if;
end;
$test$;

rollback;
