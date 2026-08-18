-- Restaurante fase 1 · readiness culinario integrado sin cambiar el contrato core.

create or replace function public.culinary_pos_readiness(p_company_id uuid,p_location_id uuid,p_product_id uuid,p_quantity numeric default 1,p_at timestamptz default now(),p_currency_code text default 'MXN')
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_cost jsonb;v_missing jsonb;v_conversion_missing jsonb;v_version uuid;
begin
 if p_quantity is null or p_quantity<=0 then raise exception 'La cantidad debe ser mayor que cero.';end if;
 select rv.id into v_version from public.culinary_recipes r join public.culinary_recipe_versions rv on rv.recipe_id=r.id where r.company_id=p_company_id and r.product_id=p_product_id and rv.status='active'and rv.valid_from<=p_at and(rv.valid_to is null or rv.valid_to>p_at);
 if v_version is null then return jsonb_build_object('allowed',false,'blockers',jsonb_build_array(jsonb_build_object('code','missing_active_recipe','message','Agrega y activa una receta.')));end if;
 begin v_cost:=public.culinary_version_cost(v_version,p_quantity,p_at,p_currency_code);exception when others then return jsonb_build_object('allowed',false,'recipe_version_id',v_version,'blockers',jsonb_build_array(jsonb_build_object('code','invalid_recipe_conversion','message',sqlerrm)));end;
 if not coalesce((v_cost->>'allowed')::boolean,false)then return v_cost||jsonb_build_object('recipe_version_id',v_version);end if;
 with needed as(select*from public.expand_culinary_recipe(v_version,p_quantity))
 select jsonb_agg(jsonb_build_object('product_id',p.id,'product_name',p.name)order by p.name)into v_conversion_missing from needed n join public.products p on p.id=n.ingredient_product_id left join public.product_purchase_units u on u.product_id=p.id where p.is_inventory_tracked and(p.base_unit_id is null or u.product_id is null or u.base_units_per_purchase_unit<=0);
 if v_conversion_missing is not null then return v_cost||jsonb_build_object('allowed',false,'recipe_version_id',v_version,'blockers',jsonb_build_array(jsonb_build_object('code','missing_purchase_conversion','message','Configura la unidad de compra y su equivalencia para los ingredientes indicados.','ingredients',v_conversion_missing)));end if;
 with needed as(select * from public.expand_culinary_recipe(v_version,p_quantity)),short as(
  select n.ingredient_product_id,p.name,n.quantity,coalesce(b.quantity_on_hand,0) available
  from needed n join public.products p on p.id=n.ingredient_product_id left join public.inventory_balances b on b.company_id=p_company_id and b.location_id=p_location_id and b.product_id=n.ingredient_product_id where coalesce(b.quantity_on_hand,0)<n.quantity)
 select jsonb_agg(jsonb_build_object('product_id',ingredient_product_id,'product_name',name,'required',quantity,'available',available)order by name)into v_missing from short;
 if v_missing is not null then return v_cost||jsonb_build_object('allowed',false,'recipe_version_id',v_version,'blockers',jsonb_build_array(jsonb_build_object('code','insufficient_ingredient_stock','message','Completa la existencia de los ingredientes indicados.','ingredients',v_missing)));end if;
 return v_cost||jsonb_build_object('allowed',true,'recipe_version_id',v_version,'blockers','[]'::jsonb);
end$$;

alter function public.validate_pos_product_for_location(uuid,uuid,uuid,timestamptz)rename to validate_pos_product_for_location_before_culinary;
revoke all on function public.validate_pos_product_for_location_before_culinary(uuid,uuid,uuid,timestamptz)from public,anon,authenticated;

create function public.validate_pos_product_for_location(p_company_id uuid,p_location_id uuid,p_product_id uuid,p_at timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_core jsonb;v_experience text;v_product public.products%rowtype;v_culinary jsonb;v_currency text;
begin
 v_core:=public.validate_pos_product_for_location_before_culinary(p_company_id,p_location_id,p_product_id,p_at);
 select product_experience_code,base_currency_code into v_experience,v_currency from public.companies where id=p_company_id;
 select * into v_product from public.products where id=p_product_id and company_id=p_company_id;
 if v_experience<>'restaurant'or not v_product.is_sellable or v_product.is_inventory_tracked then return v_core;end if;
 v_culinary:=public.culinary_pos_readiness(p_company_id,p_location_id,p_product_id,1,p_at,coalesce(v_currency,'MXN'));
 return v_core||jsonb_build_object('allowed',coalesce((v_core->>'allowed')::boolean,false)and coalesce((v_culinary->>'allowed')::boolean,false),'culinary_readiness',v_culinary);
end$$;

revoke all on function public.culinary_pos_readiness(uuid,uuid,uuid,numeric,timestamptz,text),public.validate_pos_product_for_location(uuid,uuid,uuid,timestamptz)from public,anon;
grant execute on function public.culinary_pos_readiness(uuid,uuid,uuid,numeric,timestamptz,text),public.validate_pos_product_for_location(uuid,uuid,uuid,timestamptz)to authenticated;
