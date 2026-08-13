begin;

do $historical_tax_fallback$
declare
  v_company uuid := '8a120016-0000-4000-8000-000000000001';
  v_user uuid := '8a120016-0000-4000-8000-000000000010';
  v_location uuid;
  v_category uuid;
  v_batch uuid;
  v_result jsonb;
  v_taxable numeric;
  v_tax numeric;
  v_rate numeric;
begin
  insert into public.companies(id,legal_name,display_name,base_currency_code)
  values(v_company,'Fallback fiscal histórico QA','Fallback fiscal histórico QA','MXN');
  insert into auth.users(id,aud,role,email,encrypted_password)
  values(v_user,'authenticated','authenticated','historical-tax-fallback@example.com','');
  insert into public.user_roles(user_id,role_id,company_id)
  select v_user,id,v_company from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_user::text,true);

  insert into public.locations(company_id,external_code,name,location_type)
  values(v_company,'QA','Sucursal QA','sucursal') returning id into v_location;
  insert into public.tax_categories(company_id,code,name)
  values(v_company,'IVA16','IVA 16%') returning id into v_category;
  insert into public.tax_rates(tax_category_id,jurisdiction_code,rate,valid_from,created_by)
  values(v_category,'MX',0.16,now(),v_user);
  insert into public.products(company_id,alpha_sku,name,unit,tax_category_id)
  values(v_company,'PV85796','Tubo QA','METRO',v_category);

  v_result:=public.begin_alpha_sales_evidence_file(v_company,'manual_upload','sales','nvtadesg_20260708_TAX.xls','xls',repeat('e',64),date '2026-07-08');
  v_batch:=(v_result->>'batch_id')::uuid;
  perform public.stage_alpha_sales_staging_rows(v_batch,jsonb_build_array(jsonb_build_object(
    'row_number',60761,'source_file','nvtadesg_20260708_TAX.xls','detected_type','sales',
    'raw_data',jsonb_build_object('cells',jsonb_build_array('PV85796','','Tubo QA','','','','PV85796','Tubo QA','0.25','7.25')),
    'validation_status','valid','normalized_data',jsonb_build_object(
      'evidenceKind','sale_line','saleDate','2026-07-01','sourceFolio','887','sourceInvoice','887',
      'sourceStatus','Pagada','locationCode','QA','warehouseName','QA','canonicalLocationId',v_location,
      'customerExternalCode','00999','customerName','Cliente QA','alphaSku','PV85796','description','Tubo QA',
      'unit','METRO','quantity',0.25,'unitPrice',25,'lineAmount',7.25,'lineTotal',7.25,'discountAmount',4
    )
  )),'[]'::jsonb);
  perform public.finish_alpha_sales_evidence_file(v_batch,'[]'::jsonb);
  perform public.begin_alpha_sales_evidence_file(v_company,'manual_upload','collections','cob_cte_20260708_TAX.xls','xls',repeat('f',64),date '2026-07-08');
  perform public.stage_alpha_sales_staging_rows(v_batch,jsonb_build_array(jsonb_build_object(
    'row_number',1,'source_file','cob_cte_20260708_TAX.xls','detected_type','sales','raw_data','{}'::jsonb,
    'validation_status','valid','normalized_data',jsonb_build_object('evidenceKind','collection','customerExternalCode','00999','reference','887','amount',7.25)
  )),'[]'::jsonb);
  perform public.finish_alpha_sales_evidence_file(v_batch,'[]'::jsonb);

  select taxable_amount,tax_amount into v_taxable,v_tax
  from public.alpha_historical_sales_lines(v_batch);
  if v_taxable<>6.25 or v_tax<>1 then
    raise exception 'El fallback fiscal sigue interpretando Dcto. como impuesto: base %, impuesto %.',v_taxable,v_tax;
  end if;

  perform public.acknowledge_staged_warnings(v_batch,error_code,'Incidencia ajena al fallback fiscal reconocida en QA.')
  from (
    select distinct error_code from public.import_staging_errors
    where import_batch_id=v_batch and severity='warning' and resolved_at is null
  ) warning;

  v_result:=public.promote_alpha_historical_sales_chunk(v_batch,'Validación de fallback fiscal.',100);
  if v_result->>'status'<>'completed' then
    raise exception 'La promoción corregida no terminó: %',v_result;
  end if;
  select item.taxable_amount,item.tax_amount,tax.rate
  into v_taxable,v_tax,v_rate
  from public.sale_items item
  join public.sales sale_data on sale_data.id=item.sale_id
  join public.sale_item_taxes tax on tax.sale_item_id=item.id
  where sale_data.source_import_batch_id=v_batch;
  if v_taxable<>6.25 or v_tax<>1 or v_rate<>0.16 then
    raise exception 'La venta promovida no conservó base 6.25, IVA 1 y tasa 16%%: %, %, %.',v_taxable,v_tax,v_rate;
  end if;
  raise notice 'Fallback fiscal histórico: Dcto. 4 ignorado; base 6.25, IVA 1 y tasa 16%% verificados.';
end;
$historical_tax_fallback$;

rollback;
