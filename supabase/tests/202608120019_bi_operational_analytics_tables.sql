-- BI Fase 3 operativa: volumen, búsqueda, orden, permisos, parcialidad y exportación.
begin;

do $installation$
begin
  if to_regprocedure('public.bi_get_operational_table(uuid,text,text,date,date,uuid,uuid,uuid,uuid,text,text,text,integer,integer,text)') is null then raise exception 'Falta tabla operativa BI.';end if;
  if not has_function_privilege('authenticated','public.bi_get_operational_table(uuid,text,text,date,date,uuid,uuid,uuid,uuid,text,text,text,integer,integer,text)','execute') then raise exception 'authenticated no puede consultar tablas operativas.';end if;
  if has_function_privilege('anon','public.bi_get_operational_table(uuid,text,text,date,date,uuid,uuid,uuid,uuid,text,text,text,integer,integer,text)','execute') then raise exception 'anon no debe consultar tablas operativas.';end if;
end;$installation$;

do $fixtures$
declare
  c uuid:='8a120019-1000-4000-8000-000000000001';u uuid:='8a120019-1000-4000-8000-000000000002';
  register_id uuid:='8a120019-1000-4000-8000-000000000003';session_id uuid:='8a120019-1000-4000-8000-000000000004';
begin
  insert into public.companies(id,legal_name,display_name,base_currency_code)values(c,'BI Operativo QA','BI Operativo QA','MXN');
  insert into auth.users(id,aud,role,email,encrypted_password)values(u,'authenticated','authenticated','bi-operativo@example.com','');
  insert into public.user_roles(user_id,role_id,company_id)select u,id,c from public.roles where code='direccion_admin';
  create temporary table bi_op_locations(n integer primary key,id uuid not null,name text not null)on commit drop;
  insert into bi_op_locations select n,gen_random_uuid(),format('Sucursal %s',n)from generate_series(1,3)n;
  insert into public.locations(id,company_id,external_code,name,location_type,is_active)select id,c,format('OP-%s',n),name,'sucursal',true from bi_op_locations;
  insert into public.cash_registers(id,company_id,location_id,code,display_name,currency_code)
  select register_id,c,id,'OP-CAJA','Caja BI','MXN'from bi_op_locations where n=1;
  insert into public.cash_sessions(id,company_id,cash_register_id,location_id,opened_by,status,opening_amount)
  select session_id,c,register_id,id,u,'open',0 from bi_op_locations where n=1;
  insert into public.accounting_config_versions(company_id,version,status,base_currency,cutoff_date,catalog_structure,tax_treatment,responsibilities,change_reason,approved_by,approved_at)
  values(c,1,'approved','MXN',date'2025-01-01','{}','{}','{}','Configuración BI operativa',u,now());

  create temporary table bi_op_categories(n integer primary key,id uuid not null,name text not null)on commit drop;
  insert into bi_op_categories select n,gen_random_uuid(),format('Categoría %s',lpad(n::text,2,'0'))from generate_series(1,12)n;
  insert into public.product_categories(id,company_id,external_code,name)select id,c,format('CAT-%s',n),name from bi_op_categories;
  create temporary table bi_op_products(n integer primary key,id uuid not null,category_id uuid not null,name text not null)on commit drop;
  insert into bi_op_products select product_number.n,gen_random_uuid(),category.id,format('Producto %s',lpad(product_number.n::text,3,'0'))
  from generate_series(1,120) product_number(n)
  join bi_op_categories category on category.n=((product_number.n-1)%12)+1;
  insert into public.products(id,company_id,alpha_sku,name,category_id,unit)
  select id,c,format('SKU-OP-%s',n),name,category_id,'PIEZA'from bi_op_products;

  create temporary table bi_op_sales(sale_id uuid primary key,product_id uuid not null,location_id uuid not null,occurred_at timestamptz not null,amount numeric not null)on commit drop;
  insert into bi_op_sales
  select gen_random_uuid(),product.id,location.id,period.occurred_at,
    case when period.current_period then case when product.n%3=0 then 50 else 130 end else 100 end
  from bi_op_products product join bi_op_locations location on location.n=((product.n-1)%3)+1
  cross join(values('2026-07-15T12:00:00Z'::timestamptz,true),('2026-06-15T12:00:00Z'::timestamptz,false))period(occurred_at,current_period);
  insert into public.sales(id,company_id,location_id,cash_register_id,cash_session_id,cashier_id,sale_type,status,currency_code,subtotal_amount,discount_amount,tax_amount,total_amount,client_request_id,completed_at)
  select sale_id,c,location_id,register_id,session_id,u,'cash','completed','MXN',amount,0,amount*.16,amount*1.16,gen_random_uuid(),occurred_at from bi_op_sales;
  insert into public.sale_items(sale_id,product_id,product_code,product_name,unit_name,quantity,unit_price_amount,gross_amount,discount_percent,discount_amount,taxable_amount,tax_amount,total_amount)
  select sale.sale_id,product.id,format('SKU-OP-%s',product.n),product.name,'PIEZA',1,sale.amount,sale.amount,0,0,sale.amount,sale.amount*.16,sale.amount*1.16
  from bi_op_sales sale join bi_op_products product on product.id=sale.product_id;
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);
end;$fixtures$;

