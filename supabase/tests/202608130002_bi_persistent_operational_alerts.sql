-- BI Fase 4: instalación, idempotencia, transiciones, auditoría y rendimiento local.
begin;

do $installation$
begin
  if to_regprocedure('public.bi_evaluate_company_alerts(uuid,date,date,text,uuid)') is null then raise exception 'Falta evaluador de alertas.';end if;
  if to_regprocedure('public.bi_list_alerts(uuid,text,text,text,uuid,date,date,text,integer,integer)') is null then raise exception 'Falta listado de alertas.';end if;
  if has_function_privilege('anon','public.bi_list_alerts(uuid,text,text,text,uuid,date,date,text,integer,integer)','execute') then raise exception 'anon no debe consultar alertas.';end if;
  if not exists(select 1 from cron.job where jobname='satrapy-bi-operational-alerts')then raise exception 'Falta evaluación programada.';end if;
end;$installation$;

do $fixtures$
declare c uuid:='8a130002-1000-4000-8000-000000000001';u uuid:='8a130002-1000-4000-8000-000000000002';l uuid:='8a130002-1000-4000-8000-000000000003';r uuid:='8a130002-1000-4000-8000-000000000004';s uuid:='8a130002-1000-4000-8000-000000000005';sale_id uuid;product_id uuid;
begin
  insert into public.companies(id,legal_name,display_name,base_currency_code)values(c,'BI Alertas QA','BI Alertas QA','MXN');
  insert into auth.users(id,aud,role,email,encrypted_password)values(u,'authenticated','authenticated','bi-alertas@example.com','');
  insert into public.user_roles(user_id,role_id,company_id)select u,id,c from public.roles where code='direccion_admin';
  insert into public.locations(id,company_id,external_code,name,location_type,is_active)values(l,c,'AL-1','Sucursal Alertas','sucursal',true);
  insert into public.cash_registers(id,company_id,location_id,code,display_name,currency_code)values(r,c,l,'AL-CAJA','Caja Alertas','MXN');
  insert into public.cash_sessions(id,company_id,cash_register_id,location_id,opened_by,status,opening_amount)values(s,c,r,l,u,'open',0);
  insert into public.accounting_config_versions(company_id,version,status,base_currency,cutoff_date,catalog_structure,tax_treatment,responsibilities,change_reason,approved_by,approved_at)
  values(c,1,'approved','MXN',date'2025-01-01','{}','{}','{}','Alertas BI',u,now());
  for n in 1..25 loop
    product_id:=gen_random_uuid();sale_id:=gen_random_uuid();
    insert into public.products(id,company_id,alpha_sku,name,unit)values(product_id,c,'AL-'||n,'Producto alerta '||n,'PIEZA');
    insert into public.sales(id,company_id,location_id,cash_register_id,cash_session_id,cashier_id,sale_type,status,currency_code,subtotal_amount,discount_amount,tax_amount,total_amount,client_request_id,completed_at)
    values(sale_id,c,l,r,s,u,'cash','completed','MXN',40,0,6.4,46.4,gen_random_uuid(),timestamptz'2026-07-15 12:00:00+00');
    insert into public.sale_items(sale_id,product_id,product_code,product_name,unit_name,quantity,unit_price_amount,gross_amount,discount_percent,discount_amount,taxable_amount,tax_amount,total_amount)
    values(sale_id,product_id,'AL-'||n,'Producto alerta '||n,'PIEZA',1,40,40,0,0,40,6.4,46.4);
    sale_id:=gen_random_uuid();
    insert into public.sales(id,company_id,location_id,cash_register_id,cash_session_id,cashier_id,sale_type,status,currency_code,subtotal_amount,discount_amount,tax_amount,total_amount,client_request_id,completed_at)
    values(sale_id,c,l,r,s,u,'cash','completed','MXN',100,0,16,116,gen_random_uuid(),timestamptz'2026-06-15 12:00:00+00');
    insert into public.sale_items(sale_id,product_id,product_code,product_name,unit_name,quantity,unit_price_amount,gross_amount,discount_percent,discount_amount,taxable_amount,tax_amount,total_amount)
    values(sale_id,product_id,'AL-'||n,'Producto alerta '||n,'PIEZA',1,100,100,0,0,100,16,116);
  end loop;
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);
end;$fixtures$;

set local role authenticated;
do $assertions$
declare c uuid:='8a130002-1000-4000-8000-000000000001';a uuid;r1 jsonb;r2 jsonb;listed jsonb;history jsonb;started timestamptz;elapsed numeric;
begin
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub','8a130002-1000-4000-8000-000000000002',true);
  started:=clock_timestamp();r1:=public.bi_evaluate_company_alerts(c,date'2026-07-01',date'2026-07-31','previous_period','8a130002-1000-4000-8000-000000000002'::uuid);r2:=public.bi_evaluate_company_alerts(c,date'2026-07-01',date'2026-07-31','previous_period','8a130002-1000-4000-8000-000000000002'::uuid);elapsed:=extract(epoch from(clock_timestamp()-started))*1000;
  if(r1->>'created')::integer<1 or(r2->>'created')::integer<>0 then raise exception 'Evaluación no idempotente: %, %',r1,r2;end if;
  if exists(select condition_key from public.bi_alerts where company_id=c and status in('active','reviewed')group by condition_key having count(*)>1)then raise exception 'Condición abierta duplicada.';end if;
  listed:=public.bi_list_alerts(c,'active',null,null,null,null,null,'ventas',1,25);
  if(listed->'pagination'->>'total')::integer<1 then raise exception 'Búsqueda/listado no devolvió alertas: %',listed;end if;
  select id into a from public.bi_alerts where company_id=c and status='active'order by created_at limit 1;
  perform public.bi_transition_alert(c,a,'review',null);perform public.bi_transition_alert(c,a,'resolve','Validación operativa completada');
  history:=public.bi_get_alert_history(c,a,1,25);
  if jsonb_array_length(history->'items')<3 then raise exception 'Historial incompleto: %',history;end if;
  if not exists(select 1 from public.audit_log where company_id=c and entity_id=a and action='bi.alert_resolved')then raise exception 'Falta auditoría de resolución.';end if;
  if elapsed>5000 then raise exception 'Dos evaluaciones excedieron 5 s: % ms',elapsed;end if;
  raise notice 'BI alertas: dos evaluaciones % ms, creadas %, actualizadas %',round(elapsed,2),r1->>'created',r2->>'updated';
end;$assertions$;
reset role;
rollback;
