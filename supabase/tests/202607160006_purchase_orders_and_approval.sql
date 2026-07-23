begin;

do $test$
declare
  v_actor uuid;v_other_actor uuid:='36000000-0000-4000-8000-000000000099';
  v_company uuid:='36000000-0000-4000-8000-000000000001';v_other uuid:='36000000-0000-4000-8000-000000000002';
  v_supplier uuid;v_supplier_other uuid;v_product uuid;v_product_2 uuid;v_order uuid;v_rejected uuid;v_batch uuid;v_stage_supplier uuid;
  v_result jsonb;v_forbidden boolean:=false;v_inventory_before bigint;v_cost_before bigint;v_receivable_before bigint;v_receipt_before bigint;
begin
  if to_regprocedure('public.save_purchase_order(uuid,uuid,uuid,text,date,date,text,text,text,numeric,jsonb,timestamptz)') is null
    or to_regprocedure('public.promote_alpha_purchase_orders(uuid,integer)') is null
    or to_regprocedure('public.search_purchase_order_products(uuid,text,integer)') is null then raise exception 'Faltan RPC de M3B.';end if;
  select ur.user_id into v_actor from public.user_roles ur join public.roles r on r.id=ur.role_id where r.code='super_admin' limit 1;
  if v_actor is null then raise exception 'La prueba requiere Super Admin.';end if;
  insert into public.companies(id,legal_name,display_name) values(v_company,'Compras 3B','Compras 3B'),(v_other,'Otra Compras 3B','Otra Compras 3B');
  insert into public.user_roles(user_id,role_id,company_id) select v_actor,id,v_company from public.roles where code='super_admin' on conflict do nothing;
  insert into auth.users(id,aud,role,email,encrypted_password) values(v_other_actor,'authenticated','authenticated','sin-permiso-3b@example.com','');
  insert into public.user_roles(user_id,role_id,company_id) select v_other_actor,id,v_other from public.roles where code='punto_venta';
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',v_actor::text,true);
  insert into public.suppliers(company_id,code,display_name,legal_entity_type,country_code,is_active) values(v_company,'SUP-3B','Proveedor 3B','moral','MX',true) returning id into v_supplier;
  insert into public.suppliers(company_id,code,display_name,legal_entity_type,country_code,is_active) values(v_other,'SUP-X','Proveedor ajeno','moral','MX',true) returning id into v_supplier_other;
  insert into public.products(company_id,alpha_sku,name,unit,product_type,is_active,is_inventory_tracked) values(v_company,'SKU-3B-1','Producto 3B uno','PZA','P. TERMINADO',true,true) returning id into v_product;
  insert into public.products(company_id,alpha_sku,name,unit,product_type,is_active,is_inventory_tracked) values(v_company,'SKU-3B-2','Producto 3B dos','PZA','P. TERMINADO',true,true) returning id into v_product_2;

  v_result:=public.search_purchase_order_products(v_company,'SKU-3B-1',30);
  if jsonb_array_length(v_result->'items')<>1
    or (v_result#>>'{items,0,id}')::uuid<>v_product
    or (v_result->'items'->0) ? 'price'
    or (v_result->'items'->0) ? 'blockers' then
    raise exception 'Selector ligero de productos incorrecto: %',v_result;
  end if;

  v_result:=public.save_purchase_order(v_company,null,v_supplier,'mxn','2026-07-16','2026-07-20','REF-1','REQ-1','Prueba',10,
    jsonb_build_array(jsonb_build_object('product_id',v_product,'description','Partida uno','unit','PZA','quantity',2,'unit_cost',10,'discount_percent_1',10),jsonb_build_object('product_id',v_product_2,'description','Partida dos','unit','PZA','quantity',1,'unit_cost',5)),null);
  v_order:=(v_result->>'id')::uuid;
  if v_result->>'status'<>'draft' or v_result->>'folio' not like 'OC-%' or (v_result->>'subtotal')::numeric<>25 or (v_result->>'line_discount_total')::numeric<>2 or (v_result->>'order_discount_total')::numeric<>2.3 or (v_result->>'total')::numeric<>20.7 then raise exception 'Creación o totales server-side incorrectos: %',v_result;end if;
  v_result:=public.save_purchase_order(v_company,v_order,v_supplier,'MXN','2026-07-16','2026-07-21','REF-2',null,'Editada',0,jsonb_build_array(jsonb_build_object('product_id',v_product,'description','Editada','quantity',3,'unit_cost',7)),(v_result->>'updated_at')::timestamptz);
  if (v_result->>'total')::numeric<>21 or (select count(*) from public.purchase_order_lines where purchase_order_id=v_order)<>1 then raise exception 'No se editó el borrador atómicamente.';end if;
  v_result:=public.submit_purchase_order(v_company,v_order,'Lista para revisión.');if v_result->>'status'<>'pending_approval' then raise exception 'No se envió a aprobación.';end if;
  begin update public.purchase_order_lines set quantity=99 where purchase_order_id=v_order;exception when others then v_forbidden:=position('sólo pueden modificarse' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Se modificó una partida enviada.';end if;v_forbidden:=false;
  v_result:=public.decide_purchase_order(v_company,v_order,'approved','Revisión conforme.');if v_result->>'status'<>'approved' then raise exception 'No se aprobó la OC.';end if;
  begin perform public.save_purchase_order(v_company,v_order,v_supplier,'MXN','2026-07-16',null,null,null,null,0,jsonb_build_array(jsonb_build_object('description','Indebida','quantity',1,'unit_cost',1)),null);exception when others then v_forbidden:=position('no admite edición' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Se editó una OC aprobada.';end if;v_forbidden:=false;
  if not exists(select 1 from public.purchase_order_decisions where purchase_order_id=v_order and decision='approved' and actor_id=v_actor and reason='Revisión conforme.') then raise exception 'Falta actor, fecha, decisión o motivo.';end if;

  v_result:=public.save_purchase_order(v_company,null,v_supplier,'USD','2026-07-16',null,null,null,null,0,jsonb_build_array(jsonb_build_object('product_id',v_product,'description','Para rechazo','quantity',1,'unit_cost',1)),null);v_rejected:=(v_result->>'id')::uuid;
  perform public.submit_purchase_order(v_company,v_rejected,null);
  begin perform public.decide_purchase_order(v_company,v_rejected,'rejected',null);exception when others then v_forbidden:=position('motivo' in lower(sqlerrm))>0;end;if not v_forbidden then raise exception 'Se rechazó sin motivo.';end if;v_forbidden:=false;
  v_result:=public.decide_purchase_order(v_company,v_rejected,'rejected','Presupuesto no confirmado.');if v_result->>'status'<>'rejected' then raise exception 'No se rechazó la OC.';end if;
  begin perform public.cancel_purchase_order(v_company,v_order,'');exception when others then v_forbidden:=position('motivo' in lower(sqlerrm))>0;end;if not v_forbidden then raise exception 'Se canceló sin motivo.';end if;v_forbidden:=false;
  v_result:=public.cancel_purchase_order(v_company,v_order,'Solicitud comercial documentada.');if v_result->>'status'<>'cancelled' then raise exception 'No se canceló la OC.';end if;
  begin update public.purchase_orders set notes='mutación' where id=v_order;exception when others then v_forbidden:=position('inmutable' in lower(sqlerrm))>0;end;if not v_forbidden then raise exception 'Se mutó una OC cancelada.';end if;v_forbidden:=false;

  v_result:=public.search_purchase_orders(v_company,'REF-2',null,null,null,null,null,1,1);if (v_result#>>'{pagination,total}')::int<>1 or jsonb_array_length(v_result->'items')<>1 then raise exception 'Catálogo server-side incorrecto: %',v_result;end if;
  v_result:=public.get_purchase_order_detail(v_company,v_order);if jsonb_array_length(v_result->'lines')<>1 or jsonb_array_length(v_result->'history')<>3 then raise exception 'Detalle o historial incompleto: %',v_result;end if;
  begin perform public.save_purchase_order(v_company,null,v_supplier_other,'MXN','2026-07-16',null,null,null,null,0,jsonb_build_array(jsonb_build_object('description','Cruce','quantity',1,'unit_cost',1)),null);exception when others then v_forbidden:=position('proveedor activo' in lower(sqlerrm))>0;end;if not v_forbidden then raise exception 'Se vinculó proveedor de otra empresa.';end if;v_forbidden:=false;

  select count(*) into v_inventory_before from public.inventory_balances;select count(*) into v_cost_before from public.product_costs;select count(*) into v_receivable_before from public.customer_receivables;select count(*) into v_receipt_before from public.purchase_receipts;
  insert into public.alpha_purchasing_import_batches(company_id,cutoff_date,content_sha256,status,records_received,imported_by,summary,completed_at,supplier_promotion_completed_at)
  values(v_company,'2026-07-08','purchase-order-3b-test','staged',5,v_actor,'{"purchase_orders":2,"purchase_order_lines":3,"error_count":0}',now(),now()) returning id into v_batch;
  insert into public.alpha_purchasing_import_suppliers(batch_id,external_code,display_name,source_row_number,source_row_hash,promoted_supplier_id)
  values(v_batch,'PRV-1','Proveedor 3B',1,'po-sup-1',v_supplier) returning id into v_stage_supplier;
  insert into public.alpha_purchasing_import_orders(batch_id,source_order_key,order_number,branch_code,supplier_external_code,supplier_name,ordered_date,currency_code,source_status,source_approval_status,discount_percent,source_row_number,source_row_hash) values
    (v_batch,'S1|100','100','S1','PRV-1','Proveedor 3B','2026-07-01','MXN','Aceptada','Aceptada',5,10,'po-head-1'),
    (v_batch,'S1|101','101','S1','NO-RESUELTO','Proveedor faltante','2026-07-02','MXN','Aceptada','Aceptada',0,20,'po-head-2');
  insert into public.alpha_purchasing_import_order_lines(batch_id,source_order_key,line_number,alpha_sku,description,quantity,unit_cost_mxn,discount_1,expected_date,source_row_number,source_row_hash) values
    (v_batch,'S1|100',1,'SKU-3B-1','Histórica uno',2,10,10,'2026-07-10',11,'po-line-1'),
    (v_batch,'S1|100',2,'SKU-3B-2','Histórica dos',1,5,0,'2026-07-11',12,'po-line-2'),
    (v_batch,'S1|101',1,'SKU-3B-1','Excepción',1,1,0,'2026-07-12',21,'po-line-3');
  v_result:=public.promote_alpha_purchase_orders(v_batch,1);if v_result->>'status'<>'in_progress' or (v_result#>>'{page,promoted}')::int<>1 then raise exception 'Primera página de promoción incorrecta: %',v_result;end if;
  v_result:=public.promote_alpha_purchase_orders(v_batch,1);if v_result->>'status'<>'completed_with_exceptions' or (v_result#>>'{summary,promoted_orders}')::int<>1 or (v_result#>>'{summary,promoted_lines}')::int<>2 or (v_result#>>'{summary,exceptions}')::int<>1 then raise exception 'Conciliación de promoción incorrecta: %',v_result;end if;
  if not exists(select 1 from public.purchase_orders po join public.purchase_order_external_references er on er.purchase_order_id=po.id where er.external_key='S1|100' and po.status='approved' and po.origin='imported_historical' and po.total=21.85) then raise exception 'La OC histórica no quedó aprobada, diferenciada o recalculada.';end if;
  v_result:=public.promote_alpha_purchase_orders(v_batch,100);if v_result->>'status'<>'already_promoted' or (select count(*) from public.purchase_order_external_references where company_id=v_company and source_system='alpha')<>1 then raise exception 'La promoción no es idempotente.';end if;
  if (select count(*) from public.inventory_balances)<>v_inventory_before or (select count(*) from public.product_costs)<>v_cost_before or (select count(*) from public.customer_receivables)<>v_receivable_before then raise exception '3B alteró inventario, costos o cuentas.';end if;
  if (select count(*) from public.purchase_receipts)<>v_receipt_before then raise exception 'La promoción de 3B creó recepciones.';end if;
  if not exists(select 1 from public.audit_log where company_id=v_company and action='alpha_purchase_orders.promoted' and entity_id=v_batch) then raise exception 'Falta auditoría de promoción.';end if;

  perform set_config('request.jwt.claim.sub',v_other_actor::text,true);
  begin perform public.search_purchase_orders(v_company,null,null,null,null,null,null,1,50);exception when others then v_forbidden:=position('No autorizado' in sqlerrm)>0;end;if not v_forbidden then raise exception 'Un usuario ajeno consultó OC.';end if;v_forbidden:=false;
  begin perform public.search_purchase_order_products(v_company,'SKU',30);exception when others then v_forbidden:=position('No autorizado' in sqlerrm)>0;end;if not v_forbidden then raise exception 'Un usuario ajeno consultó productos de OC.';end if;v_forbidden:=false;
  begin perform public.decide_purchase_order(v_company,v_rejected,'approved',null);exception when others then v_forbidden:=position('No autorizado' in sqlerrm)>0;end;if not v_forbidden then raise exception 'Un usuario sin permiso aprobó OC.';end if;
  raise notice 'Módulo 3B: workflow, totales, permisos, bloqueo, promoción, idempotencia, auditoría y aislamiento aprobados.';
end;
$test$;

rollback;
