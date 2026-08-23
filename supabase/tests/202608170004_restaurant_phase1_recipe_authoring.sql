begin;
do $$
declare c uuid:='81700004-0000-4000-8000-000000000001';u uuid:='81700004-0000-4000-8000-000000000002';dish uuid:='81700004-0000-4000-8000-000000000003';ingredient uuid:='81700004-0000-4000-8000-000000000004';request_id uuid:='81700004-0000-4000-8000-000000000005';result jsonb;context jsonb;version_id uuid;
begin
 insert into public.companies(id,legal_name,display_name,product_experience_code)values(c,'Autoría Restaurante','Autoría Restaurante','restaurant');
 insert into auth.users(id,aud,role,email,encrypted_password)values(u,'authenticated','authenticated','recipe-authoring@example.invalid','');
 insert into public.user_roles(user_id,role_id,company_id)select u,id,c from public.roles where code='direccion_admin';
 perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);
 insert into public.products(id,company_id,alpha_sku,internal_sku,name,unit,is_inventory_tracked)values(dish,c,'DISH','DISH','Platillo','PZA',false),(ingredient,c,'ING','ING','Ingrediente','g',true);
 insert into public.product_culinary_roles(company_id,product_id,role,assigned_by,reason)
 values(c,dish,'dish',u,'Prueba de autoría'),(c,ingredient,'ingredient',u,'Prueba de autoría');
 insert into public.product_costs(company_id,product_id,cost_type,amount,currency_code,valid_from,created_by)values(c,ingredient,'replacement_cost',0.2,'MXN',now()-interval'1 minute',u);
 result:=public.save_culinary_recipe_draft(c,dish,'dish',1,'piece',1,0,jsonb_build_array(jsonb_build_object('product_id',ingredient,'quantity',50,'unit_code','g','base_unit_code','g','sort_order',0)),request_id,null);
 version_id:=(result->>'version_id')::uuid;
 if result->>'status'<>'draft' or (select count(*)from public.culinary_recipe_components where recipe_version_id=version_id)<>1 then raise exception 'No se guardó el borrador completo: %',result;end if;
 result:=public.save_culinary_recipe_draft(c,dish,'dish',1,'piece',1,0,jsonb_build_array(jsonb_build_object('product_id',ingredient,'quantity',50,'unit_code','g','base_unit_code','g','sort_order',0)),request_id,null);
 if result->>'idempotent'<>'true' then raise exception 'El reintento no fue idempotente.';end if;
 context:=public.get_culinary_recipe_context(c,dish);
 if context#>>'{draft,cost,total_cost}'<>'10.000000' or context#>>'{draft,cost,cost_per_portion}'<>'10.000000' then raise exception 'El contexto no calculó costo y porción: %',context;end if;
 perform public.activate_culinary_recipe_version(version_id);
 context:=public.get_culinary_recipe_context(c,dish);
 if context#>>'{active,status}'<>'active' or context->'draft' is distinct from 'null'::jsonb then raise exception 'La activación no actualizó el contexto: %',context;end if;
 if (public.search_culinary_components(c,'Ingrediente',1,20)->>'total')::integer<>1 then raise exception 'La búsqueda paginada no encontró el ingrediente.';end if;
end$$;
rollback;
