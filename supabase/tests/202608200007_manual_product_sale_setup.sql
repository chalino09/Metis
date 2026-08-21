begin;

do $test$
declare
  v_company uuid:='82030000-0000-4000-8000-000000000001';v_actor uuid:='82030000-0000-4000-8000-000000000002';
  v_location uuid:='82030000-0000-4000-8000-000000000003';v_unit uuid:='82030000-0000-4000-8000-000000000004';
  v_tax uuid:='82030000-0000-4000-8000-000000000005';v_result jsonb;v_replay jsonb;v_product uuid;v_list uuid;
begin
  insert into public.companies(id,legal_name,display_name,default_price_policy) values(v_company,'Alta asistida prueba','Alta asistida prueba','specific_list');
  insert into auth.users(id,aud,role,email,encrypted_password) values(v_actor,'authenticated','authenticated','guided-product@example.com','');
  insert into public.user_roles(user_id,role_id,company_id) select v_actor,id,v_company from public.roles where code='super_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',v_actor::text,true);
  insert into public.locations(id,company_id,external_code,name,location_type,is_active) values(v_location,v_company,'SUC-01','Sucursal principal','sucursal',true);
  insert into public.units_of_measure(id,company_id,code,name) values(v_unit,v_company,'PZA','Pieza');
  insert into public.tax_categories(id,company_id,code,name) values(v_tax,v_company,'IVA16','IVA 16%');
  insert into public.tax_rates(tax_category_id,jurisdiction_code,rate,valid_from,created_by) values(v_tax,'MX',0.16,now()-interval '1 day',v_actor);

  v_result:=public.create_product_sale_setup(v_company,'Producto guiado','PZA','Pruebas',null,'tracked',v_tax,116,null,'{}'::uuid[],'82030000-0000-4000-8000-000000000006');
  v_product:=(v_result->>'product_id')::uuid;v_list:=(v_result->>'price_list_id')::uuid;
  if (v_result->'readiness'->>'pos_ready')::boolean is not true then raise exception 'El producto no quedó configurado para venta: %',v_result;end if;
  if (select count(*) from public.products where id=v_product and internal_sku like 'PROD-%')<>1 then raise exception 'No se generó el código canónico.';end if;
  if (select count(*) from public.product_prices where product_id=v_product and price_list_id=v_list and amount=100)<>1 then raise exception 'El precio final no se convirtió a base sin IVA.';end if;
  if (select count(*) from public.sales_assortment_items item join public.location_sales_assortments assignment on assignment.assortment_id=item.assortment_id where item.product_id=v_product and assignment.location_id=v_location)<>1 then raise exception 'El producto no quedó disponible en la sucursal.';end if;
  if (select default_price_list_id from public.companies where id=v_company)<>v_list then raise exception 'No se creó la lista general predeterminada.';end if;

  v_replay:=public.create_product_sale_setup(v_company,'Producto guiado','PZA','Pruebas',null,'tracked',v_tax,116,null,'{}'::uuid[],'82030000-0000-4000-8000-000000000006');
  if coalesce((v_replay->>'idempotent')::boolean,false) is not true or (select count(*) from public.products where company_id=v_company)<>1 then raise exception 'El reintento duplicó el alta.';end if;
end;
$test$;

rollback;