set local role authenticated;

do $assertions$
declare
  c uuid:='8a120019-1000-4000-8000-000000000001';r jsonb;blocked boolean;started timestamptz;short_ms numeric;long_ms numeric;
begin
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub','8a120019-1000-4000-8000-000000000002',true);
  started:=clock_timestamp();
  r:=public.bi_get_operational_table(c,'net_sales','product',date'2026-07-01',date'2026-07-31',null,null,null,null,null,'negative_impact','desc',1,999);
  short_ms:=extract(epoch from(clock_timestamp()-started))*1000;
  if(r->'pagination'->>'total')::integer<>120 or(r->'pagination'->>'page_size')::integer<>100 or jsonb_array_length(r->'items')<>100 then raise exception 'Paginación de producto incorrecta: %',r->'pagination';end if;
  if r->'items'->0->>'status'<>'deteriorated'or(r->'items'->0->>'change_value')::numeric<>-50 then raise exception 'Prioridad negativa incorrecta: %',r->'items'->0;end if;
  if(r->'items'->0->>'ranking')::integer<>1 then raise exception 'Ranking incorrecto.';end if;

  r:=public.bi_get_operational_table(c,'net_sales','product',date'2026-07-01',date'2026-07-31',null,null,null,null,'Producto 012','entity','asc',1,25);
  if(r->'pagination'->>'total')::integer<>1 or r->'items'->0->>'group_label'<>'Producto 012' then raise exception 'Búsqueda server-side incorrecta: %',r;end if;
  r:=public.bi_get_operational_table(c,'net_sales','category',date'2026-07-01',date'2026-07-31',null,null,null,null,null,'share_percent','desc',1,25);
  if(r->'pagination'->>'total')::integer<>12 then raise exception 'Categorías incorrectas: %',r->'pagination';end if;
  r:=public.bi_get_operational_table(c,'net_sales','location',date'2026-07-01',date'2026-07-31',null,null,null,null,null,'positive_contribution','desc',1,25);
  if(r->'pagination'->>'total')::integer<>3 then raise exception 'Sucursales incorrectas: %',r->'pagination';end if;

  r:=public.bi_get_operational_table(c,'gross_margin','product',date'2026-07-01',date'2026-07-31',null,null,null,null,null,'negative_impact','desc',1,25);
  if not(r->>'partial')::boolean or(r->'scope'->>'partial_groups')::integer<>120 then raise exception 'Margen parcial no fue explícito: %',r->'scope';end if;

  blocked:=false;begin perform public.bi_get_operational_table(c,'net_sales','seller',date'2026-07-01',date'2026-07-31');exception when others then blocked:=position('sucursal, categoría o producto' in sqlerrm)>0;end;
  if not blocked then raise exception 'Se publicó vendedor sin identidad canónica.';end if;
  blocked:=false;begin perform public.bi_get_operational_table(c,'net_sales','product',date'2026-07-01',date'2026-07-31',null,null,null,null,null,'drop table sales','desc',1,25);exception when others then blocked:=position('no permitida' in sqlerrm)>0;end;
  if not blocked then raise exception 'La allowlist aceptó un orden inválido.';end if;

  r:=public.bi_prepare_operational_export(c,'csv',jsonb_build_object('metric_code','net_sales','dimension','product','date_from','2026-07-01','date_to','2026-07-31','search','Producto 012','sort_by','entity','sort_direction','asc'));
  if r->>'job_id'is null or r->'configs'->0->'definition'->>'search'<>'Producto 012' then raise exception 'Snapshot de exportación incorrecto: %',r;end if;

  started:=clock_timestamp();
  perform public.bi_get_operational_table(c,'net_sales','product',date'2025-08-01',date'2026-08-01',null,null,null,null,null,'negative_impact','desc',1,25);
  long_ms:=extract(epoch from(clock_timestamp()-started))*1000;
  if short_ms>5000 or long_ms>5000 then raise exception 'Consulta fuera del umbral local: corto % ms, largo % ms',short_ms,long_ms;end if;
  if not exists(select 1 from public.audit_log where company_id=c and action='bi.operational_table_queried')then raise exception 'Falta auditoría de consulta operativa.';end if;
  raise notice 'BI operativo: corto % ms, largo % ms',round(short_ms,2),round(long_ms,2);
end;$assertions$;

reset role;
rollback;
