begin;
do $$
declare
  c uuid:='82300002-0000-4000-8000-000000000001';
  u uuid:='82300002-0000-4000-8000-000000000002';
  loc uuid:='82300002-0000-4000-8000-000000000003';
  supplier_id uuid:='82300002-0000-4000-8000-000000000004';
  gram_id uuid:='82300002-0000-4000-8000-000000000005';
  kilo_id uuid:='82300002-0000-4000-8000-000000000006';
  ingredient_id uuid:='82300002-0000-4000-8000-000000000007';
  request_id uuid:='82300002-0000-4000-8000-000000000008';
  piece_id uuid:='82300002-0000-4000-8000-000000000009';
  dish_id uuid:='82300002-0000-4000-8000-000000000010';
  recipe_id uuid:='82300002-0000-4000-8000-000000000011';
  version_id uuid:='82300002-0000-4000-8000-000000000012';
  price_list_id uuid:='82300002-0000-4000-8000-000000000013';
  result jsonb;analysis jsonb;balance numeric;cost numeric;ledger_count integer;
begin
  insert into public.companies(id,legal_name,display_name,product_experience_code)
  values(c,'Restaurante compras E2E','Restaurante compras E2E','restaurant');
  insert into auth.users(id,aud,role,email,encrypted_password)
  values(u,'authenticated','authenticated','restaurant-purchases@example.invalid','');
  insert into public.user_roles(user_id,role_id,company_id)
  select u,id,c from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',u::text,true);
  insert into public.locations(id,company_id,external_code,name)values(loc,c,'COCINA','Cocina');
  insert into public.suppliers(id,company_id,code,display_name)values(supplier_id,c,'PRV-TEST','Proveedor prueba');
  insert into public.units_of_measure(id,company_id,code,name,source)values
    (gram_id,c,'g','Gramo','manual'),(kilo_id,c,'kg','Kilogramo','manual'),(piece_id,c,'piece','Pieza','manual');
  insert into public.products(id,company_id,alpha_sku,internal_sku,name,unit,is_inventory_tracked,base_unit_id,purchase_unit_id,inventory_policy)
  values(ingredient_id,c,'JITOMATE','JITOMATE','Jitomate','g',true,gram_id,kilo_id,'tracked');
  insert into public.products(id,company_id,alpha_sku,internal_sku,name,unit,is_sellable,is_inventory_tracked,base_unit_id,sales_unit_id,inventory_policy)
  values(dish_id,c,'PLATILLO','PLATILLO','Platillo prueba','piece',true,false,piece_id,piece_id,'not_required');
  insert into public.product_culinary_roles(company_id,product_id,role,assigned_by,reason)
  values(c,ingredient_id,'ingredient',u,'Prueba de compra'),(c,dish_id,'dish',u,'Prueba de margen');
  insert into public.product_purchase_units(product_id,purchase_unit_id,base_units_per_purchase_unit,updated_by)
  values(ingredient_id,kilo_id,1000,u);

  if public.search_restaurant_purchase_ingredients(c,'Jitomate',10)#>>'{items,0,id}'<>ingredient_id::text then
    raise exception 'El selector no encontró el insumo canónico.';
  end if;

  result:=public.confirm_restaurant_purchase_receipt(
    c,supplier_id,loc,current_date,'FACT-TEST','Compra end-to-end',
    jsonb_build_array(jsonb_build_object('product_id',ingredient_id,'quantity',2,'unit_cost',60)),request_id
  );
  if result->>'status'<>'confirmed' or result->>'idempotent'<>'false' then
    raise exception 'La recepción no fue confirmada: %',result;
  end if;
  select quantity_on_hand into balance from public.inventory_balances where company_id=c and location_id=loc and product_id=ingredient_id;
  if balance<>2000 then raise exception 'La entrada no convirtió 2 kg a 2000 g; saldo: %',balance;end if;
  select amount into cost from public.product_costs where company_id=c and product_id=ingredient_id and cost_type='replacement_cost' and valid_to is null;
  if cost<>0.06 then raise exception 'El costo vigente no quedó en 0.06 MXN por gramo: %',cost;end if;
  result:=public.search_restaurant_purchase_ingredients(c,'JITOMATE',10);
  if (result#>>'{items,0,current_cost}')::numeric<>0.06
    or (result#>>'{items,0,current_purchase_unit_cost}')::numeric<>60
  then raise exception 'El selector confundió costo por gramo con precio por kilogramo: %',result;end if;
  select count(*) into ledger_count from public.inventory_ledger where company_id=c and location_id=loc and product_id=ingredient_id and movement_type='purchase_receipt';
  if ledger_count<>1 then raise exception 'La compra no dejó un solo movimiento auditable.';end if;
  result:=public.confirm_restaurant_purchase_receipt(
    c,supplier_id,loc,current_date,'FACT-TEST','Compra end-to-end',
    jsonb_build_array(jsonb_build_object('product_id',ingredient_id,'quantity',2,'unit_cost',60)),request_id
  );
  if result->>'idempotent'<>'true' then raise exception 'El reintento no fue idempotente.';end if;
  select quantity_on_hand into balance from public.inventory_balances where company_id=c and location_id=loc and product_id=ingredient_id;
  if balance<>2000 then raise exception 'El reintento duplicó inventario: %',balance;end if;
  analysis:=public.get_restaurant_weekly_cost_analysis(c,date_trunc('week',current_date)::date,null,1,1,20);
  if analysis#>>'{ingredients,0,name}'<>'Jitomate'
    or (analysis#>>'{ingredients,0,current_cost}')::numeric<>0.06
    or (analysis#>>'{ingredients,0,receipt_count}')::integer<>1
  then raise exception 'El análisis semanal no reflejó la compra: %',analysis;end if;

  insert into public.culinary_recipes(id,company_id,product_id,recipe_kind)values(recipe_id,c,dish_id,'dish');
  insert into public.culinary_recipe_versions(id,recipe_id,version_number,status,yield_quantity,yield_unit_code,portion_count,valid_from,activated_by,activated_at)
  values(version_id,recipe_id,1,'active',1,'piece',1,now()-interval'1 minute',u,now()-interval'1 minute');
  insert into public.culinary_recipe_components(recipe_version_id,component_product_id,entered_quantity,entered_unit_code,normalized_quantity,base_unit_code)
  values(version_id,ingredient_id,100,'g',1,'g');
  insert into public.price_lists(id,company_id,external_code,name,currency_code,is_active,status,is_default)
  values(price_list_id,c,'MENU','Menú','MXN',true,'active',true);
  insert into public.product_prices(product_id,price_list_id,amount,currency_code,valid_from,created_by)
  values(dish_id,price_list_id,10,'MXN',now()-interval'1 minute',u);
  perform public.set_restaurant_margin_threshold(c,dish_id,50,true,'Límite de prueba end-to-end','82300002-0000-4000-8000-000000000014');
  if not exists(
    select 1 from public.bi_alerts where company_id=c and rule_code='restaurant_dish_margin_below_threshold'
      and entity_id=dish_id and status='active' and observed_value=40 and threshold_value=50
  )then raise exception 'No se creó la alerta persistente del platillo: %',(select coalesce(jsonb_agg(to_jsonb(a)),'[]'::jsonb)from public.bi_alerts a where a.company_id=c);end if;
  analysis:=public.get_restaurant_weekly_cost_analysis(c,date_trunc('week',current_date)::date,null,1,1,20);
  if analysis#>>'{dishes,0,name}'<>'Platillo prueba'
    or (analysis#>>'{dishes,0,projected_cost}')::numeric<>6
    or (analysis#>>'{dishes,0,projected_margin_percent}')::numeric<>40
    or analysis#>>'{dishes,0,below_threshold}'<>'true'
    or (analysis#>>'{summary,dishes_below_threshold}')::integer<>1
  then raise exception 'El análisis de platillos o su límite es incorrecto: %',analysis;end if;
end$$;
rollback;
