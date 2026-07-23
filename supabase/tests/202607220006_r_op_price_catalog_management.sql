begin;
do $r_op_prices$
declare
  v_company uuid:='d6000000-0000-4000-8000-000000000001';v_admin uuid:='d6000000-0000-4000-8000-000000000002';v_operator uuid:='d6000000-0000-4000-8000-000000000003';v_product uuid;v_list uuid;result jsonb;replay jsonb;stamp timestamptz;first_price uuid;blocked boolean:=false;
begin
  insert into public.companies(id,legal_name,display_name) values(v_company,'Empresa precios R-OP','Empresa precios R-OP');
  insert into auth.users(id,aud,role,email,encrypted_password) values(v_admin,'authenticated','authenticated','admin-prices-r-op@example.com',''),(v_operator,'authenticated','authenticated','operator-prices-r-op@example.com','');
  insert into public.user_roles(user_id,role_id,company_id) select v_admin,id,v_company from public.roles where code='direccion_admin' union all select v_operator,id,v_company from public.roles where code='sucursal';
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',v_admin::text,true);
  v_product:=(public.save_product(v_company,null,'PRECIO-001','Producto con precio',null,'PZA',null,true,true,true,'Alta para precios',null,'d6000000-0000-4000-8000-000000000010')->>'id')::uuid;
  result:=public.save_price_list(v_company,null,' menudeo ','Menudeo','mxn',true,true,'Alta inicial',null,'d6000000-0000-4000-8000-000000000011');v_list:=(result->>'id')::uuid;
  if result->>'internal_code'<>'MENUDEO' or result->>'external_code' is not null or not (result->>'is_default')::boolean then raise exception 'La lista manual no quedó canónica: %',result;end if;
  if (select default_price_list_id from public.companies where id=v_company)<>v_list then raise exception 'La lista predeterminada no configuró la empresa vacía.';end if;
  replay:=public.save_price_list(v_company,null,'MENUDEO','Menudeo','MXN',true,true,'Alta inicial',null,'d6000000-0000-4000-8000-000000000011');
  if not (replay->>'idempotent')::boolean or (replay->>'id')::uuid<>v_list then raise exception 'La lista no es idempotente.';end if;
  result:=public.save_product_price(v_company,v_list,v_product,125.50,null,'Precio inicial','d6000000-0000-4000-8000-000000000012');first_price:=(result->>'id')::uuid;
  if (result->>'amount')::numeric<>125.5 then raise exception 'No se creó el precio.';end if;
  replay:=public.save_product_price(v_company,v_list,v_product,125.50,null,'Precio inicial','d6000000-0000-4000-8000-000000000012');if not (replay->>'idempotent')::boolean or (replay->>'id')::uuid<>first_price then raise exception 'El precio no es idempotente.';end if;
  perform pg_sleep(0.002);
  result:=public.save_product_price(v_company,v_list,v_product,130,null,'Ajuste de precio','d6000000-0000-4000-8000-000000000013');
  if not exists(select 1 from public.product_prices price where price.id=first_price and price.valid_to is not null) or (select count(*) from public.product_prices price where price.product_id=v_product and price.price_list_id=v_list)<>2 then raise exception 'El ajuste sobrescribió el historial.';end if;
  if jsonb_array_length(public.list_price_lists_admin(v_company))<>1 or (public.search_price_list_products(v_company,v_list,'PRECIO-001',1,50)->>'total')::integer<>1 then raise exception 'La consulta administrativa no devuelve la empresa creada desde cero.';end if;
  select updated_at into stamp from public.price_lists where id=v_list;perform pg_sleep(0.002);
  perform public.save_price_list(v_company,v_list,'MENUDEO','Menudeo actualizado','MXN',false,false,'Desactivación',stamp,'d6000000-0000-4000-8000-000000000014');
  if (select default_price_list_id from public.companies where id=v_company) is not null then raise exception 'La desactivación conservó una lista predeterminada inválida.';end if;
  begin perform public.save_product_price(v_company,v_list,v_product,150,null,'Intento inactivo','d6000000-0000-4000-8000-000000000015');exception when others then blocked:=position('no está activa' in lower(sqlerrm))>0;end;if not blocked then raise exception 'Una lista inactiva recibió precios.';end if;blocked:=false;
  perform set_config('request.jwt.claim.sub',v_operator::text,true);
  begin perform public.save_price_list(v_company,null,'MAYOREO','Mayoreo','MXN',true,false,'Sin permiso',null,'d6000000-0000-4000-8000-000000000016');exception when others then blocked:=position('no autorizado' in lower(sqlerrm))>0;end;if not blocked then raise exception 'Un operador sin permiso administró listas.';end if;
  if (select count(*) from public.audit_log audit where audit.company_id=v_company and audit.action='price_list.admin_saved')<>2 or (select count(*) from public.audit_log audit where audit.company_id=v_company and audit.action='price.admin_saved')<>2 then raise exception 'La auditoría administrativa no conserva listas y vigencias.';end if;
  raise notice 'R-OP precios: identidad canónica, empresa vacía, historial, idempotencia, permisos y auditoría aprobados.';
end;$r_op_prices$;
rollback;
