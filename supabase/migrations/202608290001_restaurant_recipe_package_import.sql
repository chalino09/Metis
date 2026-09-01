-- Restaurante · importación única y transaccional de insumos y recetas.
-- Volumen esperado: hasta 100 insumos y 100 recetas por paquete.

begin;

create table if not exists public.restaurant_recipe_import_requests(
  company_id uuid not null references public.companies(id) on delete cascade,
  client_request_id uuid not null,
  result jsonb not null,
  created_at timestamptz not null default now(),
  primary key(company_id,client_request_id)
);

alter table public.restaurant_recipe_import_requests enable row level security;
revoke all on public.restaurant_recipe_import_requests from public,anon,authenticated;

create or replace function public.import_restaurant_recipe_package(
  p_company_id uuid,p_ingredients jsonb,p_recipes jsonb,p_reason text,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare
  v_existing_result jsonb;v_ingredient record;v_recipe record;v_component record;
  v_product_id uuid;v_product_result jsonb;v_product_role text;v_component_product_id uuid;
  v_product_map jsonb:='{}'::jsonb;v_recipe_results jsonb:='[]'::jsonb;
  v_created_ingredients integer:=0;v_reused_ingredients integer:=0;v_recipe_count integer:=0;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_products') or not public.has_company_permission(p_company_id,'manage_recipes') then
    raise exception 'No autorizado para importar insumos y recetas.';
  end if;
  if not exists(select 1 from public.companies where id=p_company_id and product_experience_code='restaurant') then raise exception 'Esta importación sólo está disponible en Restaurante.';end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null or p_client_request_id is null then raise exception 'Indica el motivo y la llave de la importación.';end if;
  select result into v_existing_result from public.restaurant_recipe_import_requests where company_id=p_company_id and client_request_id=p_client_request_id;
  if found then return v_existing_result||jsonb_build_object('idempotent',true);end if;
  if jsonb_typeof(coalesce(p_ingredients,'[]'))<>'array' or jsonb_array_length(p_ingredients) not between 1 and 100 then raise exception 'El paquete debe contener entre 1 y 100 insumos.';end if;
  if jsonb_typeof(coalesce(p_recipes,'[]'))<>'array' or jsonb_array_length(p_recipes) not between 1 and 100 then raise exception 'El paquete debe contener entre 1 y 100 recetas.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||':restaurant-recipe-import',0));

  for v_ingredient in select * from jsonb_to_recordset(p_ingredients) as x(canonical_key text,canonical_name text,existing_product_id uuid,base_unit_code text,purchase_unit_code text,base_units_per_purchase_unit numeric) loop
    if nullif(trim(coalesce(v_ingredient.canonical_key,'')),'') is null or nullif(trim(coalesce(v_ingredient.canonical_name,'')),'') is null then raise exception 'Hay un insumo sin identidad canónica.';end if;
    if v_product_map ? v_ingredient.canonical_key then raise exception 'El insumo % está repetido en el paquete.',v_ingredient.canonical_name;end if;
    if v_ingredient.existing_product_id is not null then
      select role into v_product_role from public.product_culinary_roles where company_id=p_company_id and product_id=v_ingredient.existing_product_id;
      if v_product_role is distinct from 'ingredient' or not exists(select 1 from public.products where company_id=p_company_id and id=v_ingredient.existing_product_id and is_active) then raise exception 'El insumo existente % ya no está disponible.',v_ingredient.canonical_name;end if;
      v_product_id:=v_ingredient.existing_product_id;v_reused_ingredients:=v_reused_ingredients+1;
    else
      select product.id into v_product_id from public.products product where product.company_id=p_company_id and lower(regexp_replace(trim(product.name),'\s+',' ','g'))=lower(regexp_replace(trim(v_ingredient.canonical_name),'\s+',' ','g')) limit 1;
      if v_product_id is not null then
        select role into v_product_role from public.product_culinary_roles where company_id=p_company_id and product_id=v_product_id;
        if v_product_role is distinct from 'ingredient' then raise exception 'Ya existe % con otra función culinaria.',v_ingredient.canonical_name;end if;
        v_reused_ingredients:=v_reused_ingredients+1;
      else
        v_product_result:=public.save_restaurant_catalog_item(p_company_id,null,null,v_ingredient.canonical_name,null,v_ingredient.base_unit_code,'Otros insumos','ingredient',false,true,null,v_ingredient.purchase_unit_code,v_ingredient.base_units_per_purchase_unit,false,p_reason,null,gen_random_uuid());
        v_product_id:=(v_product_result->>'id')::uuid;v_created_ingredients:=v_created_ingredients+1;
      end if;
    end if;
    v_product_map:=v_product_map||jsonb_build_object(v_ingredient.canonical_key,v_product_id);
  end loop;

  for v_recipe in select * from jsonb_to_recordset(p_recipes) as x(name text,recipe_kind text,yield_quantity numeric,yield_unit_code text,components jsonb) loop
    if v_recipe.recipe_kind not in('dish','preparation') or nullif(trim(coalesce(v_recipe.name,'')),'') is null then raise exception 'Hay una receta con identidad inválida.';end if;
    select product.id,role_data.role into v_product_id,v_product_role from public.products product left join public.product_culinary_roles role_data on role_data.company_id=product.company_id and role_data.product_id=product.id where product.company_id=p_company_id and lower(regexp_replace(trim(product.name),'\s+',' ','g'))=lower(regexp_replace(trim(v_recipe.name),'\s+',' ','g')) limit 1;
    if v_product_id is not null and v_product_role is distinct from v_recipe.recipe_kind then raise exception 'Ya existe % con otra función culinaria.',v_recipe.name;end if;
    if v_product_id is null then
      v_product_result:=public.save_restaurant_catalog_item(p_company_id,null,null,v_recipe.name,null,case when v_recipe.recipe_kind='dish' then 'piece' else v_recipe.yield_unit_code end,case when v_recipe.recipe_kind='dish' then 'Platos fuertes' else 'Salsas' end,v_recipe.recipe_kind,false,true,null,null,null,false,p_reason,null,gen_random_uuid());
      v_product_id:=(v_product_result->>'id')::uuid;
    end if;
    declare v_components jsonb:='[]'::jsonb;begin
      for v_component in select * from jsonb_to_recordset(v_recipe.components) as x(canonical_key text,quantity numeric,base_unit_code text,sort_order integer,notes text) loop
        v_component_product_id:=(v_product_map->>v_component.canonical_key)::uuid;
        if v_component_product_id is null or v_component.quantity<=0 then raise exception 'La receta % contiene un componente inválido.',v_recipe.name;end if;
        v_components:=v_components||jsonb_build_array(jsonb_build_object('product_id',v_component_product_id,'quantity',v_component.quantity,'unit_code',v_component.base_unit_code,'base_unit_code',v_component.base_unit_code,'sort_order',v_component.sort_order,'notes',v_component.notes));
      end loop;
      v_recipe_results:=v_recipe_results||jsonb_build_array(public.save_culinary_recipe_draft(p_company_id,v_product_id,v_recipe.recipe_kind,v_recipe.yield_quantity,v_recipe.yield_unit_code,1,0,v_components,gen_random_uuid(),null));
    end;
    v_recipe_count:=v_recipe_count+1;
  end loop;

  v_existing_result:=jsonb_build_object('created_ingredients',v_created_ingredients,'reused_ingredients',v_reused_ingredients,'recipes',v_recipe_count,'recipe_results',v_recipe_results,'idempotent',false);
  insert into public.restaurant_recipe_import_requests(company_id,client_request_id,result) values(p_company_id,p_client_request_id,v_existing_result);
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata) values(p_company_id,auth.uid(),'restaurant.recipe_package_imported','culinary_recipe_batch',jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'created_ingredients',v_created_ingredients,'reused_ingredients',v_reused_ingredients,'recipes',v_recipe_count));
  return v_existing_result;
end $$;

revoke all on function public.import_restaurant_recipe_package(uuid,jsonb,jsonb,text,uuid) from public,anon;
grant execute on function public.import_restaurant_recipe_package(uuid,jsonb,jsonb,text,uuid) to authenticated;

notify pgrst,'reload schema';
commit;
