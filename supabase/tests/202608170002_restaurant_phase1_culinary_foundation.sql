begin;

do $$
declare
 c uuid:='81700002-0000-4000-8000-000000000001';
 u uuid:='81700002-0000-4000-8000-000000000002';
 dish uuid:='81700002-0000-4000-8000-000000000003';
 ingredient uuid:='81700002-0000-4000-8000-000000000004';
 recipe uuid:='81700002-0000-4000-8000-000000000005';
 version uuid:='81700002-0000-4000-8000-000000000006';
 result jsonb;blocked boolean:=false;
begin
 insert into public.companies(id,legal_name,display_name,product_experience_code) values(c,'Restaurante Fase 1','Restaurante Fase 1','restaurant');
 insert into auth.users(id,aud,role,email,encrypted_password) values(u,'authenticated','authenticated','restaurant-phase1@example.invalid','');
 insert into public.user_roles(user_id,role_id,company_id) select u,id,c from public.roles where code='direccion_admin';
 perform set_config('request.jwt.claim.role','authenticated',true);
 perform set_config('request.jwt.claim.sub',u::text,true);

 insert into public.products(id,company_id,alpha_sku,internal_sku,name,unit,is_inventory_tracked) values
  (dish,c,'DISH-1','DISH-1','Platillo de prueba','PZA',false),
  (ingredient,c,'ING-1','ING-1','Ingrediente de prueba','g',true);

 if public.normalize_culinary_quantity(1,'kg','g')<>1000 then raise exception '1 kg no normalizó a 1000 g.';end if;
 begin
  perform public.normalize_culinary_quantity(1,'kg','ml');
 exception when others then blocked:=position('incompatibles' in lower(sqlerrm))>0;end;
 if not blocked then raise exception 'La conversión masa-volumen no fue rechazada.';end if;

 insert into public.culinary_recipes(id,company_id,product_id,recipe_kind) values(recipe,c,dish,'dish');
 insert into public.culinary_recipe_versions(id,recipe_id,version_number,yield_quantity,yield_unit_code,portion_count,waste_percent)
 values(version,recipe,1,1,'piece',2,10);
 insert into public.culinary_recipe_components(recipe_version_id,component_product_id,entered_quantity,entered_unit_code,normalized_quantity,base_unit_code)
 values(version,ingredient,0.5,'kg',1,'g');
 if (select normalized_quantity from public.culinary_recipe_components where recipe_version_id=version)<>500 then raise exception 'El trigger no normalizó el componente.';end if;

 result:=public.activate_culinary_recipe_version(version);
 if result->>'status'<>'active' or coalesce((result->>'idempotent')::boolean,true) then raise exception 'No se activó la receta: %',result;end if;
 result:=public.culinary_recipe_readiness(c,dish,now());
 if result->>'allowed'<>'false' or result#>>'{blockers,0,code}'<>'missing_component_cost' then raise exception 'Readiness no detectó costo faltante: %',result;end if;

 insert into public.product_costs(company_id,product_id,cost_type,amount,currency_code,valid_from,created_by)
 values(c,ingredient,'replacement_cost',0.02,'MXN',now()-interval '1 minute',u);
 result:=public.culinary_recipe_readiness(c,dish,now());
 if result->>'allowed'<>'true' or result->>'recipe_version_id'<>version::text then raise exception 'Readiness no habilitó la receta completa: %',result;end if;
end $$;

rollback;
