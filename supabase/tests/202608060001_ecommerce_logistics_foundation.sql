begin;

do $$
declare
  c uuid:='60860000-0000-4000-8000-000000000001';u uuid:='60860000-0000-4000-8000-000000000002';
  l uuid:='60860000-0000-4000-8000-000000000003';p uuid:='60860000-0000-4000-8000-000000000004';
  customer uuid:='60860000-0000-4000-8000-000000000005';o uuid:='60860000-0000-4000-8000-000000000006';
  address_id uuid;snapshot jsonb;blocked boolean:=false;
begin
  insert into public.companies(id,legal_name,display_name) values(c,'Ecommerce QA','Ecommerce QA');
  insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,last_sign_in_at) values(u,'authenticated','authenticated','ecommerce-qa@example.invalid','',now(),now());
  insert into public.user_roles(user_id,role_id,company_id) select u,id,c from public.roles where code='direccion_admin';
  insert into public.locations(id,company_id,external_code,name,location_type,classification_source) values(l,c,'EC-01','Origen ecommerce','almacen_operativo','manual_review');
  insert into public.products(id,company_id,alpha_sku,name,unit,product_type) values(p,c,'EC-P-01','Producto ecommerce','PZA','P. TERMINADO');
  insert into public.customers(id,company_id,code,display_name,credit_enabled,credit_limit,credit_term_days,created_by) values(customer,c,'EC-C-01','Cliente ecommerce',false,0,0,u);
  insert into public.sales_deposit_orders(id,company_id,location_id,customer_id,folio,currency_code,subtotal_amount,tax_amount,total_amount,created_by) values(o,c,l,customer,'EC-O-01','MXN',100,16,116,u);
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);

  address_id:=public.save_customer_delivery_address(c,customer,null,'Casa','Cliente ecommerce','5555555555','Av. Prueba 123',null,'Centro','Monterrey','Nuevo León','64000','MX','Tocar el timbre',true);
  snapshot:=public.record_sales_order_delivery_address(c,o,address_id,'customer_address','Cliente ecommerce','5555555555','Av. Prueba 123',null,'Centro','Monterrey','Nuevo León','64000','MX','Tocar el timbre');
  if (snapshot->>'postal_code')<>'64000' or (snapshot->>'idempotent')::boolean then raise exception 'Snapshot incorrecto: %',snapshot;end if;
  snapshot:=public.record_sales_order_delivery_address(c,o,address_id,'customer_address','Cliente ecommerce','5555555555','Av. Prueba 123',null,'Centro','Monterrey','Nuevo León','64000','MX','Tocar el timbre');
  if not (snapshot->>'idempotent')::boolean then raise exception 'El snapshot no respetó idempotencia.';end if;

  update public.customer_addresses set address_line='Av. Nueva 999' where id=address_id;
  if (select address_line from public.sales_order_delivery_addresses where order_id=o)<>'Av. Prueba 123' then raise exception 'El pedido cambió junto con la dirección del cliente.';end if;
  begin
    update public.sales_order_delivery_addresses set address_line='Mutación inválida' where order_id=o;
  exception when others then blocked:=true;end;
  if not blocked then raise exception 'La dirección histórica permitió modificar datos de entrega.';end if;
  update public.sales_order_delivery_addresses set latitude=25.686614,longitude=-100.316113,geocoding_provider='qa',geocoding_precision='postal_code',geocoding_attempted_at=now(),geocoded_at=now() where order_id=o;
  if (select latitude from public.sales_order_delivery_addresses where order_id=o)<>25.686614 then raise exception 'No se pudo enriquecer geográficamente el snapshot.';end if;

  if has_table_privilege('authenticated','public.sales_order_delivery_addresses','select') then raise exception 'La tabla histórica no debe exponerse directamente.';end if;
end $$;

rollback;
