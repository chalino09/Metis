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
  result jsonb;analysis jsonb;balance numeric;cost numeric;ledger_count integer;receipt_id uuid;ignored_id uuid;test_status text;
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

  -- El costo de recetas o reposición nunca debe inventar una compra.
  insert into public.product_costs(company_id,product_id,cost_type,amount,currency_code,valid_from)
  values(c,ingredient_id,'average_cost',.042,'MXN',now()-interval '1 day');
  result:=public.search_restaurant_purchase_ingredients(c,'Jitomate',10);
  if result#>>'{items,0,last_purchase_unit_cost}' is not null then raise exception 'Inventó una compra desde el promedio';end if;

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
  receipt_id:=(select id from public.purchase_receipts where company_id=c and document_reference='FACT-TEST');
  if (result#>>'{items,0,last_purchase_unit_cost}')::numeric<>60
    or result#>>'{items,0,last_purchase_date}'<>current_date::text
    or result#>>'{items,0,last_purchase_folio}' is null
  then raise exception 'No ofreció la compra confirmada con fecha y folio: %',result;end if;

  -- Una presentación actual distinta debe respetar el factor histórico de la compra.
  update public.product_purchase_units set base_units_per_purchase_unit=500 where product_id=ingredient_id;
  result:=public.search_restaurant_purchase_ingredients(c,'Jitomate',10);
  if (result#>>'{items,0,last_purchase_unit_cost}')::numeric<>30 then raise exception 'No normalizó la presentación histórica: %',result;end if;

  -- Borradores, anulaciones y fechas futuras no reemplazan la última compra válida.
  foreach test_status in array array['draft','reversed','future'] loop
    ignored_id:=gen_random_uuid();
    insert into public.purchase_receipts(id,company_id,purchase_order_id,supplier_id,location_id,folio,status,receipt_date,client_request_id)
    select ignored_id,c,r.purchase_order_id,r.supplier_id,r.location_id,'IGNORE-'||test_status,'draft',
      case when test_status='future' then current_date+1 else current_date end,gen_random_uuid()
    from public.purchase_receipts r where r.id=receipt_id;
    insert into public.purchase_receipt_lines(company_id,purchase_receipt_id,purchase_order_line_id,product_id,quantity,unit_cost,base_units_per_purchase_unit)
    select c,ignored_id,purchase_order_line_id,product_id,1,900,1000 from public.purchase_receipt_lines where purchase_receipt_id=receipt_id;
    if test_status<>'draft' then
      update public.purchase_receipts set status=case when test_status='future' then 'confirmed' else 'reversed' end,
        confirmed_at=now()+interval '1 minute',confirm_request_id=gen_random_uuid(),
        reversed_at=case when test_status='reversed' then now() end,
        reversed_by=case when test_status='reversed' then u end,
        reversal_reason=case when test_status='reversed' then 'Anulación de prueba' end,
        reverse_request_id=case when test_status='reversed' then gen_random_uuid() end
      where id=ignored_id;
    end if;
  end loop;
  result:=public.search_restaurant_purchase_ingredients(c,'Jitomate',10);
  if (result#>>'{items,0,last_purchase_unit_cost}')::numeric<>30 then raise exception 'Una recepción no válida contaminó la referencia: %',result;end if;

  -- No toca el costo promedio usado por las recetas ni los registros anteriores.
  if not exists(select 1 from public.product_costs where company_id=c and product_id=ingredient_id and cost_type='average_cost' and amount=.042 and valid_to is null) then raise exception 'Se alteró el costo promedio';end if;
  if (select base_units_per_purchase_unit from public.purchase_receipt_lines where purchase_receipt_id=receipt_id)<>1000 then raise exception 'Se alteró el historial de compra';end if;
end$$;
rollback;
