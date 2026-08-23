begin;
do $$
declare
 c uuid:='81700003-0000-4000-8000-000000000001';u uuid:='81700003-0000-4000-8000-000000000002';loc uuid:='81700003-0000-4000-8000-000000000003';reg uuid:='81700003-0000-4000-8000-000000000004';session_id uuid:='81700003-0000-4000-8000-000000000005';
 dish uuid:='81700003-0000-4000-8000-000000000010';prep uuid:='81700003-0000-4000-8000-000000000011';ingredient uuid:='81700003-0000-4000-8000-000000000012';
 dish_recipe uuid:='81700003-0000-4000-8000-000000000020';prep_recipe uuid:='81700003-0000-4000-8000-000000000021';dish_version uuid:='81700003-0000-4000-8000-000000000022';prep_version uuid:='81700003-0000-4000-8000-000000000023';
 sale_id uuid:='81700003-0000-4000-8000-000000000030';item_id uuid:='81700003-0000-4000-8000-000000000031';cost_result jsonb;movement_context jsonb;inventory_context jsonb;balance numeric;snapshot_count integer;
begin
 insert into public.companies(id,legal_name,display_name,product_experience_code)values(c,'Restaurante consumo','Restaurante consumo','restaurant');
 insert into auth.users(id,aud,role,email,encrypted_password)values(u,'authenticated','authenticated','restaurant-consumption@example.invalid','');
 insert into public.user_roles(user_id,role_id,company_id)select u,id,c from public.roles where code='direccion_admin';
 perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);
 insert into public.locations(id,company_id,external_code,name)values(loc,c,'COCINA','Cocina');
 insert into public.cash_registers(id,company_id,location_id,code,display_name)values(reg,c,loc,'CAJA','Caja');
 insert into public.cash_sessions(id,company_id,cash_register_id,location_id,opened_by)values(session_id,c,reg,loc,u);
 insert into public.products(id,company_id,alpha_sku,internal_sku,name,unit,is_inventory_tracked)values
  (dish,c,'DISH','DISH','Platillo','PZA',false),(prep,c,'PREP','PREP','Salsa','ml',false),(ingredient,c,'ING','ING','Tomate','g',true);
 insert into public.culinary_recipes(id,company_id,product_id,recipe_kind)values(dish_recipe,c,dish,'dish'),(prep_recipe,c,prep,'preparation');
 insert into public.culinary_recipe_versions(id,recipe_id,version_number,status,yield_quantity,yield_unit_code,portion_count,valid_from,activated_by,activated_at)values
  (dish_version,dish_recipe,1,'active',1,'piece',1,now()-interval '1 hour',u,now()-interval '1 hour'),
  (prep_version,prep_recipe,1,'active',1000,'ml',1,now()-interval '1 hour',u,now()-interval '1 hour');
 update public.culinary_recipe_versions set waste_percent=20 where id=prep_version;
 insert into public.culinary_recipe_components(recipe_version_id,component_product_id,entered_quantity,entered_unit_code,normalized_quantity,base_unit_code)values
  (dish_version,prep,100,'ml',1,'ml'),(prep_version,ingredient,500,'g',1,'g');
 insert into public.product_costs(company_id,product_id,cost_type,amount,currency_code,valid_from,created_by)values(c,ingredient,'replacement_cost',0.1,'MXN',now()-interval '1 hour',u);
 insert into public.inventory_balances(company_id,location_id,product_id,quantity_on_hand)values(c,loc,ingredient,1000);
 cost_result:=public.get_culinary_recipe_cost(c,dish,2,now(),'MXN');
 if cost_result->>'allowed'<>'true' or (cost_result->>'total_cost')::numeric<>12.5 then raise exception 'Costeo anidado con merma incorrecto: %',cost_result;end if;
 insert into public.sales(id,company_id,location_id,cash_register_id,cash_session_id,cashier_id,sale_type,currency_code,subtotal_amount,discount_amount,tax_amount,total_amount,client_request_id)
 values(sale_id,c,loc,reg,session_id,u,'cash','MXN',100,0,0,100,'81700003-0000-4000-8000-000000000032');
 insert into public.sale_items(id,sale_id,product_id,product_code,product_name,unit_name,quantity,unit_price_amount,gross_amount,discount_percent,discount_amount,taxable_amount,tax_amount,total_amount)
 values(item_id,sale_id,dish,'DISH','Platillo','PZA',2,50,100,0,0,100,0,100);
 insert into public.canonical_tickets(sale_id,company_id,location_id,folio,payload,content_sha256)
 values(sale_id,c,loc,'T-001','{}','restaurant-consumption-test');
 select quantity_on_hand into balance from public.inventory_balances where location_id=loc and product_id=ingredient;
 if balance<>875 then raise exception 'La venta no descontó 125 g considerando merma; saldo: %',balance;end if;
 select count(*) into snapshot_count from public.culinary_sale_item_recipe_versions v join public.culinary_sale_item_snapshots s on s.id=v.snapshot_id where s.sale_item_id=item_id;
 if snapshot_count<>2 or (select recognized_cost_amount from public.sale_items where id=item_id)<>12.5 then raise exception 'No se congelaron versiones y costo con merma.';end if;
 insert into public.sale_cancellations(company_id,sale_id,reason,client_request_id)values(c,sale_id,'Cancelación de prueba','81700003-0000-4000-8000-000000000033');
 select quantity_on_hand into balance from public.inventory_balances where location_id=loc and product_id=ingredient;
 if balance<>1000 then raise exception 'La cancelación no restituyó el consumo original; saldo: %',balance;end if;
 if (select count(*) from public.inventory_ledger where product_id=ingredient and movement_type in('culinary_sale','culinary_sale_reversal'))<>2 then raise exception 'Faltan movimientos culinarios auditables.';end if;
 movement_context:=public.list_inventory_location_movements(c,loc,ingredient,1,25);
 if movement_context#>>'{items,0,movement_type}'<>'culinary_sale_reversal'
   or movement_context#>>'{items,0,dish_name}'<>'Platillo'
   or movement_context#>>'{items,0,ticket_folio}'<>'T-001'
   or movement_context#>>'{items,0,reference_label}'<>'Platillo · Ticket T-001'
 then raise exception 'El reintegro no explica platillo y ticket: %',movement_context;end if;
 inventory_context:=public.search_inventory_products_by_location(c,loc,'Tomate',1,50);
 if inventory_context#>>'{items,0,locations,0,last_movement_type}'<>'culinary_sale_reversal'
   or inventory_context#>>'{items,0,locations,0,last_movement_reference_label}'<>'Platillo · Ticket T-001'
 then raise exception 'La existencia no explica el origen del reintegro: %',inventory_context;end if;
end$$;
rollback;
