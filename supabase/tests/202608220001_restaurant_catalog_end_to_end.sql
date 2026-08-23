begin;

do $$
declare
  c uuid := '82200001-0000-4000-8000-000000000001';
  u uuid := '82200001-0000-4000-8000-000000000002';
  tax uuid := '82200001-0000-4000-8000-000000000003';
  ingredient uuid;
  base uuid;
  dish uuid;
  saved jsonb;
  draft jsonb;
  result jsonb;
  component_options jsonb;
  batch_rows jsonb;
begin
  insert into public.companies(id,legal_name,display_name,product_experience_code)
  values(c,'Catálogo Restaurante E2E','Catálogo Restaurante E2E','restaurant');
  insert into auth.users(id,aud,role,email,encrypted_password)
  values(u,'authenticated','authenticated','restaurant-e2e@example.invalid','');
  insert into public.user_roles(user_id,role_id,company_id)
  select u,id,c from public.roles where code='direccion_admin';
  insert into public.tax_categories(id,company_id,code,name) values(tax,c,'IVA16','IVA 16%');
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',u::text,true);

  saved:=public.save_restaurant_catalog_item(c,null,'ING-E2E','Jitomate E2E',null,'g','Verduras','ingredient',true,true,tax,'KG',1000,false,'Prueba E2E',null,'82200001-0000-4000-8000-000000000010');
  ingredient:=(saved->>'id')::uuid;
  if exists(select 1 from public.products where id=ingredient and (is_sellable or tax_category_id is not null)) then
    raise exception 'Un insumo conservó campos comerciales exclusivos del platillo.';
  end if;

  saved:=public.save_restaurant_catalog_item(c,null,'BASE-E2E','Salsa roja E2E',null,'ml','Salsas','preparation',true,true,tax,null,null,false,'Prueba E2E',null,'82200001-0000-4000-8000-000000000011');
  base:=(saved->>'id')::uuid;
  if exists(select 1 from public.products where id=base and (is_sellable or tax_category_id is not null)) then
    raise exception 'Una base conservó campos comerciales exclusivos del platillo.';
  end if;

  saved:=public.save_restaurant_catalog_item(c,null,'DISH-E2E','Pipián E2E',null,'piece','Platos fuertes','dish',true,true,tax,null,null,false,'Prueba E2E',null,'82200001-0000-4000-8000-000000000012');
  dish:=(saved->>'id')::uuid;
  if not exists(select 1 from public.products where id=dish and is_sellable and tax_category_id=tax) then
    raise exception 'El platillo no conservó su configuración comercial.';
  end if;

  component_options:=public.search_restaurant_recipe_components(c,'E2E',1,50);
  if exists(select 1 from jsonb_array_elements(component_options->'items') item where item->>'id' in (base::text,dish::text)) then
    raise exception 'El buscador ofreció un platillo o una base sin receta activa: %',component_options;
  end if;

  draft:=public.save_culinary_recipe_draft(c,base,'preparation',1000,'ml',1,0,
    jsonb_build_array(jsonb_build_object('product_id',ingredient,'quantity',500,'unit_code','g','base_unit_code','g','sort_order',0)),
    '82200001-0000-4000-8000-000000000013',null);
  if (select unit from public.products where id=base)<>'ml' then raise exception 'La base no tomó la unidad de su rendimiento.'; end if;
  perform public.activate_culinary_recipe_version((draft->>'version_id')::uuid,'draft');
  component_options:=public.search_restaurant_recipe_components(c,'E2E',1,50);
  if not exists(select 1 from jsonb_array_elements(component_options->'items') item where item->>'id'=base::text and item->>'recipe_kind'='preparation') then
    raise exception 'La base activa no apareció como componente reutilizable: %',component_options;
  end if;

  begin
    perform public.save_culinary_recipe_draft(c,dish,'dish',1,'piece',1,0,
      jsonb_build_array(jsonb_build_object('product_id',dish,'quantity',1,'unit_code','piece','base_unit_code','piece','sort_order',0)),
      '82200001-0000-4000-8000-000000000014',null);
    raise exception 'Se aceptó un platillo como componente.';
  exception when others then
    if sqlerrm='Se aceptó un platillo como componente.' then raise; end if;
  end;

  begin
    update public.products set is_sellable=true where id=base;
    raise exception 'El trigger permitió vender una base.';
  exception when others then
    if sqlerrm='El trigger permitió vender una base.' then raise; end if;
  end;

  batch_rows:=jsonb_build_array(
    jsonb_build_object('internal_sku','ING-LOTE-1','name','Cebolla lote','unit','g','product_group','Verduras','is_active',true,'purchase_unit_code','KG','base_units_per_purchase_unit',1000),
    jsonb_build_object('internal_sku','ING-LOTE-2','name','Chile lote','unit','g','product_group','Chiles','is_active',true,'purchase_unit_code','KG','base_units_per_purchase_unit',1000)
  );
  result:=public.import_restaurant_catalog_batch(c,'ingredient',batch_rows,'Carga de prueba','82200001-0000-4000-8000-000000000015');
  if (result->>'processed')::integer<>2 then raise exception 'La carga no procesó las dos filas.'; end if;
  result:=public.import_restaurant_catalog_batch(c,'ingredient',batch_rows,'Carga de prueba','82200001-0000-4000-8000-000000000015');
  if not (result->>'idempotent')::boolean then raise exception 'La carga no fue idempotente.'; end if;
  if (select count(*) from public.products where company_id=c and internal_sku like 'ING-LOTE-%')<>2 then raise exception 'La carga idempotente duplicó registros.'; end if;
end $$;

rollback;
