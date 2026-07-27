-- BI Fase 5: versiones, jerarquía, importación, resultado real, atribución y RLS.
begin;

do $installation$
begin
  if to_regprocedure('public.bi_approve_budget_version(uuid,uuid,text)')is null then raise exception'Falta BI Fase 5.';end if;
  if has_function_privilege('anon','public.bi_list_budget_performance(uuid,text,date,date,integer,integer)','execute')then raise exception'anon no debe consultar presupuestos.';end if;
end;$installation$;

do $fixtures$
declare c uuid:='b1500000-0000-4000-8000-000000000001';director uuid:='b1500000-0000-4000-8000-000000000002';engineer uuid:='b1500000-0000-4000-8000-000000000003';
l1 uuid:='b1500000-0000-4000-8000-000000000004';l2 uuid:='b1500000-0000-4000-8000-000000000005';cat uuid:='b1500000-0000-4000-8000-000000000006';
p uuid:='b1500000-0000-4000-8000-000000000007';col uuid:='b1500000-0000-4000-8000-000000000008';reg uuid:='b1500000-0000-4000-8000-000000000009';
session uuid:='b1500000-0000-4000-8000-000000000010';sale uuid:='b1500000-0000-4000-8000-000000000011';
begin
  insert into public.companies(id,legal_name,display_name)values(c,'BI Fase 5','BI Fase 5');
  insert into auth.users(id,aud,role,email,encrypted_password)values(director,'authenticated','authenticated','bi-f5-dir@example.com',''),(engineer,'authenticated','authenticated','bi-f5-eng@example.com','');
  insert into public.user_roles(user_id,role_id,company_id)select director,id,c from public.roles where code='direccion_admin';
  insert into public.user_roles(user_id,role_id,company_id)select engineer,id,c from public.roles where code='ingeniero_campo';
  insert into public.locations(id,company_id,external_code,name,location_type)values(l1,c,'L1','Centro','sucursal'),(l2,c,'L2','Norte','sucursal');
  insert into public.user_location_access(user_id,location_id)values(engineer,l1);
  insert into public.product_categories(id,company_id,external_code,name)values(cat,c,'CAT-1','Consumibles');
  insert into public.products(id,company_id,alpha_sku,name,category_id)values(p,c,'SKU-1','Producto',cat);
  insert into public.collaborators(id,company_id,code,display_name,job_title,hired_at)values(col,c,'ING-1','Ingeniero Uno','Ingeniero',date'2025-01-01');
  insert into public.cash_registers(id,company_id,location_id,code,display_name,currency_code)values(reg,c,l1,'CAJA-1','Caja','MXN');
  insert into public.cash_sessions(id,company_id,cash_register_id,location_id,opened_by,status,opening_amount)values(session,c,reg,l1,director,'open',0);
  insert into public.sales(id,company_id,location_id,cash_register_id,cash_session_id,cashier_id,sale_type,currency_code,subtotal_amount,discount_amount,tax_amount,total_amount,client_request_id,completed_at)
  values(sale,c,l1,reg,session,director,'cash','MXN',1000,0,160,1160,gen_random_uuid(),date'2026-07-10');
  insert into public.sale_items(sale_id,product_id,product_code,product_name,unit_name,quantity,unit_price_amount,gross_amount,discount_percent,discount_amount,taxable_amount,tax_amount,total_amount)
  values(sale,p,'SKU-1','Producto','pieza',10,100,1000,0,0,1000,160,1160);
end;$fixtures$;

set local role authenticated;

