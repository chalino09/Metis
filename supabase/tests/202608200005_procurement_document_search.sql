begin;

do $test$
declare
  v_company uuid:='82000005-0000-4000-8000-000000000001';
  v_user uuid:='82000005-0000-4000-8000-000000000002';
  v_other_user uuid:='82000005-0000-4000-8000-000000000003';
  v_location uuid:='82000005-0000-4000-8000-000000000004';
  v_product uuid:='82000005-0000-4000-8000-000000000005';
  v_supplier uuid;
  v_requisition uuid:='82000005-0000-4000-8000-000000000006';
  v_requisition_line uuid:='82000005-0000-4000-8000-000000000007';
  v_result jsonb;
  v_forbidden boolean:=false;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','document-search@example.invalid','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
    (v_other_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','document-search-other@example.invalid','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
  insert into public.companies(id,legal_name,display_name) values(v_company,'Documentos de compra','Documentos de compra');
  insert into public.locations(id,company_id,external_code,name,location_type,classification_source)
  values(v_location,v_company,'DOC-01','Almacén documental','almacen_central','manual_review');
  insert into public.products(id,company_id,alpha_sku,name,unit,product_type,is_active,is_inventory_tracked)
  values(v_product,v_company,'DOC-PROD-1','Producto documental','PZA','P. TERMINADO',true,true);
  insert into public.suppliers(company_id,code,display_name,legal_entity_type,country_code,is_active,payable_term_days)
  values(v_company,'DOC-SUP','Proveedor documental','moral','MX',true,30) returning id into v_supplier;
  insert into public.user_roles(user_id,role_id,company_id)
  select v_user,id,v_company from public.roles where code='direccion_admin';
  insert into public.user_location_access(user_id,location_id) values(v_user,v_location);
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_user::text,true);

  insert into public.procurement_requisitions(id,company_id,folio,location_id,status,source,target_date,exception_reason)
  values(v_requisition,v_company,'REQ-TEST-000001',v_location,'quoting','manual_exception',current_date+5,'Compra documental');
  insert into public.procurement_requisition_lines(id,company_id,requisition_id,line_number,product_id,description,unit,required_quantity)
  values(v_requisition_line,v_company,v_requisition,1,v_product,'Producto documental','PZA',1);
  perform public.save_procurement_quote(
    v_company,v_requisition,v_supplier,'MXN',current_date+10,5,0,null,null,
    jsonb_build_array(jsonb_build_object(
      'requisition_line_id',v_requisition_line,
      'available_quantity',1,
      'unit_price',90,
      'commercial_discount_percent',0,
      'expected_date',(current_date+5)::text
    ))
  );
  insert into public.purchase_orders(company_id,supplier_id,folio,status,origin,currency_code,ordered_date,total)
  values(v_company,v_supplier,'OC-TEST-000001','approved','operational','MXN',current_date,50);

  v_result:=public.search_procurement_documents(v_company,null,null,null,1,25);
  if (v_result#>>'{pagination,total}')::integer<>2 then raise exception 'La vista no reunió cotización y orden: %',v_result; end if;
  if not exists(
    select 1 from jsonb_array_elements(v_result->'items') item
    where item->>'document_type'='quote' and item->>'reference'='REQ-TEST-000001' and (item->>'total')::numeric=90
  ) then raise exception 'La cotización no conserva solicitud o total: %',v_result; end if;

  v_result:=public.search_procurement_documents(v_company,null,'quote',null,1,25);
  if (v_result#>>'{pagination,total}')::integer<>1 or v_result#>>'{items,0,status_code}'<>'quote_received' then
    raise exception 'El filtro de cotizaciones es incorrecto: %',v_result;
  end if;
  v_result:=public.search_procurement_documents(v_company,null,'order','order_approved',1,25);
  if (v_result#>>'{pagination,total}')::integer<>1 or v_result#>>'{items,0,reference}'<>'OC-TEST-000001' then
    raise exception 'El filtro de órdenes es incorrecto: %',v_result;
  end if;
  v_result:=public.search_procurement_documents(v_company,'REQ-TEST',null,null,1,1);
  if (v_result#>>'{pagination,total}')::integer<>1 or jsonb_array_length(v_result->'items')<>1 then
    raise exception 'Búsqueda o paginación incorrecta: %',v_result;
  end if;

  perform set_config('request.jwt.claim.sub',v_other_user::text,true);
  begin
    perform public.search_procurement_documents(v_company,null,null,null,1,25);
  exception when others then
    v_forbidden:=position('No autorizado' in sqlerrm)>0;
  end;
  if not v_forbidden then raise exception 'Un usuario ajeno consultó documentos de compra.'; end if;

  raise notice 'Consulta unificada: cotización, orden, total, filtros, paginación y permisos correctos.';
end $test$;

rollback;
