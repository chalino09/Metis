begin;

do $test$
declare
  v_company uuid:='21080100-0000-4000-8000-000000000001';
  v_actor uuid:='21080100-0000-4000-8000-000000000002';
  v_target_location uuid:='21080100-0000-4000-8000-000000000003';
  v_other_location uuid:='21080100-0000-4000-8000-000000000004';
  v_product uuid:='21080100-0000-4000-8000-000000000005';
  v_supplier uuid:='21080100-0000-4000-8000-000000000006';
  v_requisition uuid:='21080100-0000-4000-8000-000000000007';
  v_award uuid:='21080100-0000-4000-8000-000000000008';
  v_order uuid:='21080100-0000-4000-8000-000000000009';
  v_order_line uuid:='21080100-0000-4000-8000-000000000010';
  v_result jsonb;
  v_forbidden boolean:=false;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(v_actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','receipt-location-test@example.invalid','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
  insert into public.companies(id,legal_name,display_name) values(v_company,'Herencia de recepción','Herencia de recepción');
  insert into public.locations(id,company_id,external_code,name,location_type,classification_source) values
    (v_target_location,v_company,'DESTINO','Almacén destino','almacen_operativo','manual_review'),
    (v_other_location,v_company,'OTRO','Otro almacén','almacen_operativo','manual_review');
  insert into public.products(id,company_id,alpha_sku,name,unit,product_type,is_active,is_inventory_tracked)
  values(v_product,v_company,'HEREDA-01','Producto con destino heredado','PZA','P. TERMINADO',true,true);
  insert into public.suppliers(id,company_id,code,display_name,legal_entity_type,country_code,is_active)
  values(v_supplier,v_company,'PROV-HEREDA','Proveedor herencia','moral','MX',true);
  insert into public.user_roles(user_id,role_id,company_id) select v_actor,id,v_company from public.roles where code='super_admin';
  insert into public.user_location_access(user_id,location_id) values(v_actor,v_target_location),(v_actor,v_other_location);
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_actor::text,true);

  insert into public.procurement_requisitions(id,company_id,folio,location_id,status,source,exception_reason)
  values(v_requisition,v_company,'REQ-HEREDA-01',v_target_location,'approved','manual_exception','Prueba de herencia de almacén.');
  insert into public.procurement_awards(id,company_id,requisition_id,status,recommendation_reason,decided_reason)
  values(v_award,v_company,v_requisition,'approved','Proveedor seleccionado para la prueba.','Aprobación de prueba.');
  insert into public.purchase_orders(id,company_id,supplier_id,folio,status,currency_code,ordered_date,requisition_reference)
  values(v_order,v_company,v_supplier,'OC-HEREDA-01','draft','MXN',current_date,'REQ-HEREDA-01');
  insert into public.purchase_order_lines(id,company_id,purchase_order_id,line_number,product_id,description,unit,quantity,unit_cost,requisition_reference)
  values(v_order_line,v_company,v_order,1,v_product,'Producto con destino heredado','PZA',1,100,'REQ-HEREDA-01');
  update public.purchase_orders set status='approved' where id=v_order;
  insert into public.procurement_purchase_orders(procurement_award_id,purchase_order_id,company_id)
  values(v_award,v_order,v_company);

  v_result:=public.get_receivable_purchase_order(v_company,v_order);
  if (v_result->>'inherited_location_id')::uuid<>v_target_location
    or v_result->>'inherited_location_name'<>'Almacén destino'
    or v_result->>'inherited_location_code'<>'DESTINO' then
    raise exception 'La OC no expuso el almacén heredado: %',v_result;
  end if;

  delete from public.procurement_purchase_orders where purchase_order_id=v_order;
  v_result:=public.get_receivable_purchase_order(v_company,v_order);
  if (v_result->>'inherited_location_id')::uuid<>v_target_location then
    raise exception 'La OC histórica no recuperó el almacén por su referencia de solicitud: %',v_result;
  end if;

  begin
    perform public.save_purchase_receipt(v_company,null,v_order,v_other_location,current_date,null,null,jsonb_build_array(jsonb_build_object('purchase_order_line_id',v_order_line,'quantity',1)),gen_random_uuid(),null);
  exception when others then
    v_forbidden:=position('debe coincidir con la ubicación definida' in lower(sqlerrm))>0;
  end;
  if not v_forbidden then raise exception 'Se permitió recibir la OC en un almacén distinto al solicitado.';end if;

  v_result:=public.save_purchase_receipt(v_company,null,v_order,v_target_location,current_date,null,null,jsonb_build_array(jsonb_build_object('purchase_order_line_id',v_order_line,'quantity',1)),gen_random_uuid(),null);
  if (v_result->>'location_id')::uuid<>v_target_location then raise exception 'La recepción no conservó el almacén heredado: %',v_result;end if;

  raise notice 'Recepción: almacén heredado de la solicitud y protegido correctamente.';
end $test$;

rollback;
