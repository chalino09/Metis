begin;
do $$
declare c uuid:='81700016-0000-4000-8000-000000000001';u uuid:='81700016-0000-4000-8000-000000000002';dish uuid:='81700016-0000-4000-8000-000000000003';ingredient uuid:='81700016-0000-4000-8000-000000000004';prep uuid:='81700016-0000-4000-8000-000000000005';pending uuid:='81700016-0000-4000-8000-000000000006';v uuid;result jsonb;
begin
 insert into public.companies(id,legal_name,display_name,product_experience_code) values(c,'Catálogo culinario','Catálogo culinario','restaurant');
 insert into auth.users(id,aud,role,email,encrypted_password) values(u,'authenticated','authenticated','catalog-roles@example.invalid','');
 insert into public.user_roles(user_id,role_id,company_id) select u,id,c from public.roles where code='direccion_admin';
 perform set_config('request.jwt.claim.role','authenticated',true); perform set_config('request.jwt.claim.sub',u::text,true);
 insert into public.products(id,company_id,internal_sku,name,unit,is_inventory_tracked,is_active,is_sellable)
 values(dish,c,'DISH','Enchiladas','piece',false,true,true),(ingredient,c,'ING','Tortilla','g',true,true,false),(prep,c,'PREP','Salsa verde','g',true,true,false),(pending,c,'PENDING','Platillo pendiente','piece',false,true,true);
 insert into public.product_culinary_roles(company_id,product_id,role,assigned_by,reason)
 values(c,dish,'dish',u,'Prueba de catálogo'),(c,ingredient,'ingredient',u,'Prueba de catálogo'),(c,prep,'preparation',u,'Prueba de catálogo'),(c,pending,'dish',u,'Prueba de catálogo');
 insert into public.culinary_recipes(company_id,product_id,recipe_kind) values(c,dish,'dish'),(c,prep,'preparation');
 result:=public.search_restaurant_catalog(c,'dish',null,1,50,null);
 if (result->>'total')::int<>2 or result#>>'{items,0,name}'<>'Enchiladas' then raise exception 'La vista de platillos mezcló insumos: %',result; end if;
 result:=public.search_restaurant_catalog(c,'ingredient',null,1,50,null);
 if (result->>'total')::int<>1 then raise exception 'La vista de insumos no separó el catálogo: %',result; end if;
 result:=public.search_restaurant_catalog(c,'preparation',null,1,50,null);
 if (result->>'total')::int<>1 then raise exception 'La vista de bases no separó el catálogo: %',result; end if;
 result:=public.search_restaurant_recipe_components(c,'Tortilla',1,20);
 if (result->>'total')::int<>1 then raise exception 'La búsqueda de receta no encontró el insumo: %',result; end if;
 result:=public.search_restaurant_recipe_components(c,'Salsa',1,20);
 if (result->>'total')::int<>0 then raise exception 'La búsqueda ofreció una base sin receta activa: %',result; end if;
end $$;
rollback;
