begin;

do $bi_historical_sales_summary$
declare
  v_company uuid:='8a120017-1000-4000-8000-000000000001';
  v_user uuid:='8a120017-1000-4000-8000-000000000010';
  v_location uuid:='8a120017-1000-4000-8000-000000000020';
  v_product_a uuid:='8a120017-1000-4000-8000-000000000030';
  v_product_b uuid:='8a120017-1000-4000-8000-000000000031';
  v_batch uuid:='8a120017-1000-4000-8000-000000000040';
  v_summary jsonb;
  v_charts jsonb;
  v_product_summary jsonb;
  v_sales_before text;
  v_sales_after text;
  v_items_before text;
  v_items_after text;
  v_value numeric;
  v_previous numeric;
  v_tickets bigint;
begin
  insert into public.companies(id,legal_name,display_name,base_currency_code)
  values(v_company,'BI histórico QA','BI histórico QA','MXN');
  insert into auth.users(id,aud,role,email,encrypted_password)
  values(v_user,'authenticated','authenticated','bi-historical-summary@example.com','');
  insert into public.user_roles(user_id,role_id,company_id)
  select v_user,id,v_company from public.roles where code='direccion_admin';
  insert into public.locations(id,company_id,external_code,name,location_type)
  values(v_location,v_company,'QA','Sucursal QA','sucursal');
  insert into public.products(id,company_id,alpha_sku,name,unit) values
    (v_product_a,v_company,'SKU-BI-A','Producto A','PIEZA'),
    (v_product_b,v_company,'SKU-BI-B','Producto B','PIEZA');
  insert into public.accounting_config_versions(
    company_id,version,status,base_currency,cutoff_date,catalog_structure,
    tax_treatment,responsibilities,change_reason,approved_by,approved_at
  ) values (
    v_company,1,'approved','MXN',date '2025-01-01','{}','{}','{}',
    'Configuración BI QA',v_user,now()
  );
  insert into public.import_batches(
    id,company_id,import_type,source,file_sha256,status,records_received,
    records_imported,imported_by,completed_at,closed_at
  ) values (
    v_batch,v_company,'sales','manual_upload',repeat('c',64),'completed',4,4,
    v_user,now(),now()
  );

  insert into public.sales(
    id,company_id,location_id,cashier_id,sale_type,status,currency_code,
    subtotal_amount,discount_amount,tax_amount,total_amount,client_request_id,
    completed_at,source_kind,source_import_batch_id,source_document_key
  ) values
    ('8a120017-1000-4000-8000-000000000101',v_company,v_location,v_user,'cash','completed','MXN',100,0,16,116,gen_random_uuid(),'2025-12-31T12:00:00Z','alpha_historical',v_batch,'previous-a'),
    ('8a120017-1000-4000-8000-000000000102',v_company,v_location,v_user,'cash','completed','MXN',100,0,16,116,gen_random_uuid(),'2026-01-01T12:00:00Z','alpha_historical',v_batch,'current-a-1'),
    ('8a120017-1000-4000-8000-000000000103',v_company,v_location,v_user,'cash','completed','MXN',100,0,16,116,gen_random_uuid(),'2026-04-15T12:00:00Z','alpha_historical',v_batch,'current-b'),
    ('8a120017-1000-4000-8000-000000000104',v_company,v_location,v_user,'cash','completed','MXN',100,0,16,116,gen_random_uuid(),'2026-08-12T12:00:00Z','alpha_historical',v_batch,'current-a-2');

  insert into public.sale_items(
    sale_id,product_id,product_code,product_name,unit_name,quantity,
    unit_price_amount,gross_amount,discount_percent,discount_amount,
    taxable_amount,tax_amount,total_amount
  ) values
    ('8a120017-1000-4000-8000-000000000101',v_product_a,'SKU-BI-A','Producto A','PIEZA',1,100,100,0,0,100,16,116),
    ('8a120017-1000-4000-8000-000000000102',v_product_a,'SKU-BI-A','Producto A','PIEZA',1,100,100,0,0,100,16,116),
    ('8a120017-1000-4000-8000-000000000103',v_product_b,'SKU-BI-B','Producto B','PIEZA',1,100,100,0,0,100,16,116),
    ('8a120017-1000-4000-8000-000000000104',v_product_a,'SKU-BI-A','Producto A','PIEZA',1,100,100,0,0,100,16,116);

  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_user::text,true);

  select md5(string_agg(row_to_json(sale_data)::text,'|' order by sale_data.id))
  into v_sales_before from public.sales sale_data where sale_data.company_id=v_company;
  select md5(string_agg(row_to_json(item)::text,'|' order by item.id))
  into v_items_before
  from public.sale_items item join public.sales sale_data on sale_data.id=item.sale_id
  where sale_data.company_id=v_company;

  v_summary:=public.bi_get_executive_summary(v_company,date '2026-01-01',date '2026-08-12',null,null,null,null);
  v_charts:=public.bi_get_executive_charts(v_company,date '2026-01-01',date '2026-08-12',null,null,null,null);
  v_product_summary:=public.bi_get_executive_summary(v_company,date '2026-01-01',date '2026-08-12',null,v_product_a,null,null);

  select (metric->>'value')::numeric,(metric->>'previous_value')::numeric
  into v_value,v_previous from jsonb_array_elements(v_summary->'metrics') metric
  where metric->>'code'='net_sales';
  select (metric->>'value')::bigint into v_tickets
  from jsonb_array_elements(v_summary->'metrics') metric where metric->>'code'='tickets';
  if v_value<>300 or v_previous<>100 or v_tickets<>3
    or jsonb_array_length(v_summary->'series')<>224
    or (select sum((day_data->>'sales')::numeric) from jsonb_array_elements(v_summary->'series') day_data)<>300 then
    raise exception 'El resumen anual optimizado devolvió cifras incorrectas: %',v_summary;
  end if;

  select (metric->>'value')::numeric,(metric->>'previous_value')::numeric
  into v_value,v_previous from jsonb_array_elements(v_product_summary->'metrics') metric
  where metric->>'code'='net_sales';
  if v_value<>200 or v_previous<>100 then
    raise exception 'El filtro por producto cambió: %',v_product_summary;
  end if;

  select sum((point->>'value')::numeric),sum((point->>'previous_value')::numeric)
  into v_value,v_previous
  from jsonb_array_elements((select chart->'points' from jsonb_array_elements(v_charts->'charts') chart where chart->>'code'='sales')) point;
  if v_value<>300 or v_previous<>100
    or (v_charts#>>'{operational_rows,0,current_value}')::numeric<>300
    or (v_charts#>>'{operational_rows,0,previous_value}')::numeric<>100 then
    raise exception 'Las gráficas ejecutivas cambiaron cifras: %',v_charts;
  end if;

  select md5(string_agg(row_to_json(sale_data)::text,'|' order by sale_data.id))
  into v_sales_after from public.sales sale_data where sale_data.company_id=v_company;
  select md5(string_agg(row_to_json(item)::text,'|' order by item.id))
  into v_items_after
  from public.sale_items item join public.sales sale_data on sale_data.id=item.sale_id
  where sale_data.company_id=v_company;
  if (v_sales_before,v_items_before) is distinct from (v_sales_after,v_items_after) then
    raise exception 'La consulta BI alteró ventas o partidas confirmadas.';
  end if;

  raise notice 'BI histórico: resumen, gráficas, producto e inmutabilidad verificados.';
end;
$bi_historical_sales_summary$;

rollback;
