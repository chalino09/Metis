begin;

do $large_historical_preview$
declare
  v_company uuid := '8a120013-0000-4000-8000-000000000001';
  v_user uuid := '8a120013-0000-4000-8000-000000000010';
  v_location uuid;
  v_batch uuid;
  v_started_at timestamptz;
  v_preview jsonb;
begin
  insert into public.companies(id,legal_name,display_name,base_currency_code)
  values(v_company,'Preview histórico grande QA','Preview histórico grande QA','MXN');
  insert into auth.users(id,aud,role,email,encrypted_password)
  values(v_user,'authenticated','authenticated','large-historical-preview@example.com','');
  insert into public.user_roles(user_id,role_id,company_id)
  select v_user,id,v_company from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_user::text,true);

  insert into public.locations(company_id,external_code,name,location_type)
  values(v_company,'QA','Sucursal QA','sucursal') returning id into v_location;
  insert into public.products(company_id,alpha_sku,name,unit)
  values(v_company,'SKU-013','Producto histórico QA','PZA');
  insert into public.customers(company_id,code,display_name,alpha_external_code)
  select v_company,'C-'||series,'Cliente QA '||series,lpad(series::text,5,'0')
  from generate_series(1,4960) series;

  v_batch := (public.begin_alpha_sales_evidence_file(
    v_company,'manual_upload','sales','nvtadesg_20260708_QA.xls','xls',repeat('a',64),date '2026-07-08'
  )->>'batch_id')::uuid;
  insert into public.import_files(import_batch_id,original_name,file_type,file_sha256,row_count)
  values(v_batch,'cob_cte_20260708_QA.xls','xls',repeat('b',64),8189);
  insert into public.import_staging_rows(
    import_batch_id,row_number,source_file,detected_type,raw_data,normalized_data,validation_status
  )
  select v_batch,series,'nvtadesg_20260708_QA.xls','sales','{}'::jsonb,
    jsonb_build_object(
      'evidenceKind','sale_line','saleDate','2026-07-01',
      'sourceFolio','F-'||ceil(series::numeric/2.23)::integer,
      'sourceInvoice',ceil(series::numeric/2.23)::integer::text,
      'sourceStatus','Pagada','locationCode','QA','warehouseName','QA',
      'canonicalLocationId',v_location,'customerExternalCode',lpad(((series-1)%4960+1)::text,5,'0'),
      'customerName','Cliente QA','alphaSku','SKU-013','description','Producto histórico QA',
      'unit','PZA','quantity',1,'unitPrice',100,'taxAmount',16,'lineTotal',116
    ),'valid'
  from generate_series(1,31097) series;
  update public.import_batches
  set status='staged',records_received=31097,valid_rows=31097,warning_rows=0,error_rows=0,
      blocking_error_count=0,pending_warning_count=0
  where id=v_batch;

  v_started_at:=clock_timestamp();
  v_preview:=public.preview_alpha_historical_sales_promotion(v_batch);
  if extract(epoch from clock_timestamp()-v_started_at)>8 then
    raise exception 'El preview grande superó 8 segundos.';
  end if;
  if (v_preview->>'line_count')::integer<>31097 or (v_preview->>'eligible_documents')::integer<=0 then
    raise exception 'Preview grande inesperado: %',v_preview;
  end if;
  raise notice 'Preview histórico de 31,097 partidas validado en % ms.',
    round(extract(epoch from clock_timestamp()-v_started_at)*1000);
end;
$large_historical_preview$;

rollback;
