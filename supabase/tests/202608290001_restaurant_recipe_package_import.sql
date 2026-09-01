begin;

do $$
declare
  c uuid:='82900001-0000-4000-8000-000000000001';u uuid:='82900001-0000-4000-8000-000000000002';existing uuid;result jsonb;ingredients jsonb;recipes jsonb;
begin
  insert into public.companies(id,legal_name,display_name,product_experience_code)values(c,'Importación recetas','Importación recetas','restaurant');
  insert into auth.users(id,aud,role,email,encrypted_password)values(u,'authenticated','authenticated','recipe-package@example.invalid','');
  insert into public.user_roles(user_id,role_id,company_id)select u,id,c from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);
  existing:=(public.save_restaurant_catalog_item(c,null,null,'Aceite',null,'l','Abarrotes','ingredient',false,true,null,'L',1,false,'Prueba',null,'82900001-0000-4000-8000-000000000010')->>'id')::uuid;
  ingredients:=jsonb_build_array(
    jsonb_build_object('canonical_key','ACEITE','canonical_name','Aceite','existing_product_id',existing,'base_unit_code','ml','purchase_unit_code','L','base_units_per_purchase_unit',1000),
    jsonb_build_object('canonical_key','JITOMATE','canonical_name','Jitomate importado','existing_product_id',null,'base_unit_code','g','purchase_unit_code','KG','base_units_per_purchase_unit',1000)
  );
  recipes:=jsonb_build_array(jsonb_build_object('name','Platillo importado','recipe_kind','dish','yield_quantity',1,'yield_unit_code','piece','components',jsonb_build_array(
    jsonb_build_object('canonical_key','ACEITE','quantity',10,'base_unit_code','ml','sort_order',0),jsonb_build_object('canonical_key','JITOMATE','quantity',100,'base_unit_code','g','sort_order',1)
  )));
  result:=public.import_restaurant_recipe_package(c,ingredients,recipes,'Prueba transaccional','82900001-0000-4000-8000-000000000020');
  if (result->>'created_ingredients')::integer<>1 or (result->>'reused_ingredients')::integer<>1 or (result->>'recipes')::integer<>1 then raise exception 'Resultado inesperado: %',result;end if;
  if (select count(*) from public.products where company_id=c and lower(name)='aceite')<>1 then raise exception 'Se duplicó Aceite.';end if;
  if not exists(select 1 from public.culinary_recipe_versions version join public.culinary_recipes recipe on recipe.id=version.recipe_id join public.products product on product.id=recipe.product_id where product.company_id=c and product.name='Platillo importado' and version.status='draft' and version.portion_count=1) then raise exception 'No se creó el borrador por porción.';end if;
  if not exists(select 1 from public.culinary_recipe_components component where component.component_product_id=existing and component.entered_quantity=.01 and component.base_unit_code='l') then raise exception 'No se convirtió ml a la unidad base histórica l.';end if;
  result:=public.import_restaurant_recipe_package(c,ingredients,recipes,'Prueba transaccional','82900001-0000-4000-8000-000000000020');
  if not (result->>'idempotent')::boolean then raise exception 'La repetición no fue idempotente.';end if;
  if (select count(*) from public.products where company_id=c and name in('Jitomate importado','Platillo importado'))<>2 then raise exception 'La repetición duplicó registros.';end if;
end $$;

rollback;
