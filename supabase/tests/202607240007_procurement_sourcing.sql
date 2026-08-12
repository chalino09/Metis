begin;

do $test$
declare
  c uuid:='24070000-0000-4000-8000-000000000001'; u uuid:='24070000-0000-4000-8000-000000000002'; l uuid:='24070000-0000-4000-8000-000000000003';
  p1 uuid:='24070000-0000-4000-8000-000000000004'; p2 uuid:='24070000-0000-4000-8000-000000000005'; s1 uuid; s2 uuid; req uuid; q1 uuid; q2 uuid; ql1 uuid; ql2 uuid; result jsonb;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(u,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','procurement-test@example.invalid','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
  insert into public.companies(id,legal_name,display_name) values(c,'Abastecimiento prueba','Abastecimiento prueba');
  insert into public.locations(id,company_id,external_code,name,location_type,classification_source) values(l,c,'ABS-01','Almacén pruebas','almacen_central','manual_review');
  insert into public.products(id,company_id,alpha_sku,name,unit,product_type,is_active,is_inventory_tracked) values
    (p1,c,'ABS-1','Producto abastecimiento uno','PZA','P. TERMINADO',true,true),(p2,c,'ABS-2','Producto abastecimiento dos','PZA','P. TERMINADO',true,true);
  insert into public.inventory_balances(company_id,location_id,product_id,quantity_on_hand) values(c,l,p1,2),(c,l,p2,1);
  insert into public.suppliers(company_id,code,display_name,legal_entity_type,country_code,is_active,payable_term_days) values(c,'ABS-A','Proveedor A','moral','MX',true,30) returning id into s1;
  insert into public.suppliers(company_id,code,display_name,legal_entity_type,country_code,is_active,payable_term_days) values(c,'ABS-B','Proveedor B','moral','MX',true,45) returning id into s2;
  insert into public.user_roles(user_id,role_id,company_id) select u,id,c from public.roles where code='direccion_admin';
  insert into public.user_location_access(user_id,location_id) values(u,l);
  perform set_config('request.jwt.claim.role','authenticated',true); perform set_config('request.jwt.claim.sub',u::text,true);
  perform public.configure_inventory_replenishment_policies(c,l,jsonb_build_array(jsonb_build_object('product_code','ABS-1','minimum_quantity',5,'maximum_quantity',10),jsonb_build_object('product_code','ABS-2','minimum_quantity',4,'maximum_quantity',8)),'24070000-0000-4000-8000-000000000006');
  result:=public.generate_procurement_requisition_from_replenishment(c,l,current_date+15,null); req:=(result->>'id')::uuid;
  if jsonb_array_length(result->'lines')<>2 or result->>'source'<>'replenishment' then raise exception 'La necesidad no se generó desde los faltantes: %',result;end if;
  perform public.save_procurement_quote(c,req,s1,'MXN',current_date+10,3,0,null,'Proveedor A cotiza el requerimiento',jsonb_build_array(jsonb_build_object('requisition_line_id',(select id from public.procurement_requisition_lines where requisition_id=req and product_id=p1),'available_quantity',8,'unit_price',9,'commercial_discount_percent',5,'expected_date',(current_date+10)::text),jsonb_build_object('requisition_line_id',(select id from public.procurement_requisition_lines where requisition_id=req and product_id=p2),'available_quantity',7,'unit_price',13,'commercial_discount_percent',0,'expected_date',(current_date+10)::text)));
  perform public.save_procurement_quote(c,req,s2,'MXN',current_date+10,5,0,null,'Proveedor B cotiza el requerimiento',jsonb_build_array(jsonb_build_object('requisition_line_id',(select id from public.procurement_requisition_lines where requisition_id=req and product_id=p1),'available_quantity',8,'unit_price',12,'commercial_discount_percent',0,'expected_date',(current_date+10)::text),jsonb_build_object('requisition_line_id',(select id from public.procurement_requisition_lines where requisition_id=req and product_id=p2),'available_quantity',7,'unit_price',11,'commercial_discount_percent',0,'expected_date',(current_date+10)::text)));
  select id into q1 from public.procurement_quotes where requisition_id=req and supplier_id=s1; select id into q2 from public.procurement_quotes where requisition_id=req and supplier_id=s2;
  select ql.id into ql1 from public.procurement_quote_lines ql join public.procurement_requisition_lines rl on rl.id=ql.requisition_line_id where ql.quote_id=q1 and rl.product_id=p1; select ql.id into ql2 from public.procurement_quote_lines ql join public.procurement_requisition_lines rl on rl.id=ql.requisition_line_id where ql.quote_id=q2 and rl.product_id=p2;
  result:=public.recommend_procurement_award(c,req,'A gana producto uno por mejor precio; B cubre producto dos.',jsonb_build_array(jsonb_build_object('quote_line_id',ql1,'awarded_quantity',8,'reason','Mejor precio'),jsonb_build_object('quote_line_id',ql2,'awarded_quantity',7,'reason','Disponibilidad confirmada')));
  if result->>'status'<>'recommended' then raise exception 'No se registró la recomendación: %',result;end if;
  result:=public.approve_procurement_award(c,req,'Aprobación de prueba con adjudicación por partida.');
  if result->>'status'<>'approved' or jsonb_array_length(result#>'{award,purchase_order_ids}')<>2 then raise exception 'La adjudicación no creó dos OC: %',result;end if;
  if (select count(*) from public.purchase_orders po join public.procurement_purchase_orders ppo on ppo.purchase_order_id=po.id where ppo.company_id=c and po.status='approved')<>2 then raise exception 'Las OC no quedaron aprobadas.';end if;
  if not exists(select 1 from public.purchase_orders po join public.procurement_purchase_orders ppo on ppo.purchase_order_id=po.id join public.suppliers s on s.id=po.supplier_id where ppo.company_id=c and s.id=s1 and po.total=68.4) then raise exception 'La OC A no preservó precio y descuento comercial.';end if;
  if not exists(select 1 from public.audit_log where company_id=c and action='procurement.award_approved') then raise exception 'Falta la auditoría de aprobación.';end if;
  raise notice 'Abastecimiento: generación, cotizaciones, adjudicación por partida y dos OC aprobadas correctamente.';
end $test$;

rollback;
