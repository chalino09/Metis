begin;

do $bi_margin_coverage$
declare
  v_company uuid:='8a120018-1000-4000-8000-000000000001';
  v_user uuid:='8a120018-1000-4000-8000-000000000010';
  v_location uuid:='8a120018-1000-4000-8000-000000000020';
  v_product_a uuid:='8a120018-1000-4000-8000-000000000030';
  v_product_b uuid:='8a120018-1000-4000-8000-000000000031';
  v_batch uuid:='8a120018-1000-4000-8000-000000000040';
  v_net numeric;
  v_cost numeric;
  v_margin numeric;
  v_items bigint;
  v_costed bigint;
  v_missing bigint;
  v_sales_before text;
  v_sales_after text;
  v_items_before text;
  v_items_after text;
begin
  insert into public.companies(id,legal_name,display_name,base_currency_code)
  values(v_company,'Cobertura margen QA','Cobertura margen QA','MXN');
  insert into auth.users(id,aud,role,email,encrypted_password)
  values(v_user,'authenticated','authenticated','bi-margin-coverage@example.com','');
  insert into public.user_roles(user_id,role_id,company_id)
  select v_user,id,v_company from public.roles where code='direccion_admin';
  insert into public.locations(id,company_id,external_code,name,location_type)
  values(v_location,v_company,'QA','Sucursal QA','sucursal');
  insert into public.products(id,company_id,alpha_sku,name,unit) values
    (v_product_a,v_company,'SKU-MARGIN-A','Producto A','PIEZA'),
    (v_product_b,v_company,'SKU-MARGIN-B','Producto B','PIEZA');
  insert into public.import_batches(
    id,company_id,import_type,source,file_sha256,status,records_received,
    records_imported,imported_by,completed_at,closed_at
  ) values (
    v_batch,v_company,'sales','manual_upload',repeat('d',64),'completed',2,2,
    v_user,now(),now()
  );
  insert into public.sales(
    id,company_id,location_id,cashier_id,sale_type,status,currency_code,
    subtotal_amount,discount_amount,tax_amount,total_amount,client_request_id,
    completed_at,source_kind,source_import_batch_id,source_document_key
  ) values
    ('8a120018-1000-4000-8000-000000000101',v_company,v_location,v_user,'cash','completed','MXN',150,0,24,174,gen_random_uuid(),'2026-01-15T12:00:00Z','alpha_historical',v_batch,'margin-current-a'),
    ('8a120018-1000-4000-8000-000000000102',v_company,v_location,v_user,'cash','completed','MXN',80,0,12.8,92.8,gen_random_uuid(),'2025-12-15T12:00:00Z','alpha_historical',v_batch,'margin-previous-a');
  insert into public.sale_items(
    sale_id,product_id,product_code,product_name,unit_name,quantity,
    unit_price_amount,gross_amount,discount_percent,discount_amount,
    taxable_amount,tax_amount,total_amount
  ) values
    ('8a120018-1000-4000-8000-000000000101',v_product_a,'SKU-MARGIN-A','Producto A','PIEZA',1,100,100,0,0,100,16,116),
    ('8a120018-1000-4000-8000-000000000101',v_product_b,'SKU-MARGIN-B','Producto B','PIEZA',1,50,50,0,0,50,8,58),
    ('8a120018-1000-4000-8000-000000000102',v_product_a,'SKU-MARGIN-A','Producto A','PIEZA',1,80,80,0,0,80,12.8,92.8);

  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_user::text,true);
  select md5(string_agg(row_to_json(sale_data)::text,'|' order by sale_data.id))
  into v_sales_before from public.sales sale_data where sale_data.company_id=v_company;
  select md5(string_agg(row_to_json(item)::text,'|' order by item.id))
  into v_items_before from public.sale_items item
  join public.sales sale_data on sale_data.id=item.sale_id
  where sale_data.company_id=v_company;

  select net_sales,recognized_cost,gross_margin,item_count,costed_item_count,missing_cost_item_count
  into v_net,v_cost,v_margin,v_items,v_costed,v_missing
  from public.sale_margin_coverage(v_company,date '2026-01-01',date '2026-08-12','MXN',null,null,null);
  if (v_net,v_cost,v_margin,v_items,v_costed,v_missing)
      is distinct from (150::numeric,0::numeric,null::numeric,2::bigint,0::bigint,2::bigint) then
    raise exception 'La cobertura general cambió: net %, cost %, margin %, items %, costed %, missing %',
      v_net,v_cost,v_margin,v_items,v_costed,v_missing;
  end if;

  select net_sales,item_count,missing_cost_item_count
  into v_net,v_items,v_missing
  from public.sale_margin_coverage(v_company,date '2026-01-01',date '2026-08-12','MXN',null,v_product_a,null);
  if (v_net,v_items,v_missing) is distinct from (100::numeric,1::bigint,1::bigint) then
    raise exception 'El filtro por producto cambió: net %, items %, missing %',v_net,v_items,v_missing;
  end if;

  select md5(string_agg(row_to_json(sale_data)::text,'|' order by sale_data.id))
  into v_sales_after from public.sales sale_data where sale_data.company_id=v_company;
  select md5(string_agg(row_to_json(item)::text,'|' order by item.id))
  into v_items_after from public.sale_items item
  join public.sales sale_data on sale_data.id=item.sale_id
  where sale_data.company_id=v_company;
  if (v_sales_before,v_items_before) is distinct from (v_sales_after,v_items_after) then
    raise exception 'La cobertura de margen alteró documentos POS confirmados.';
  end if;

  raise notice 'Cobertura de margen: cifras, filtro e inmutabilidad verificados.';
end;
$bi_margin_coverage$;

rollback;
