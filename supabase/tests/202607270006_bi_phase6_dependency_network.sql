-- BI Fase 6: construcción, no duplicación, surtido/readiness, límites, RLS, drill-down y exportación.
begin;

do $installation$
begin
  if to_regprocedure('public.bi_dependency_network_query(uuid,date,date,uuid,uuid,uuid,uuid,text[],text,text,text,text,text,text,text,uuid,integer,integer,integer)')is null then raise exception'Falta BI Fase 6.';end if;
  if to_regprocedure('public.bi_supplier_dependency_overview(uuid,date,date,uuid,uuid,uuid,uuid,text,integer,integer)')is null then raise exception'Falta panorama ejecutivo por proveedor.';end if;
  if has_function_privilege('anon','public.bi_dependency_network_query(uuid,date,date,uuid,uuid,uuid,uuid,text[],text,text,text,text,text,text,text,uuid,integer,integer,integer)','execute')then raise exception'anon no debe consultar la red.';end if;
  if has_function_privilege('anon','public.bi_supplier_dependency_overview(uuid,date,date,uuid,uuid,uuid,uuid,text,integer,integer)','execute')then raise exception'anon no debe consultar dependencia por proveedor.';end if;
end;$installation$;

do $fixtures$
declare c1 uuid:='b1600000-0000-4000-8000-000000000001';c2 uuid:='b1600000-0000-4000-8000-000000000002';
u1 uuid:='b1600000-0000-4000-8000-000000000003';u2 uuid:='b1600000-0000-4000-8000-000000000004';
l1 uuid:='b1600000-0000-4000-8000-000000000005';l2 uuid:='b1600000-0000-4000-8000-000000000006';
cat uuid:='b1600000-0000-4000-8000-000000000007';p uuid:='b1600000-0000-4000-8000-000000000008';s uuid:='b1600000-0000-4000-8000-000000000009';
po uuid:='b1600000-0000-4000-8000-000000000010';pol uuid:='b1600000-0000-4000-8000-000000000011';
pr uuid:='b1600000-0000-4000-8000-000000000012';sa uuid:='b1600000-0000-4000-8000-000000000013';
begin
  insert into public.companies(id,legal_name,display_name)values(c1,'BI F6 A','BI F6 A'),(c2,'BI F6 B','BI F6 B');
  insert into auth.users(id,aud,role,email,encrypted_password)values(u1,'authenticated','authenticated','bi-f6-dir@example.com',''),(u2,'authenticated','authenticated','bi-f6-loc@example.com','');
  insert into public.user_roles(user_id,role_id,company_id)select u1,id,c1 from public.roles where code='direccion_admin';
  insert into public.user_roles(user_id,role_id,company_id)select u2,id,c1 from public.roles where code='ingeniero_campo';
  insert into public.role_permissions(role_id,permission_id)
    select r.id,p.id from public.roles r cross join public.permissions p where r.code='ingeniero_campo'and p.code in('view_bi','view_bi_dependency_network','expand_bi_dependency_network')on conflict do nothing;
  insert into public.locations(id,company_id,external_code,name,location_type)values(l1,c1,'L1','Centro','sucursal'),(l2,c1,'L2','Norte','sucursal');
  insert into public.user_location_access(user_id,location_id)values(u2,l1);
  insert into public.product_categories(id,company_id,external_code,name,source)values(cat,c1,'CAT-F6','Categoría F6','satrapy');
  insert into public.products(id,company_id,alpha_sku,internal_sku,name,category_id,is_active,is_sellable,is_inventory_tracked,commercial_review_required)
    values(p,c1,'LEG-F6','SKU-F6','Producto F6',cat,true,true,true,true);
  insert into public.suppliers(id,company_id,code,display_name)values(s,c1,'PROV-F6','Proveedor F6');
  insert into public.purchase_orders(id,company_id,supplier_id,folio,status,origin,currency_code,ordered_date,subtotal,total)
    values(po,c1,s,'OC-F6','approved','operational','MXN',date'2026-07-10',100,100);
  insert into public.purchase_order_lines(id,company_id,purchase_order_id,line_number,product_id,description,quantity,unit_cost)
    values(pol,c1,po,1,p,'Producto F6',10,10);
  insert into public.purchase_receipts(id,company_id,purchase_order_id,supplier_id,location_id,folio,status,receipt_date,client_request_id,confirmed_at,confirmed_by,confirm_request_id)
    values(pr,c1,po,s,l1,'REC-F6','confirmed',date'2026-07-12',gen_random_uuid(),now(),u1,gen_random_uuid());
  insert into public.purchase_receipt_lines(company_id,purchase_receipt_id,purchase_order_line_id,product_id,quantity,unit_cost)
    values(c1,pr,pol,p,10,10);
  insert into public.inventory_balances(company_id,location_id,product_id,quantity_on_hand)values(c1,l1,p,10),(c1,l2,p,0);
  insert into public.sales_assortments(id,company_id,code,name,status,valid_from)values(sa,c1,'SUR-F6','Surtido F6','active','2026-01-01');
  insert into public.sales_assortment_items(assortment_id,product_id)values(sa,p);
  insert into public.location_sales_assortments(location_id,assortment_id,valid_from)values(l1,sa,'2026-01-01');
