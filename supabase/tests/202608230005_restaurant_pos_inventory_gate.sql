begin;
do $$
declare
  c uuid:='82300005-0000-4000-8000-000000000001';
  u uuid:='82300005-0000-4000-8000-000000000002';
  loc uuid:='82300005-0000-4000-8000-000000000003';
  reg uuid:='82300005-0000-4000-8000-000000000004';
  session_id uuid:='82300005-0000-4000-8000-000000000005';
  piece_id uuid:='82300005-0000-4000-8000-000000000006';
  ingredient uuid:='82300005-0000-4000-8000-000000000007';
  dish uuid:='82300005-0000-4000-8000-000000000008';
  recipe uuid:='82300005-0000-4000-8000-000000000009';
  version_id uuid:='82300005-0000-4000-8000-000000000010';
  sale_id uuid:='82300005-0000-4000-8000-000000000011';
  item_id uuid:='82300005-0000-4000-8000-000000000012';
  readiness jsonb;balance numeric;
begin
  insert into public.companies(id,legal_name,display_name,product_experience_code)values(c,'Restaurante POS inventario','Restaurante POS inventario','restaurant');
  insert into auth.users(id,aud,role,email,encrypted_password)values(u,'authenticated','authenticated','restaurant-pos-inventory@example.invalid','');
  insert into public.user_roles(user_id,role_id,company_id)select u,id,c from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);
  insert into public.locations(id,company_id,external_code,name)values(loc,c,'COCINA','Cocina');
  insert into public.cash_registers(id,company_id,location_id,code,display_name)values(reg,c,loc,'CAJA','Caja');
  insert into public.cash_sessions(id,company_id,cash_register_id,location_id,opened_by)values(session_id,c,reg,loc,u);
  insert into public.units_of_measure(id,company_id,code,name,source)values(piece_id,c,'piece','Pieza','manual');
  insert into public.products(id,company_id,alpha_sku,internal_sku,name,unit,is_inventory_tracked,base_unit_id,purchase_unit_id,inventory_policy)
  values(ingredient,c,'HUEVO','HUEVO','Huevo','piece',true,piece_id,piece_id,'tracked');
  insert into public.products(id,company_id,alpha_sku,internal_sku,name,unit,is_sellable,is_inventory_tracked,base_unit_id,sales_unit_id,inventory_policy)
  values(dish,c,'HUEVO-EXTRA','HUEVO-EXTRA','Huevo extra','piece',true,false,piece_id,piece_id,'not_required');
  insert into public.product_purchase_units(product_id,purchase_unit_id,base_units_per_purchase_unit,updated_by)values(ingredient,piece_id,1,u);
  insert into public.culinary_recipes(id,company_id,product_id,recipe_kind)values(recipe,c,dish,'dish');
  insert into public.culinary_recipe_versions(id,recipe_id,version_number,status,yield_quantity,yield_unit_code,portion_count,valid_from,activated_by,activated_at)
  values(version_id,recipe,1,'active',1,'piece',1,now()-interval'1 minute',u,now()-interval'1 minute');
  insert into public.culinary_recipe_components(recipe_version_id,component_product_id,entered_quantity,entered_unit_code,normalized_quantity,base_unit_code)
  values(version_id,ingredient,1,'piece',1,'piece');
  insert into public.inventory_balances(company_id,location_id,product_id,quantity_on_hand)values(c,loc,ingredient,2);

  readiness:=public.culinary_pos_readiness(c,loc,dish,1,now(),'MXN');
  if readiness->>'allowed'<>'true' or readiness#>>'{warnings,0,code}'<>'missing_component_cost' then
    raise exception 'El costo pendiente bloqueó el POS o no quedó como advertencia: %',readiness;
  end if;

  update public.inventory_balances set quantity_on_hand=0 where company_id=c and location_id=loc and product_id=ingredient;
  readiness:=public.culinary_pos_readiness(c,loc,dish,1,now(),'MXN');
  if readiness->>'allowed'<>'false' or readiness#>>'{blockers,0,code}'<>'insufficient_ingredient_stock' then
    raise exception 'La falta de existencia no bloqueó el POS: %',readiness;
  end if;
  update public.inventory_balances set quantity_on_hand=2 where company_id=c and location_id=loc and product_id=ingredient;

  insert into public.sales(id,company_id,location_id,cash_register_id,cash_session_id,cashier_id,sale_type,currency_code,subtotal_amount,discount_amount,tax_amount,total_amount,client_request_id)
  values(sale_id,c,loc,reg,session_id,u,'cash','MXN',10,0,0,10,'82300005-0000-4000-8000-000000000013');
  insert into public.sale_items(id,sale_id,product_id,product_code,product_name,unit_name,quantity,unit_price_amount,gross_amount,discount_percent,discount_amount,taxable_amount,tax_amount,total_amount)
  values(item_id,sale_id,dish,'HUEVO-EXTRA','Huevo extra','piece',1,10,10,0,0,10,0,10);
  select quantity_on_hand into balance from public.inventory_balances where company_id=c and location_id=loc and product_id=ingredient;
  if balance<>1 then raise exception 'La venta sin costo no descontó la existencia: %',balance;end if;
  if not exists(select 1 from public.culinary_sale_consumptions consumption join public.culinary_sale_item_snapshots snapshot on snapshot.id=consumption.snapshot_id
    where snapshot.sale_item_id=item_id and consumption.ingredient_product_id=ingredient and consumption.product_cost_id is null and consumption.recognized_cost_amount is null)
  then raise exception 'La venta sin costo no dejó consumo auditable pendiente de costo.';end if;
  if (select recognized_culinary_snapshot_id is null or recognized_unit_cost is not null from public.sale_items where id=item_id)then
    raise exception 'El platillo no conservó el snapshot con costo pendiente.';
  end if;
end$$;
rollback;
