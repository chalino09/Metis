begin;

do $test$
declare
  c uuid:='81700000-0000-4000-8000-000000000001';c2 uuid:='81700000-0000-4000-8000-000000000002';u uuid:='81700000-0000-4000-8000-000000000003';customer uuid:='81700000-0000-4000-8000-000000000004';customer2 uuid:='81700000-0000-4000-8000-000000000005';case_id uuid;case2_id uuid;policy_id uuid;v_task_id uuid;proposal_id uuid;v_sale_id uuid;listed jsonb;detail jsonb;blocked boolean:=false;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values(u,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','collection-phase3@example.invalid','',now(),'{}','{}',now(),now());
  insert into public.companies(id,legal_name,display_name) values(c,'Cobranza fase 3','Cobranza fase 3'),(c2,'Cobranza aislada','Cobranza aislada');
  insert into public.user_roles(user_id,role_id,company_id) select u,id,c from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);
  insert into public.customers(id,company_id,code,display_name,credit_enabled,credit_limit,credit_term_days,is_active,created_by) values(customer,c,'C-F3','Cliente fase 3',true,100,30,true,u),(customer2,c2,'C-OTHER','Cliente otra empresa',true,100,30,true,u);
  insert into public.locations(id,company_id,external_code,name) values('81700000-0000-4000-8000-000000000006',c,'F3','Sucursal fase 3');
  insert into public.cash_registers(id,company_id,location_id,code,display_name) values('81700000-0000-4000-8000-000000000007',c,'81700000-0000-4000-8000-000000000006','F3','Caja fase 3');
  insert into public.cash_sessions(id,company_id,cash_register_id,location_id,opened_by) values('81700000-0000-4000-8000-000000000008',c,'81700000-0000-4000-8000-000000000007','81700000-0000-4000-8000-000000000006',u);
  insert into public.sales(company_id,location_id,cash_register_id,cash_session_id,cashier_id,customer_id,sale_type,currency_code,subtotal_amount,discount_amount,tax_amount,total_amount,due_date,client_request_id) values(c,'81700000-0000-4000-8000-000000000006','81700000-0000-4000-8000-000000000007','81700000-0000-4000-8000-000000000008',u,customer,'credit','MXN',10,0,0,10,current_date-1,gen_random_uuid()) returning id into v_sale_id;
  insert into public.customer_receivables(company_id,customer_id,sale_id,due_date,original_amount,outstanding_amount) values(c,customer,v_sale_id,current_date-1,10,10);
  insert into public.collection_cases(company_id,customer_id,technical_reason,created_by) values(c,customer,'Prueba asistida',u) returning id into case_id;
  insert into public.collection_cases(company_id,customer_id,technical_reason,created_by) values(c2,customer2,'Prueba aislada',u) returning id into case2_id;
  policy_id:=(public.collection_save_policy_draft(c,'Política fase 3','America/Mexico_City','{1,2,3,4,5}','09:00','18:00','72 hours',3,u,u)->>'id')::uuid;
  perform public.collection_approve_policy(c,policy_id,'Aprobar prueba asistida');
  if (public.collection_generate_assisted_reviews(c,100,null)->>'created')::integer<>1 then raise exception 'No se generó una tarea asistida.';end if;
  perform set_config('request.jwt.claim.role','service_role',true);perform set_config('request.jwt.claim.sub','',true);
  select id into v_task_id from public.collection_claim_tasks('phase3-worker',10,120) where task_type='assisted_review';
  if v_task_id is null then raise exception 'El worker no reclamó la tarea asistida.';end if;
  if public.collection_get_agent_context(v_task_id,'phase3-worker')->'case'->>'balance_snapshot'<>'10.00' then raise exception 'El contexto no conservó el saldo canónico.';end if;
  proposal_id:=(public.collection_record_agent_proposal(v_task_id,'phase3-worker','{"summary":"Saldo pendiente","recommendation":"prepare_contact","channel":"email","draft":"Borrador de prueba"}','[{"source":"receivable","reference":"documento de prueba"}]','Preparar contacto','low','gpt-test','prompt-v1',now()+interval '1 day','{"input_tokens":100,"output_tokens":40,"trace_id":"trace_test"}')->>'id')::uuid;
  perform public.collection_finish_assisted_task(v_task_id,'phase3-worker','gpt-test','prompt-v1',100,40,0.000255,'trace_test','{"requests":1}');
  if not exists(select 1 from public.collection_executions e where e.task_id=v_task_id and e.input_tokens=100 and e.output_tokens=40 and e.estimated_cost_usd=0.000255 and e.provider_trace_id='trace_test') then raise exception 'No persistió la telemetría asistida.';end if;
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);
  listed:=public.collection_list_proposals(c,'pending',1,25);
  if jsonb_array_length(listed->'items')<>1 or listed->'items'->0 ? 'model' or listed->'items'->0 ? 'evidence' then raise exception 'La bandeja expuso metadatos técnicos: %',listed;end if;
  perform public.collection_decide_proposal(c,proposal_id,'approve','Aprobación humana',null,null);
  update public.customer_receivables set outstanding_amount=9 where sale_id=v_sale_id;
  begin perform public.collection_apply_proposal(c,proposal_id,'Aplicar con saldo cambiado');exception when others then blocked:=position('cambió' in sqlerrm)>0;end;
  if not blocked then raise exception 'Se aplicó una propuesta con saldo cambiado.';end if;
  update public.customer_receivables set outstanding_amount=10 where sale_id=v_sale_id;
  perform public.collection_apply_proposal(c,proposal_id,'Aplicación humana comprobada');
  blocked:=false;begin perform public.collection_apply_proposal(c,proposal_id,'Aplicación concurrente');exception when others then blocked:=position('no disponible' in sqlerrm)>0;end;
  if not blocked then raise exception 'La misma propuesta se aplicó dos veces.';end if;
  detail:=public.collection_get_case(c,case_id);
  if jsonb_array_length(detail->'assistant_history')<>1 or detail->'assistant_history'->0->>'status'<>'applied' then raise exception 'El expediente no reconstruyó el historial asistido: %',detail;end if;
  blocked:=false;begin perform public.collection_list_proposals(c2,'all',1,25);exception when others then blocked:=position('No autorizado' in sqlerrm)>0;end;
  if not blocked then raise exception 'Un usuario consultó propuestas de otra empresa.';end if;
  if has_table_privilege('authenticated','public.collection_proposals','select') or has_table_privilege('authenticated','public.collection_executions','select') or has_table_privilege('authenticated','public.collection_actions','select') then raise exception 'Authenticated conserva lectura directa de tablas técnicas.';end if;
end $test$;

rollback;