end;$fixtures$;

set local role authenticated;
do $assertions$
declare c1 uuid:='b1600000-0000-4000-8000-000000000001';c2 uuid:='b1600000-0000-4000-8000-000000000002';
u1 uuid:='b1600000-0000-4000-8000-000000000003';u2 uuid:='b1600000-0000-4000-8000-000000000004';
l1 uuid:='b1600000-0000-4000-8000-000000000005';l2 uuid:='b1600000-0000-4000-8000-000000000006';
p uuid:='b1600000-0000-4000-8000-000000000008';s uuid:='b1600000-0000-4000-8000-000000000009';
r jsonb;e jsonb;d jsonb;overview jsonb;blocked boolean;job uuid;
begin
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u1::text,true);
  r:=public.bi_dependency_network_query(c1,date'2026-07-01',date'2026-07-31',null,null,null,null,null,null,null,'purchases','node_type','amount','supplier_dependency',null,null,0,120,240);
  select value into e from jsonb_array_elements(r->'edges')where value->>'type'='supplier_product';
  if(e->>'amount')::numeric<>100 then raise exception'Orden y recepción se duplicaron: %',e;end if;
  if e->>'metric_source'<>'confirmed_receipt'then raise exception'No prevaleció recepción confirmada.';end if;
  if not exists(select 1 from jsonb_array_elements(r->'edges')x where x->>'type'='product_location_assortment')then raise exception'Falta surtido comercial.';end if;
  if not exists(select 1 from jsonb_array_elements(r->'edges')x where x->>'type'='product_location_availability'and x->>'operational_state'='blocked_readiness')then raise exception'Falta bloqueo readiness separado.';end if;

  overview:=public.bi_supplier_dependency_overview(c1,date'2026-07-01',date'2026-07-31',null,null,null,null,null,1,24);
  if(overview->'pagination'->>'total')::integer<>1 or jsonb_array_length(overview->'items')<>1 then raise exception'Panorama por proveedor no paginó el total real: %',overview;end if;
  if((overview->'items'->0->>'total_amount')::numeric)<>100 then raise exception'Panorama duplicó etapas de compra: %',overview;end if;
  if(overview->'items'->0->>'unique_product_count')::integer<>1 then raise exception'Panorama no detectó proveedor único: %',overview;end if;
  if(overview->'items'->0->>'location_count')::integer<>1 then raise exception'Panorama no conservó cobertura por surtido: %',overview;end if;

  r:=public.bi_dependency_network_query(c1,date'2026-07-01',date'2026-07-31',null,null,null,null,null,null,null,'connections','node_type','frequency','selected_impact','product',p,99,2,2);
  if(r->'limits'->>'nodes')::integer<>2 or(r->'limits'->>'edges')::integer<>2 or(r->'limits'->>'expansion_levels')::integer<>2 then raise exception'Límites incorrectos.';end if;

  d:=public.bi_dependency_network_drilldown(c1,'supplier_product',s,p,date'2026-07-01',date'2026-07-31',1,1);
  if(d->'pagination'->>'total')::integer<>1 or jsonb_array_length(d->'items')<>1 then raise exception'Drill-down no paginó evidencia.';end if;

  perform set_config('request.jwt.claim.sub',u2::text,true);
  blocked:=false;begin perform public.bi_dependency_network_query(c1,date'2026-07-01',date'2026-07-31',l2,null,null,null,null,null,null,'purchases','node_type','amount','supplier_dependency',null,null,0,120,240);
  exception when others then blocked:=position('Ubicación no disponible' in sqlerrm)>0;end;
  if not blocked then raise exception'RLS lógico permitió ubicación ajena.';end if;
  r:=public.bi_dependency_network_query(c1,date'2026-07-01',date'2026-07-31',l1,null,null,null,null,null,null,'purchases','node_type','amount','supplier_dependency',null,null,0,120,240);
  if exists(select 1 from jsonb_array_elements(r->'nodes')x where x->>'id'='location:'||l2::text)then raise exception'Respuesta filtró ubicación sólo en cliente.';end if;
  blocked:=false;begin perform public.bi_dependency_network_query(c2,date'2026-07-01',date'2026-07-31',null,null,null,null,null,null,null,'purchases','node_type','amount','supplier_dependency',null,null,0,120,240);
  exception when others then blocked:=position('No autorizado' in sqlerrm)>0;end;
  if not blocked then raise exception'Se consultó otra empresa.';end if;

  perform set_config('request.jwt.claim.sub',u1::text,true);
  job:=public.bi_start_network_export(c1,'xlsx','{"kind":"network","date_from":"2026-07-01","date_to":"2026-07-31","relation_types":[],"size_metric":"purchases","color_metric":"node_type","edge_metric":"amount","perspective":"supplier_dependency"}');
  perform public.bi_finish_export(job,'completed',8,4096,'{"test":true}');
  if not exists(select 1 from public.bi_export_jobs where id=job and status='completed')then raise exception'Exportación no quedó auditada.';end if;
end;$assertions$;
reset role;
rollback;
