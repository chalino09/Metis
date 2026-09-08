begin;
do $$
declare c uuid:=gen_random_uuid();u uuid:=gen_random_uuid();other_company uuid:=gen_random_uuid();loc uuid:=gen_random_uuid();tax uuid:=gen_random_uuid();ing uuid;dish uuid;base uuid;req uuid:=gen_random_uuid();payload jsonb;result jsonb;ctx jsonb;preview jsonb;before_count integer;versions_before integer;viewer uuid:=gen_random_uuid();viewer_role uuid:=gen_random_uuid();side_dish uuid;core uuid:=gen_random_uuid();
begin
  insert into public.companies(id,legal_name,display_name,product_experience_code) values(c,'Prueba estudio culinario','Prueba estudio culinario','restaurant'),(other_company,'Otro restaurante','Otro restaurante','restaurant'),(core,'ERP intacto','ERP intacto','core');
  insert into auth.users(id,aud,role,email,encrypted_password) values(u,'authenticated','authenticated','studio-'||u||'@example.invalid','');
  insert into public.user_roles(user_id,role_id,company_id) select u,id,c from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);
  insert into public.locations(id,company_id,external_code,name,location_type,is_active) values(loc,c,'COCINA-TEST','Cocina de prueba','sucursal',true);
  insert into public.tax_categories(id,company_id,code,name) values(tax,c,'IVA16','IVA 16%');
  insert into public.tax_rates(tax_category_id,jurisdiction_code,rate,valid_from) values(tax,'MX',.16,now()-interval '1 day');
  ctx:=public.get_restaurant_studio_context(c,null);
  if jsonb_array_length(ctx->'locations')<>1 then raise exception 'El contexto no ofrece la sucursal existente';end if;
  result:=public.save_restaurant_ingredient_studio(c,'{"name":"Arrachera","unit":"g","purchase_unit":"KG","purchase_factor":1000}',gen_random_uuid());ing:=(result->>'id')::uuid;
  insert into public.product_costs(company_id,product_id,cost_type,amount,currency_code,valid_from) values(c,ing,'replacement_cost',.24,'MXN',now()-interval '1 day');
  payload:=jsonb_build_object('name','Tacos de arrachera','kind','dish','portions',10,'waste_percent',0,'components',jsonb_build_array(jsonb_build_object('product_id',ing,'quantity',1.5,'unit_code','kg','base_unit_code','g','notes','Cortar al servir')),'category','Platos fuertes','finish',true,'available',true,'final_price',116,'tax_category_id',tax,'assortment_ids','[]'::jsonb,'location_ids',jsonb_build_array(loc));
  preview:=public.preview_restaurant_recipe_cost(c,payload->'components',10,0,'MXN');
  if (preview->>'total_cost')::numeric<>360 or (preview->>'cost_per_portion')::numeric<>36 then raise exception 'Costo de tanda incorrecto: %',preview;end if;
  select count(*) into before_count from public.products where company_id=c;
  begin
    perform public.save_restaurant_studio(c,payload||'{"final_price":-1}',req);
    raise exception 'TEST: aceptó precio inválido';
  exception when others then if sqlerrm like 'TEST:%' then raise;end if;end;
  if (select count(*) from public.products where company_id=c)<>before_count then raise exception 'El error dejó productos parciales';end if;
  if exists(select 1 from public.culinary_recipes where company_id=c) then raise exception 'El error dejó recetas parciales';end if;
  result:=public.save_restaurant_studio(c,payload,req);dish:=(result->>'product_id')::uuid;
  if result<>public.save_restaurant_studio(c,payload,req) then raise exception 'El reintento cambió la respuesta';end if;
  if (select count(*) from public.products where company_id=c and name='Tacos de arrachera')<>1 then raise exception 'El reintento duplicó el platillo';end if;
  if (select entered_quantity from public.culinary_recipe_components component join public.culinary_recipe_versions version on version.id=component.recipe_version_id join public.culinary_recipes recipe on recipe.id=version.recipe_id where recipe.product_id=dish)<>.15 then raise exception 'La tanda no se normalizó a una porción';end if;
  if not exists(select 1 from public.product_prices where product_id=dish and amount=100) then raise exception 'El precio no descontó el impuesto';end if;
  -- Emula la siguiente petición HTTP: el precio ya es vigente al comenzar la consulta.
  update public.product_prices set valid_from=now()-interval '1 second' where product_id=dish;
  update public.culinary_recipe_versions set valid_from=now()-interval '1 second' where id=(result->>'version_id')::uuid;
  ctx:=public.get_restaurant_studio_context(c,dish);
  if jsonb_array_length(ctx->'prices')<>1 or ctx#>>'{presentation,batch_portions}'<>'10' then raise exception 'No se recuperó el platillo completo: %',ctx;end if;
  if ctx#>>'{recipe,active,components,0,notes}'<>'Cortar al servir' then raise exception 'No se conservaron las notas de cocina';end if;
  if ctx#>>'{location_status,0,available}'<>'false' then raise exception 'Mostró disponible un platillo sin existencias';end if;
  select count(*) into versions_before from public.culinary_recipe_versions v join public.culinary_recipes r on r.id=v.recipe_id where r.product_id=dish;
  payload:=payload||jsonb_build_object('id',dish,'updated_at',ctx#>>'{product,updated_at}','recipe_revision',ctx->>'recipe_revision','available',false);
  perform public.save_restaurant_studio(c,payload,gen_random_uuid());
  if (select count(*) from public.culinary_recipe_versions v join public.culinary_recipes r on r.id=v.recipe_id where r.product_id=dish)<>versions_before then raise exception 'Cambiar venta creó una versión innecesaria';end if;
  if not exists(select 1 from public.sales_assortment_items where product_id=dish) then raise exception 'Apagar POS eliminó la pertenencia comercial';end if;
  begin perform public.save_restaurant_studio(c,payload,gen_random_uuid());raise exception 'TEST: aceptó edición obsoleta';exception when others then if sqlerrm like 'TEST:%' then raise;end if;end;
  -- Una base cuesta por su rendimiento físico al reutilizarla en otro platillo.
  result:=public.save_restaurant_studio(c,jsonb_build_object('name','Base reutilizable','kind','preparation','portions',1,'yield_quantity',1000,'yield_unit','g','waste_percent',0,'components',jsonb_build_array(jsonb_build_object('product_id',ing,'quantity',1,'unit_code','kg','base_unit_code','g')),'finish',true,'available',false),gen_random_uuid());base:=(result->>'product_id')::uuid;
  update public.culinary_recipe_versions set valid_from=now()-interval '1 second' where id=(result->>'version_id')::uuid;
  preview:=public.preview_restaurant_recipe_cost(c,jsonb_build_array(jsonb_build_object('product_id',base,'quantity',250,'unit_code','g','base_unit_code','g')),2,0,'MXN');
  if (preview->>'total_cost')::numeric<>60 or (preview->>'cost_per_portion')::numeric<>30 then raise exception 'Costo de base reutilizada incorrecto: %',preview;end if;
  -- Guardar inactivo no debe fallar por la regla canónica de receta activa.
  ctx:=public.get_restaurant_studio_context(c,base);
  perform public.save_restaurant_studio(c,jsonb_build_object('id',base,'updated_at',ctx#>>'{product,updated_at}','recipe_revision',ctx->>'recipe_revision','name','Base reutilizable','kind','preparation','portions',1,'yield_quantity',1000,'yield_unit','g','waste_percent',0,'components',jsonb_build_array(jsonb_build_object('product_id',ing,'quantity',1,'unit_code','kg','base_unit_code','g')),'finish',true,'is_active',false),gen_random_uuid());
  if (select is_active from public.products where id=base) then raise exception 'No se desactivó la base';end if;
  -- Comida completa conserva opciones canónicas al volver a abrir el platillo.
  result:=public.save_restaurant_studio(c,(payload - 'id' - 'updated_at' - 'recipe_revision')||jsonb_build_object('name','Guarnición de prueba','available',true),gen_random_uuid());side_dish:=(result->>'product_id')::uuid;
  ctx:=public.get_restaurant_studio_context(c,dish);
  payload:=payload||jsonb_build_object('updated_at',ctx#>>'{product,updated_at}','recipe_revision',ctx->>'recipe_revision','bundle',jsonb_build_object('is_active',true,'combo_price_amount','150','groups',jsonb_build_array(jsonb_build_object('name','Sopa','minimum_selections',1,'maximum_selections',1,'options',jsonb_build_array(jsonb_build_object('id',side_dish)))),'extras',jsonb_build_array(jsonb_build_object('id',side_dish))));
  perform public.save_restaurant_studio(c,payload,gen_random_uuid());
  ctx:=public.get_restaurant_studio_context(c,dish);
  if ctx#>>'{bundle,combo_price_amount}'<>'150.00' or ctx#>>'{bundle,groups,0,options,0,id}'<>side_dish::text then raise exception 'No se recuperó la comida completa';end if;
  -- Imagen inválida revierte el guardado y conserva la presentación anterior.
  begin perform public.save_restaurant_studio(c,payload||jsonb_build_object('updated_at',ctx#>>'{product,updated_at}','recipe_revision',ctx->>'recipe_revision','image_data','data:image/svg+xml;base64,AAAA'),gen_random_uuid());raise exception 'TEST: aceptó imagen no permitida';exception when others then if sqlerrm like 'TEST:%' then raise;end if;end;
  if (select image_data from public.restaurant_menu_presentations where product_id=dish) is not null then raise exception 'Persistió la imagen inválida';end if;
  -- Sin costo no debe aparecer cero, ni un subtotal como si fuera costo completo.
  update public.product_costs set valid_to=now()-interval '1 second' where product_id=ing;
  preview:=public.preview_restaurant_recipe_cost(c,payload->'components',10,0,'MXN');
  if preview->>'allowed'<>'false' or preview->>'total_cost' is not null then raise exception 'Se inventó un costo sin respaldo';end if;
  begin perform public.get_restaurant_studio_context(other_company,dish);raise exception 'TEST: permitió otra empresa';exception when others then if sqlerrm like 'TEST:%' then raise;end if;end;
  begin perform public.get_restaurant_studio_context(core,null);raise exception 'TEST: abrió el ERP';exception when others then if sqlerrm like 'TEST:%' then raise;end if;end;
  -- Lectura limitada: no filtra costos ni precios de comidas completas.
  insert into auth.users(id,aud,role,email,encrypted_password) values(viewer,'authenticated','authenticated','viewer-'||viewer||'@example.invalid','');
  insert into public.roles(id,code,display_name,description,company_id,is_system) values(viewer_role,'studio_viewer_'||viewer_role,'Lector de recetas','Prueba de aislamiento de costos',c,false);
  insert into public.role_permissions(role_id,permission_id) select viewer_role,id from public.permissions where code in('view_products','view_recipes');
  insert into public.user_roles(user_id,role_id,company_id) values(viewer,viewer_role,c);
  perform set_config('request.jwt.claim.sub',viewer::text,true);
  ctx:=public.get_restaurant_studio_context(c,dish);
  if ctx#>'{recipe,active,cost}' is not null or ctx#>>'{bundle,combo_price_amount}' is not null or jsonb_array_length(ctx->'prices')<>0 then raise exception 'El contexto filtró costos o precios';end if;
  preview:=public.preview_restaurant_recipe_cost(c,payload->'components',10,0,'MXN');
  if preview->>'can_view'<>'false' or preview->>'total_cost' is not null then raise exception 'El costeo ignoró permisos';end if;
  perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
  begin perform public.save_restaurant_studio(c,payload,gen_random_uuid());raise exception 'TEST: guardó sin permisos';exception when others then if sqlerrm like 'TEST:%' then raise;end if;end;
  raise notice 'PASS: costeo, atomicidad, idempotencia, porciones, impuesto, pertenencia, concurrencia, bases, notas, edición inactiva, comidas completas, imágenes, aislamiento y permisos';
end$$;
rollback;
