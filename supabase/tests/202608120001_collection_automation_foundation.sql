begin;

do $test$
declare c uuid:='81200000-0000-4000-8000-000000000001';u uuid:='81200000-0000-4000-8000-000000000002';customer uuid:='81200000-0000-4000-8000-000000000003';case_id uuid;v_task_id uuid;policy_id uuid;claimed integer;blocked boolean:=false;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values(u,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','collection-test@example.invalid','',now(),'{}','{}',now(),now());
  insert into public.companies(id,legal_name,display_name) values(c,'Cobranza prueba','Cobranza prueba');
  insert into public.user_roles(user_id,role_id,company_id) select u,id,c from public.roles where code='direccion_admin';
  insert into public.customers(id,company_id,code,display_name,credit_enabled,credit_limit,credit_term_days,is_active,created_by) values(customer,c,'C-1','Cliente prueba',true,100,30,true,u);
  insert into public.collection_cases(company_id,customer_id,technical_reason,created_by) values(c,customer,'Prueba durable',u) returning id into case_id;
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);
  begin perform public.collection_enqueue_task(c,case_id,'internal_healthcheck','foundation','Debe bloquearse',now(),0::smallint,'internal','blocked');exception when others then blocked:=position('no configurada' in lower(sqlerrm))>0;end;
  if not blocked then raise exception 'Una empresa no configurada pudo encolar.';end if;
  policy_id:=(public.collection_save_policy_draft(c,'Política de prueba','America/Mexico_City','{1,2,3,4,5}','09:00','18:00','72 hours',2,u,u)->>'id')::uuid;
  perform public.collection_approve_policy(c,policy_id,'Aprobación transaccional de prueba');
  v_task_id:=(public.collection_enqueue_task(c,case_id,'internal_healthcheck','foundation','Validar flujo durable',now(),10::smallint,'internal','phase1-test')->>'id')::uuid;
  if (public.collection_enqueue_task(c,case_id,'internal_healthcheck','foundation','Validar flujo durable',now(),10::smallint,'internal','phase1-test')->>'id')::uuid<>v_task_id then raise exception 'Reintento duplicó tarea.';end if;
  perform set_config('request.jwt.claim.role','service_role',true);perform set_config('request.jwt.claim.sub','',true);
  select count(*) into claimed from public.collection_claim_tasks('worker-a',25,15);if claimed<>1 then raise exception 'Primer worker no reclamó exactamente una tarea.';end if;
  select count(*) into claimed from public.collection_claim_tasks('worker-b',25,15);if claimed<>0 then raise exception 'Segundo worker reclamó la misma tarea.';end if;
  update public.collection_tasks set lease_expires_at=now()-interval '1 second' where id=v_task_id;
  select count(*) into claimed from public.collection_claim_tasks('worker-b',25,15);if claimed<>1 then raise exception 'Lease expirado no liberó la tarea.';end if;
  perform public.collection_finish_task(v_task_id,'worker-b',true,'{"ok":true}',null);
  if(select count(*) from public.collection_actions action where action.task_id=v_task_id)<>1 then raise exception 'La ejecución no produjo una acción única.';end if;
end $test$;

rollback;
