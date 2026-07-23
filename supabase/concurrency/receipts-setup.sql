\set ON_ERROR_STOP on
do $setup$
declare v_actor uuid;v_company uuid:='39000000-0000-4000-8000-000000000001';v_supplier uuid;v_product uuid;v_location uuid;v_order uuid;v_line uuid;v_result jsonb;v_same uuid;v_a uuid;v_b uuid;
begin
  select ur.user_id into v_actor from public.user_roles ur join public.roles r on r.id=ur.role_id where r.code='super_admin' limit 1;
  delete from public.companies where id=v_company;
  insert into public.companies(id,legal_name,display_name) values(v_company,'Concurrencia M3C','Concurrencia M3C');
  insert into public.user_roles(user_id,role_id,company_id) select v_actor,id,v_company from public.roles where code='super_admin' on conflict do nothing;
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',v_actor::text,true);
  insert into public.suppliers(company_id,code,display_name,legal_entity_type,country_code,is_active) values(v_company,'SUP-CONC','Proveedor concurrencia','moral','MX',true) returning id into v_supplier;
  insert into public.products(company_id,alpha_sku,name,unit,product_type,is_active,is_inventory_tracked) values(v_company,'SKU-CONC','Producto concurrencia','PZA','P. TERMINADO',true,true) returning id into v_product;
  insert into public.locations(company_id,external_code,name,location_type,is_active,classification_source) values(v_company,'ALM-CONC','Almacén concurrencia','almacen_operativo',true,'manual_review') returning id into v_location;
  v_result:=public.save_purchase_order(v_company,null,v_supplier,'MXN',current_date,null,null,null,null,0,jsonb_build_array(jsonb_build_object('product_id',v_product,'description','Producto','quantity',10,'unit_cost',5)),null);v_order:=(v_result->>'id')::uuid;
  perform public.submit_purchase_order(v_company,v_order,null);perform public.decide_purchase_order(v_company,v_order,'approved',null);select id into v_line from public.purchase_order_lines where purchase_order_id=v_order;
  v_result:=public.save_purchase_receipt(v_company,null,v_order,v_location,current_date,'CONC-SAME',null,jsonb_build_array(jsonb_build_object('purchase_order_line_id',v_line,'quantity',4)),'39000000-0000-4000-8000-000000000010',null);v_same:=(v_result->>'id')::uuid;
  v_result:=public.save_purchase_receipt(v_company,null,v_order,v_location,current_date,'CONC-A',null,jsonb_build_array(jsonb_build_object('purchase_order_line_id',v_line,'quantity',6)),'39000000-0000-4000-8000-000000000011',null);v_a:=(v_result->>'id')::uuid;
  v_result:=public.save_purchase_receipt(v_company,null,v_order,v_location,current_date,'CONC-B',null,jsonb_build_array(jsonb_build_object('purchase_order_line_id',v_line,'quantity',6)),'39000000-0000-4000-8000-000000000012',null);v_b:=(v_result->>'id')::uuid;
  create table if not exists public.m3c_concurrency_context(company_id uuid,actor_id uuid,receipt_same uuid,receipt_a uuid,receipt_b uuid,location_id uuid,product_id uuid,order_id uuid);
  truncate public.m3c_concurrency_context;
  insert into public.m3c_concurrency_context values(v_company,v_actor,v_same,v_a,v_b,v_location,v_product,v_order);
end $setup$;
