begin;

do $$
declare
  c uuid := '82300001-0000-4000-8000-000000000001';
  u uuid := '82300001-0000-4000-8000-000000000002';
  ingredient uuid;
  base uuid;
  dish uuid;
  saved jsonb;
  draft jsonb;
  catalog jsonb;
  batch_rows jsonb;
begin
  insert into public.companies(id,legal_name,display_name,product_experience_code)
  values(c,'Rendimiento y duplicados','Rendimiento y duplicados','restaurant');
  insert into auth.users(id,aud,role,email,encrypted_password)
  values(u,'authenticated','authenticated','restaurant-yield-duplicate@example.invalid','');
  insert into public.user_roles(user_id,role_id,company_id)
  select u,id,c from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',u::text,true);

  saved:=public.save_restaurant_catalog_item(c,null,'ING-YIELD','Aceite de prueba',null,'ml','Abarrotes y secos','ingredient',false,true,null,'BOTELLA',1000,false,'Alta de prueba',null,'82300001-0000-4000-8000-000000000010');
  ingredient:=(saved->>'id')::uuid;
  saved:=public.save_restaurant_catalog_item(c,null,'BASE-YIELD','Salsa roja de prueba',null,'ml','Salsas','preparation',false,true,null,null,null,false,'Alta de prueba',null,'82300001-0000-4000-8000-000000000011');
  base:=(saved->>'id')::uuid;
  saved:=public.save_restaurant_catalog_item(c,null,'DISH-YIELD','Enchiladas de prueba',null,'piece','Platos fuertes','dish',true,true,null,null,null,false,'Alta de prueba',null,'82300001-0000-4000-8000-000000000012');
  dish:=(saved->>'id')::uuid;

  begin
    perform public.save_restaurant_catalog_item(c,null,'ING-YIELD-DUP','  ACEITE   DE  PRUEBA  ',null,'ml','Abarrotes y secos','ingredient',false,true,null,'BOTELLA',1000,false,'Duplicado de prueba',null,'82300001-0000-4000-8000-000000000013');
    raise exception 'Se permitió crear un insumo duplicado por nombre.';
  exception when others then
    if sqlerrm='Se permitió crear un insumo duplicado por nombre.' then raise; end if;
    if position('Ya existe el registro' in sqlerrm)=0 then raise; end if;
  end;
  if (select count(*) from public.products where company_id=c and lower(name)='aceite de prueba')<>1 then raise exception 'La protección de duplicados alteró la identidad canónica.'; end if;

  batch_rows:=jsonb_build_array(
    jsonb_build_object('internal_sku','ING-NEW-ROLLBACK','name','Cebolla de prueba','unit','g','product_group','Frutas y verduras','is_active',true,'purchase_unit_code','KG','base_units_per_purchase_unit',1000),
    jsonb_build_object('internal_sku','ING-EXISTING-ROLLBACK','name','aceite de prueba','unit','ml','product_group','Abarrotes y secos','is_active',true,'purchase_unit_code','BOTELLA','base_units_per_purchase_unit',1000)
  );
  begin
    perform public.import_restaurant_catalog_batch(c,'ingredient',batch_rows,'Lote con duplicado','82300001-0000-4000-8000-000000000014');
    raise exception 'Se permitió importar un lote con duplicados.';
  exception when others then
    if sqlerrm='Se permitió importar un lote con duplicados.' then raise; end if;
    if position('Ya existe el registro' in sqlerrm)=0 then raise; end if;
  end;
  if exists(select 1 from public.products where company_id=c and internal_sku='ING-NEW-ROLLBACK') then raise exception 'El lote con duplicado dejó una carga parcial.'; end if;

  draft:=public.save_culinary_recipe_draft(c,base,'preparation',2000,'ml',20,0,jsonb_build_array(jsonb_build_object('product_id',ingredient,'quantity',500,'unit_code','ml','base_unit_code','ml','sort_order',0)),'82300001-0000-4000-8000-000000000015',null);
  if (draft->>'portion_count')::numeric<>20 then raise exception 'No se guardó el rendimiento de 20 platillos.'; end if;
  if (select portion_count from public.culinary_recipe_versions where id=(draft->>'version_id')::uuid)<>20 then raise exception 'La versión no conserva el rendimiento por platillos.'; end if;
  perform public.activate_culinary_recipe_version((draft->>'version_id')::uuid,'draft');
  catalog:=public.search_restaurant_catalog(c,'preparation','Salsa roja de prueba',1,10,null);
  if (catalog->'items'->0->>'recipe_portion_count')::numeric<>20 then raise exception 'El catálogo no expuso el rendimiento por platillos.'; end if;

  begin
    perform public.save_culinary_recipe_draft(c,base,'preparation',2000,'ml',2.5,0,jsonb_build_array(jsonb_build_object('product_id',ingredient,'quantity',500,'unit_code','ml','base_unit_code','ml','sort_order',0)),'82300001-0000-4000-8000-000000000016',null);
    raise exception 'Se permitió una cantidad fraccionaria de platillos.';
  exception when others then
    if sqlerrm='Se permitió una cantidad fraccionaria de platillos.' then raise; end if;
    if position('número entero' in sqlerrm)=0 then raise; end if;
  end;
  begin
    perform public.save_culinary_recipe_draft(c,dish,'dish',1,'piece',2,0,jsonb_build_array(jsonb_build_object('product_id',ingredient,'quantity',1,'unit_code','ml','base_unit_code','ml','sort_order',0)),'82300001-0000-4000-8000-000000000017',null);
    raise exception 'Se permitió que un platillo dejara de representar una porción.';
  exception when others then
    if sqlerrm='Se permitió que un platillo dejara de representar una porción.' then raise; end if;
    if position('exactamente una porción' in sqlerrm)=0 then raise; end if;
  end;
end $$;

rollback;
