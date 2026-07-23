begin;

do $test$
declare
  v_actor uuid;
  v_company uuid:='39000000-0000-4000-8000-000000000001';
  v_other uuid:='39000000-0000-4000-8000-000000000002';
  v_supplier uuid;v_product uuid;v_inactive uuid;v_non_inventory uuid;v_other_product uuid;
  v_order uuid;v_historical uuid;v_result jsonb;v_forbidden boolean:=false;
begin
  select ur.user_id into v_actor
  from public.user_roles ur join public.roles r on r.id=ur.role_id
  where r.code='super_admin' limit 1;
  if v_actor is null then raise exception 'La prueba requiere Super Admin.';end if;

  insert into public.companies(id,legal_name,display_name)
  values(v_company,'OC canónica','OC canónica'),(v_other,'Otra OC canónica','Otra OC canónica');
  insert into public.user_roles(user_id,role_id,company_id)
  select v_actor,id,v_company from public.roles where code='super_admin' on conflict do nothing;
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_actor::text,true);

  insert into public.suppliers(company_id,code,display_name,legal_entity_type,country_code,is_active)
  values(v_company,'SUP-CANON','Proveedor canónico','moral','MX',true) returning id into v_supplier;
  insert into public.products(company_id,alpha_sku,name,unit,product_type,is_active,is_inventory_tracked) values
    (v_company,'CANON-1','Producto canónico','PZA','P. TERMINADO',true,true) returning id into v_product;
  insert into public.products(company_id,alpha_sku,name,unit,product_type,is_active,is_inventory_tracked) values
    (v_company,'CANON-2','Producto inactivo','PZA','P. TERMINADO',false,true) returning id into v_inactive;
  update public.products set is_active=false where id=v_inactive;
  insert into public.products(company_id,alpha_sku,name,unit,product_type,is_active,is_inventory_tracked) values
    (v_company,'CANON-3','Producto sin inventario','SERV','SERVICIO',true,false) returning id into v_non_inventory;
  insert into public.products(company_id,alpha_sku,name,unit,product_type,is_active,is_inventory_tracked) values
    (v_other,'CANON-X','Producto ajeno','PZA','P. TERMINADO',true,true) returning id into v_other_product;

  v_result:=public.save_purchase_order(v_company,null,v_supplier,'MXN','2026-07-16',null,null,null,null,0,
    jsonb_build_array(jsonb_build_object('product_id',v_product,'description','Producto canónico','unit','PZA','quantity',10,'unit_cost',20)),null);
  v_order:=(v_result->>'id')::uuid;
  if not exists(select 1 from public.purchase_order_lines where purchase_order_id=v_order and product_id=v_product) then raise exception 'La OC válida perdió el producto canónico.';end if;

  begin
    perform public.save_purchase_order(v_company,null,v_supplier,'MXN','2026-07-16',null,null,null,null,0,
      jsonb_build_array(jsonb_build_object('description','Texto libre','quantity',1,'unit_cost',1)),null);
  exception when others then v_forbidden:=position('producto canónico' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Se guardó una OC operativa con texto libre.';end if;v_forbidden:=false;

  begin
    perform public.save_purchase_order(v_company,null,v_supplier,'MXN','2026-07-16',null,null,null,null,0,
      jsonb_build_array(jsonb_build_object('product_id',v_other_product,'description','Producto ajeno','quantity',1,'unit_cost',1)),null);
  exception when others then v_forbidden:=position('no pertenece a la empresa' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Se vinculó un producto de otra empresa.';end if;v_forbidden:=false;

  begin
    perform public.save_purchase_order(v_company,null,v_supplier,'MXN','2026-07-16',null,null,null,null,0,
      jsonb_build_array(jsonb_build_object('product_id',v_inactive,'description','Producto inactivo','quantity',1,'unit_cost',1)),null);
  exception when others then v_forbidden:=position('activo y controlar inventario' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Se vinculó un producto inactivo.';end if;v_forbidden:=false;

  begin
    perform public.save_purchase_order(v_company,null,v_supplier,'MXN','2026-07-16',null,null,null,null,0,
      jsonb_build_array(jsonb_build_object('product_id',v_non_inventory,'description','Servicio','quantity',1,'unit_cost',1)),null);
  exception when others then v_forbidden:=position('activo y controlar inventario' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Se vinculó una partida sin control de inventario.';end if;v_forbidden:=false;

  update public.products set is_active=false where id=v_product;
  begin perform public.submit_purchase_order(v_company,v_order,null);
  exception when others then v_forbidden:=position('producto canónico activo' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Se envió una OC cuyo producto dejó de estar activo.';end if;v_forbidden:=false;
  update public.products set is_active=true where id=v_product;
  perform public.submit_purchase_order(v_company,v_order,null);

  insert into public.purchase_orders(company_id,supplier_id,folio,status,origin,currency_code,ordered_date)
  values(v_company,v_supplier,'OCH-CANON-1','draft','imported_historical','MXN','2026-07-01') returning id into v_historical;
  insert into public.purchase_order_lines(company_id,purchase_order_id,line_number,description,quantity,unit_cost)
  values(v_company,v_historical,1,'Evidencia histórica sin vínculo inequívoco',1,1);
  update public.purchase_orders set status='approved' where id=v_historical;
  if not exists(select 1 from public.purchase_order_lines where purchase_order_id=v_historical and product_id is null) then raise exception 'Se alteró la compatibilidad histórica.';end if;

  raise notice 'Integración M3B-M3C: producto canónico, empresa, vigencia, inventario y compatibilidad histórica aprobados.';
end;
$test$;

rollback;
