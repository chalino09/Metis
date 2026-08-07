begin;

do $$
declare
  c uuid:='60860000-0000-4000-8000-000000000201';u uuid:='60860000-0000-4000-8000-000000000202';
  store uuid:='60860000-0000-4000-8000-000000000203';p uuid:='60860000-0000-4000-8000-000000000204';
  cost uuid:='60860000-0000-4000-8000-000000000205';ord uuid:='60860000-0000-4000-8000-000000000206';
  meta uuid:='60860000-0000-4000-8000-000000000207';resolved jsonb;resolved_again jsonb;customer uuid;address uuid;address_again uuid;summary jsonb;
begin
  if to_regclass('public.product_shipping_profiles') is not null then raise exception 'El perfil logístico duplicado todavía existe.';end if;
  insert into public.companies(id,legal_name,display_name) values(c,'Ecommerce Pilot QA','Ecommerce Pilot QA');
  insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,last_sign_in_at) values(u,'authenticated','authenticated','ecommerce-pilot-qa@example.invalid','',now(),now());
  insert into public.user_roles(user_id,role_id,company_id) select u,id,c from public.roles where code='direccion_admin';
  insert into public.products(id,company_id,alpha_sku,name,unit,product_type) values(p,c,'EC-PILOT-01','Producto piloto','PZA','P. TERMINADO');
  insert into public.product_costs(id,company_id,product_id,cost_type,amount,currency_code,valid_from,source_file_name)
  values(cost,c,p,'replacement_cost',100,'MXN',now()-interval '1 day','ecommerce-pilot-qa');
  insert into public.ecommerce_company_settings(company_id,low_margin_percent) values(c,20);
  insert into public.shopify_stores(id,company_id,shop_domain,shop_gid,installed_at,last_sync_at,access_token_ciphertext,granted_scopes) values(store,c,'satrapy-pilot.myshopify.com','gid://shopify/Shop/1',now(),now(),'v1.qa-ciphertext',array['read_orders']);
  insert into public.meta_ad_accounts(id,company_id,external_account_id,display_name,currency_code,connected_at,last_sync_at) values(meta,c,'act_123','Meta QA','MXN',now(),now());
  insert into public.meta_ad_daily_performance(company_id,meta_ad_account_id,performance_date,campaign_id,campaign_name,currency_code,spend_amount,impressions,clicks,attributed_purchases,attributed_purchase_value,raw_payload)
  values(c,meta,current_date,'campaign-1','Campaña QA','MXN',50,1000,25,1,124.4,'{}');

  perform set_config('request.jwt.claim.role','service_role',true);
  resolved:=public.resolve_shopify_customer(c,store,'gid://shopify/Customer/1','cliente@example.invalid','+52 81 1234 5678','Cliente piloto');
  customer:=(resolved->>'customer_id')::uuid;
  if resolved->>'status'<>'created' or customer is null then raise exception 'El cliente Shopify no se creó: %',resolved;end if;
  resolved_again:=public.resolve_shopify_customer(c,store,'gid://shopify/Customer/1','cliente@example.invalid','+52 81 1234 5678','Nombre distinto');
  if resolved_again->>'status'<>'matched' or(resolved_again->>'customer_id')::uuid<>customer then raise exception 'El cliente Shopify se duplicó: %',resolved_again;end if;
  perform public.resolve_shopify_customer(c,store,'gid://shopify/Customer/2','cliente@example.invalid',null,'Cliente piloto');
  if(select count(*) from public.customers where company_id=c)<>1 then raise exception 'Un mismo cliente se registró más de una vez.';end if;

  address:=public.resolve_shopify_customer_address(c,customer,'Cliente piloto','+52 81 1234 5678','Av. Piloto 1',null,'Centro','Monterrey','Nuevo León','64000','MX');
  address_again:=public.resolve_shopify_customer_address(c,customer,'Cliente piloto','+52 81 1234 5678','Av. Piloto 1',null,'Centro','Monterrey','Nuevo León','64000','MX');
  if address is null or address_again<>address or(select count(*) from public.customer_addresses where customer_id=customer)<>1 then raise exception 'La dirección canónica se duplicó.';end if;

  insert into public.ecommerce_orders(id,company_id,shopify_store_id,shopify_order_gid,order_name,customer_id,customer_match_status,customer_name_snapshot,customer_email_snapshot,customer_phone_snapshot,currency_code,financial_status,fulfillment_status,source_name,utm_source,utm_medium,utm_campaign,meta_campaign_id,subtotal_amount,discount_amount,tax_amount,shipping_charged_amount,total_amount,refunded_amount,actual_shipping_cost_amount,processed_at,raw_payload)
  values(ord,c,store,'gid://shopify/Order/1','#1001',customer,'created','Cliente piloto','cliente@example.invalid','+52 81 1234 5678','MXN','paid','fulfilled','web','facebook','paid_social','piloto','campaign-1',100,10,14.4,20,124.4,0,30,now(),'{}');
  insert into public.ecommerce_order_lines(company_id,order_id,shopify_line_gid,product_id,sku_snapshot,name_snapshot,quantity,unit_price_amount,discount_amount,total_amount,recognized_unit_cost_amount,recognized_cost_currency_code,recognized_product_cost_id,raw_payload)
  values(c,ord,'gid://shopify/LineItem/1',p,'EC-PILOT-01','Producto piloto',1,100,10,90,100,'MXN',cost,'{}');
  insert into public.ecommerce_order_addresses(order_id,company_id,customer_address_id,recipient_name,address_line,neighborhood,city,province,postal_code,country_code,latitude,longitude,coordinates_validated,raw_payload)
  values(ord,c,address,'Cliente piloto','Av. Piloto 1','Centro','Monterrey','Nuevo León','64000','MX',25.686614,-100.316113,true,'{}');
  insert into public.ecommerce_fulfillments(company_id,order_id,shopify_fulfillment_gid,status,tracking_company,tracking_numbers,tracking_urls,shipped_at,raw_payload)
  values(c,ord,'gid://shopify/Fulfillment/1','success','QA Carrier','["QA-1"]','["https://example.invalid/QA-1"]',now(),'{}');
  insert into public.shopify_webhook_receipts(company_id,shopify_store_id,shopify_event_id,topic,status,retry_count,next_retry_at,error_code,payload)
  values(c,store,'event-1','orders/updated','failed',1,now(),'temporary_error','{}');

  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);
  summary:=public.get_ecommerce_pilot_summary(c);
  if not(summary#>>'{shopify,connected}')::boolean or not(summary#>>'{meta_ads,connected}')::boolean then raise exception 'Conexiones incorrectas: %',summary;end if;
  if(summary#>>'{coverage,orders}')::integer<>1 or(summary#>>'{coverage,linked_lines}')::integer<>1 or(summary#>>'{coverage,complete_addresses}')::integer<>1 or(summary#>>'{coverage,known_shipping_costs}')::integer<>1 or(summary#>>'{coverage,attributed_orders}')::integer<>1 then raise exception 'Cobertura incorrecta: %',summary->'coverage';end if;
  if(summary#>>'{alerts,0,count}')::integer<>1 or(summary#>>'{alerts,4,count}')::integer<>1 or summary#>>'{alerts,4,severity}'<>'critical' then raise exception 'Alertas incorrectas: %',summary->'alerts';end if;
  if summary#>>'{currency_totals,0,currency_code}'<>'MXN' or(summary#>>'{currency_totals,0,net_sales_amount}')::numeric<>124.4 then raise exception 'Totales por moneda incorrectos: %',summary->'currency_totals';end if;
  if has_table_privilege('authenticated','public.ecommerce_orders','select') or has_table_privilege('authenticated','public.shopify_customer_links','select') or has_table_privilege('authenticated','public.meta_ad_daily_performance','select') then raise exception 'Las tablas de sincronización no deben exponerse directamente.';end if;
end $$;

rollback;
