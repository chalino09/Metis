begin;

do $$
declare
  c uuid:='81800002-0000-4000-8000-000000000001';
  u uuid:='81800002-0000-4000-8000-000000000002';
  free_ingredient uuid:='81800002-0000-4000-8000-000000000003';
  recipe_ingredient uuid:='81800002-0000-4000-8000-000000000004';
  stocked_ingredient uuid:='81800002-0000-4000-8000-000000000005';
  dish uuid:='81800002-0000-4000-8000-000000000006';
  location_id uuid:='81800002-0000-4000-8000-000000000007';
  recipe_id uuid:='81800002-0000-4000-8000-000000000008';
  version_id uuid:='81800002-0000-4000-8000-000000000009';
  archived jsonb;
  blocked boolean:=false;
begin
  insert into public.companies(id,legal_name,display_name,product_experience_code)
  values(c,'Archivo de insumos','Archivo de insumos','restaurant');
  insert into auth.users(id,aud,role,email,encrypted_password)
  values(u,'authenticated','authenticated','archive-ingredients@example.invalid','');
  insert into public.user_roles(user_id,role_id,company_id)
  select u,id,c from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',u::text,true);

  insert into public.products(id,company_id,internal_sku,name,unit,is_inventory_tracked,is_active)
  values
    (free_ingredient,c,'ING-LIBRE','Insumo libre','g',true,true),
    (recipe_ingredient,c,'ING-RECETA','Insumo en receta','g',true,true),
    (stocked_ingredient,c,'ING-STOCK','Insumo con existencias','g',true,true),
    (dish,c,'DISH-ARCH','Platillo de prueba','piece',false,true);
  insert into public.product_culinary_roles(company_id,product_id,role,assigned_by,reason)
  values
    (c,free_ingredient,'ingredient',u,'Prueba de archivo'),
    (c,recipe_ingredient,'ingredient',u,'Prueba de archivo'),
    (c,stocked_ingredient,'ingredient',u,'Prueba de archivo'),
    (c,dish,'dish',u,'Prueba de archivo');

  archived:=public.archive_restaurant_ingredient(c,free_ingredient,'Registro de prueba sin uso','81800002-0000-4000-8000-000000000010');
  if archived->>'archived'<>'true' or (select is_active from public.products where id=free_ingredient) then
    raise exception 'El insumo sin dependencias no se archivó: %',archived;
  end if;
  archived:=public.archive_restaurant_ingredient(c,free_ingredient,'Registro de prueba sin uso','81800002-0000-4000-8000-000000000010');
  if archived->>'idempotent'<>'true' then
    raise exception 'El archivo no fue idempotente: %',archived;
  end if;
  if (public.search_restaurant_catalog(c,'ingredient',null,1,50,null)->>'total')::integer<>3
    or (public.search_restaurant_catalog(c,'ingredient',null,1,50,true)->>'total')::integer<>2
    or (public.search_restaurant_catalog(c,'ingredient',null,1,50,false)->>'total')::integer<>1 then
    raise exception 'El catálogo no separó correctamente insumos activos e inactivos.';
  end if;

  insert into public.culinary_recipes(id,company_id,product_id,recipe_kind)
  values(recipe_id,c,dish,'dish');
  insert into public.culinary_recipe_versions(id,recipe_id,version_number,status,yield_quantity,yield_unit_code,portion_count,waste_percent,valid_from,activated_at,activated_by)
  values(version_id,recipe_id,1,'active',1,'piece',1,0,now(),now(),u);
  insert into public.culinary_recipe_components(recipe_version_id,component_product_id,entered_quantity,entered_unit_code,normalized_quantity,base_unit_code)
  values(version_id,recipe_ingredient,1,'g',1,'g');
  begin
    perform public.archive_restaurant_ingredient(c,recipe_ingredient,'Intento de archivo con receta','81800002-0000-4000-8000-000000000011');
  exception when others then
    blocked:=position('receta activa' in lower(sqlerrm))>0;
  end;
  if not blocked or not (select is_active from public.products where id=recipe_ingredient) then
    raise exception 'El archivo no bloqueó la receta activa.';
  end if;

  insert into public.locations(id,company_id,external_code,name,location_type)
  values(location_id,c,'ALM-ARCH','Almacén de archivo','almacen_operativo');
  insert into public.inventory_balances(company_id,location_id,product_id,quantity_on_hand)
  values(c,location_id,stocked_ingredient,10);
  blocked:=false;
  begin
    perform public.archive_restaurant_ingredient(c,stocked_ingredient,'Intento de archivo con existencias','81800002-0000-4000-8000-000000000012');
  exception when others then
    blocked:=position('existencias' in lower(sqlerrm))>0;
  end;
  if not blocked or not (select is_active from public.products where id=stocked_ingredient) then
    raise exception 'El archivo no bloqueó las existencias.';
  end if;
end $$;

rollback;
