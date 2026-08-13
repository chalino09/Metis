begin;

do $test$
declare c uuid:='81200000-0000-4000-8000-000000000201';u uuid:='81200000-0000-4000-8000-000000000202';customer uuid:='81200000-0000-4000-8000-000000000203';v_case_id uuid;v_paged_sale_id uuid;policy_id uuid;block_id uuid;policies jsonb;sync_result jsonb;listed jsonb;case_detail jsonb;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values(u,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','collection-closeout@example.invalid','',now(),'{}','{}',now(),now());
  insert into public.companies(id,legal_name,display_name) values(c,'Cobranza cierre','Cobranza cierre');
  insert into public.user_roles(user_id,role_id,company_id) select u,id,c from public.roles where code='direccion_admin';
  insert into public.customers(id,company_id,code,display_name,credit_enabled,credit_limit,credit_term_days,is_active,created_by) values(customer,c,'C-CLOSE','Cliente cierre',true,100,30,true,u);
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);
  policy_id:=(public.collection_save_policy_draft(c,'Política de cierre','America/Mexico_City','{1,2,3,4,5}','09:00','18:00','72 hours',3,u,u)->>'id')::uuid;
  policies:=public.collection_list_policies(c);
  if policies->>'configuration_status'<>'not_configured' or jsonb_array_length(policies->'items')<>1 then raise exception 'La política no se expuso como borrador no configurado.';end if;
  perform public.collection_approve_policy(c,policy_id,'Aprobación de prueba');
  if public.collection_list_policies(c)->>'configuration_status'<>'configured' then raise exception 'La política aprobada no habilitó configuración.';end if;
  sync_result:=public.collection_sync_cases(c,500,null);
  if sync_result->>'has_more'<>'false' then raise exception 'Una cartera vacía no debe dejar cursor pendiente.';end if;
  insert into public.collection_cases(company_id,customer_id,technical_reason,created_by) values(c,customer,'Prueba de cierre',u) returning id into v_case_id;
  perform public.collection_register_block(c,v_case_id,'dispute','Saldo controvertido','Llamada registrada',u);
  select id into block_id from public.collection_blocks where case_id=v_case_id and block_type='dispute' and status='active';
  if block_id is null or(select status from public.collection_cases where id=v_case_id)<>'requires_human' then raise exception 'La disputa no bloqueó el caso.';end if;
  perform public.collection_resolve_block(c,block_id,'Saldo confirmado en revisión');
  if(select status from public.collection_cases where id=v_case_id)<>'pending' then raise exception 'Resolver el único bloqueo no devolvió el caso a pendiente.';end if;
  perform public.collection_register_block(c,v_case_id,'no_contact','Cliente solicitó no contacto','Solicitud por teléfono',u);
  if not exists(select 1 from public.collection_blocks where case_id=v_case_id and block_type='no_contact' and status='active') then raise exception 'No se guardó la solicitud de no contacto.';end if;
  insert into public.locations(id,company_id,external_code,name) values('81200000-0000-4000-8000-000000000204',c,'CLOSEOUT','Sucursal de cierre');
  insert into public.cash_registers(id,company_id,location_id,code,display_name) values('81200000-0000-4000-8000-000000000205',c,'81200000-0000-4000-8000-000000000204','CLOSEOUT','Caja de cierre');
  insert into public.cash_sessions(id,company_id,cash_register_id,location_id,opened_by) values('81200000-0000-4000-8000-000000000206',c,'81200000-0000-4000-8000-000000000205','81200000-0000-4000-8000-000000000204',u);
  with paged_customers as(
    insert into public.customers(company_id,code,display_name,credit_enabled,credit_limit,credit_term_days,is_active,created_by)
    select c,'C-PAGE-'||lpad(n::text,3,'0'),'Cliente paginado '||n,true,100,30,true,u from generate_series(1,501) n returning id
  ), paged_sales as(
    insert into public.sales(company_id,location_id,cash_register_id,cash_session_id,cashier_id,customer_id,sale_type,currency_code,subtotal_amount,discount_amount,tax_amount,total_amount,due_date,client_request_id)
    select c,'81200000-0000-4000-8000-000000000204','81200000-0000-4000-8000-000000000205','81200000-0000-4000-8000-000000000206',u,id,'credit','MXN',10,0,0,10,current_date-1,gen_random_uuid() from paged_customers returning id,customer_id
  ) insert into public.customer_receivables(company_id,customer_id,sale_id,due_date,original_amount,outstanding_amount)
    select c,customer_id,id,current_date-1,10,10 from paged_sales;
  sync_result:=public.collection_sync_cases(c,500,null);
  if (sync_result->>'scanned')::integer<>500 or sync_result->>'has_more'<>'true' or nullif(sync_result->>'next_cursor','') is null then raise exception 'El primer lote de 501 clientes no conservó cursor reanudable: %',sync_result;end if;
  sync_result:=public.collection_sync_cases(c,500,(sync_result->>'next_cursor')::uuid);
  if (sync_result->>'scanned')::integer<>1 or sync_result->>'has_more'<>'false' then raise exception 'El segundo lote no terminó la cartera: %',sync_result;end if;
  if (select count(*) from public.collection_cases where company_id=c and customer_id in(select id from public.customers where company_id=c and code like 'C-PAGE-%'))<>501 then raise exception 'La sincronización paginada no creó todos los casos.';end if;
  select cc.id,r.sale_id into v_case_id,v_paged_sale_id
  from public.customers cu
  join public.collection_cases cc on cc.company_id=cu.company_id and cc.customer_id=cu.id
  join public.customer_receivables r on r.company_id=cu.company_id and r.customer_id=cu.id
  where cu.company_id=c and cu.code='C-PAGE-001';
  insert into public.canonical_tickets(sale_id,company_id,location_id,folio,payload,content_sha256)
  values(v_paged_sale_id,c,'81200000-0000-4000-8000-000000000204','QA-COLLECTION-001','{}','collection-closeout-test');
  listed:=public.collection_list_cases(c,'open','C-PAGE-001',1,25);
  if jsonb_array_length(listed->'items')<>1
    or (listed->'items'->0->>'outstanding_amount')::numeric<>10
    or (listed->'items'->0->>'overdue_amount')::numeric<>10 then
    raise exception 'El listado no separó correctamente saldo abierto y vencido: %',listed;
  end if;
  case_detail:=public.collection_get_case(c,v_case_id);
  if case_detail->'documents'->0->>'reference'<>'QA-COLLECTION-001'
    or (case_detail->'documents'->0->>'outstanding_amount')::numeric<>10 then
    raise exception 'El expediente no resolvió el documento canónico: %',case_detail;
  end if;
end $test$;

rollback;
