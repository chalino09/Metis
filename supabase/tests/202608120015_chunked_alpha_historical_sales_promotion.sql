begin;

do $chunked_historical_sales$
declare
  v_company uuid := '8a120015-0000-4000-8000-000000000001';
  v_user uuid := '8a120015-0000-4000-8000-000000000010';
  v_location uuid;
  v_batch uuid;
  v_result jsonb;
begin
  insert into public.companies(id,legal_name,display_name,base_currency_code)
  values(v_company,'Ventas históricas por bloques QA','Ventas históricas por bloques QA','MXN');
  insert into auth.users(id,aud,role,email,encrypted_password)
  values(v_user,'authenticated','authenticated','chunked-historical-sales@example.com','');
  insert into public.user_roles(user_id,role_id,company_id)
  select v_user,id,v_company from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_user::text,true);

  insert into public.locations(company_id,external_code,name,location_type)
  values(v_company,'QA','Sucursal QA','sucursal') returning id into v_location;
  insert into public.products(company_id,alpha_sku,name,unit)
  values(v_company,'SKU-015','Producto histórico QA','PZA');

  v_result:=public.begin_alpha_sales_evidence_file(v_company,'manual_upload','sales','nvtadesg_20260708_CHUNK.xls','xls',repeat('c',64),date '2026-07-08');
  v_batch:=(v_result->>'batch_id')::uuid;
  perform public.stage_alpha_sales_staging_rows(v_batch,(
    select jsonb_agg(jsonb_build_object(
      'row_number',series,
      'source_file','nvtadesg_20260708_CHUNK.xls',
      'detected_type','sales','raw_data','{}'::jsonb,'validation_status','valid',
      'normalized_data',jsonb_build_object(
        'evidenceKind','sale_line','saleDate','2026-07-01','sourceFolio','F-'||series,
        'sourceInvoice',series::text,'sourceStatus','Pagada','locationCode','QA','warehouseName','QA',
        'canonicalLocationId',v_location,'canonicalLocationCode','QA','customerExternalCode','00999',
        'customerName','Cliente histórico QA','alphaSku','SKU-015','description','Producto histórico QA',
        'unit','PZA','quantity',1,'unitPrice',100,'taxAmount',16,'lineTotal',116
      )
    ) order by series) from generate_series(1,101) series
  ),'[]'::jsonb);
  perform public.finish_alpha_sales_evidence_file(v_batch,'[]'::jsonb);

  perform public.begin_alpha_sales_evidence_file(v_company,'manual_upload','collections','cob_cte_20260708_CHUNK.xls','xls',repeat('d',64),date '2026-07-08');
  perform public.stage_alpha_sales_staging_rows(v_batch,(
    select jsonb_agg(jsonb_build_object(
      'row_number',1000000+series,
      'source_file','cob_cte_20260708_CHUNK.xls','detected_type','sales',
      'raw_data','{}'::jsonb,'validation_status','valid',
      'normalized_data',jsonb_build_object(
        'evidenceKind','collection','customerExternalCode','00999','reference','C1 '||series,'amount',116
      )
    ) order by series) from generate_series(1,101) series
  ),'[]'::jsonb);
  perform public.finish_alpha_sales_evidence_file(v_batch,'[]'::jsonb);

  v_result:=public.promote_alpha_historical_sales_chunk(v_batch,'Promoción QA por bloques.',100);
  if v_result->>'status'<>'processing'
    or (v_result->>'processed_documents')::integer<>100
    or (select count(*) from public.sales where source_import_batch_id=v_batch)<>100 then
    raise exception 'Primer bloque inesperado: %',v_result;
  end if;

  v_result:=public.promote_alpha_historical_sales_chunk(v_batch,'Promoción QA por bloques.',100);
  if v_result->>'status'<>'completed'
    or (v_result->>'sales_imported')::integer<>101
    or (select count(*) from public.sale_items item join public.sales sale_data on sale_data.id=item.sale_id where sale_data.source_import_batch_id=v_batch)<>101
    or (select count(*) from public.canonical_tickets ticket join public.sales sale_data on sale_data.id=ticket.sale_id where sale_data.source_import_batch_id=v_batch)<>101 then
    raise exception 'Cierre por bloques inesperado: %',v_result;
  end if;
  if exists(select 1 from public.sale_payments payment join public.sales sale_data on sale_data.id=payment.sale_id where sale_data.source_import_batch_id=v_batch)
    or exists(select 1 from public.customer_receivables receivable join public.sales sale_data on sale_data.id=receivable.sale_id where sale_data.source_import_batch_id=v_batch)
    or exists(select 1 from public.inventory_ledger ledger join public.sale_items item on item.id=ledger.sale_item_id join public.sales sale_data on sale_data.id=item.sale_id where sale_data.source_import_batch_id=v_batch) then
    raise exception 'La promoción por bloques creó efectos operativos.';
  end if;
  if not exists(select 1 from public.audit_log where entity_id=v_batch and action='sales_history.promoted') then
    raise exception 'La promoción por bloques no cerró la auditoría.';
  end if;

  v_result:=public.promote_alpha_historical_sales_chunk(v_batch,'Promoción QA por bloques.',100);
  if not (v_result->>'idempotent')::boolean or (select count(*) from public.sales where source_import_batch_id=v_batch)<>101 then
    raise exception 'El reintento por bloques duplicó ventas: %',v_result;
  end if;
  raise notice 'Promoción histórica por bloques: 100 + 1 documentos, cierre e idempotencia verificados.';
end;
$chunked_historical_sales$;

rollback;