do $assertions$
declare c uuid:='b1500000-0000-4000-8000-000000000001';director uuid:='b1500000-0000-4000-8000-000000000002';engineer uuid:='b1500000-0000-4000-8000-000000000003';
l1 uuid:='b1500000-0000-4000-8000-000000000004';cat uuid:='b1500000-0000-4000-8000-000000000006';col uuid:='b1500000-0000-4000-8000-000000000008';sale uuid:='b1500000-0000-4000-8000-000000000011';
parent jsonb;child jsonb;replacement jsonb;result jsonb;batch jsonb;view_result jsonb;blocked boolean;
begin
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',director::text,true);
  perform public.link_collaborator_user(c,col,engineer,date'2026-01-01',null,'Vínculo laboral comprobado');
  perform public.assign_sale_responsible(c,sale,col,'Responsable confirmado en operación');

  parent:=public.bi_save_budget_draft(c,null,'Venta empresa julio',null,'net_sales','monthly',date'2026-07-01','company',null,null,null,2000,'MXN',director,null,null,'Alta anual autorizada');
  parent:=public.bi_approve_budget_version(c,(parent->>'id')::uuid,'Aprobado por dirección');
  result:=public.bi_get_budget_detail(c,(parent->>'id')::uuid);
  if(result->'actual'->>'value')::numeric<>1000 then raise exception'Venta real incorrecta: %',result;end if;

  blocked:=false;begin update public.bi_budget_versions set value=999 where id=(parent->>'id')::uuid;exception when others then blocked:=position('no puede modificarse' in sqlerrm)>0;end;
  if not blocked then raise exception'Se modificó una versión aprobada.';end if;

  child:=public.bi_save_budget_draft(c,null,'Centro julio',null,'net_sales','monthly',date'2026-07-01','location',l1,null,null,1200,'MXN',director,(parent->>'id')::uuid,null,'Distribución a tienda');
  child:=public.bi_approve_budget_version(c,(child->>'id')::uuid,'Distribución autorizada');
  result:=public.bi_list_budget_performance(c,'approved',date'2026-07-01',date'2026-07-31',1,25);
  if not exists(select 1 from jsonb_array_elements(result->'items')x where x->>'id'=parent->>'id'and(x->>'assigned_value')::numeric=1200)then raise exception'No se calculó distribución.';end if;

  blocked:=false;begin perform public.bi_save_budget_draft(c,null,'Categoría arbitraria',null,'net_sales','monthly',date'2026-07-01','category',null,null,cat,100,'MXN',director,(parent->>'id')::uuid,null,'Combinación no soportada');exception when others then blocked:=position('jerarquía' in sqlerrm)>0;end;
  if not blocked then raise exception'Se permitió una combinación jerárquica arbitraria.';end if;

  replacement:=public.bi_save_budget_draft(c,null,'Venta empresa julio v2',null,'net_sales','monthly',date'2026-07-01','company',null,null,null,2200,'MXN',director,null,(parent->>'id')::uuid,'Nueva versión por revisión');
  replacement:=public.bi_approve_budget_version(c,(replacement->>'id')::uuid,'Sustituye meta anterior');
  if not exists(select 1 from public.bi_budget_versions where id=(parent->>'id')::uuid and status='superseded')then raise exception'No se sustituyó versión anterior.';end if;

  batch:=public.bi_stage_budget_import(c,gen_random_uuid(),'presupuestos.csv','sha-f5',
    '[{"name":"Unidades julio","metric_code":"units_sold","period_type":"monthly","period_start":"2026-07-01","scope_type":"responsible_category","responsible_code":"ING-1","category_code":"CAT-1","location_code":"","value":"25","unit_code":"unit"}]');
  if(batch->>'status')<>'staged'then raise exception'Staging válido falló: %',batch;end if;
  result:=public.bi_promote_budget_import(c,(batch->>'batch_id')::uuid,'Lote validado');
  result:=public.bi_promote_budget_import(c,(batch->>'batch_id')::uuid,'Reintento idempotente');
  if not(result->>'idempotent')::boolean then raise exception'Promoción no fue idempotente.';end if;

  view_result:=public.bi_explorer_query(c,array['net_sales_budget'],'period','line',date'2026-07-01',date'2026-07-31',null,null,null,null,true,1,25);
  if(view_result->'trace'->>'query')<>'bi_budget_explorer_query'then raise exception'Explorador no reutilizó extensión presupuestal.';end if;

  perform set_config('request.jwt.claim.sub',engineer::text,true);
  result:=public.bi_list_budget_performance(c,null,date'2026-07-01',date'2026-07-31',1,100);
  if exists(select 1 from jsonb_array_elements(result->'items')x where x->>'scope_type'<>'responsible'and x->>'scope_type'<>'responsible_category')then raise exception'Ingeniero vio metas fuera de su alcance.';end if;
  if not exists(select 1 from jsonb_array_elements(result->'items')x where x->>'collaborator_id'=col::text)then raise exception'Ingeniero no vio su meta autorizada.';end if;
end;$assertions$;

reset role;
rollback;
