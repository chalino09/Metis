begin;

do $test$
declare c uuid:='81200000-0000-4000-8000-000000000101';u uuid:='81200000-0000-4000-8000-000000000102';customer uuid:='81200000-0000-4000-8000-000000000103';v_case_id uuid;policy_id uuid;blocked boolean:=false;listed jsonb;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values(u,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','collection-phase2@example.invalid','',now(),'{}','{}',now(),now());
  insert into public.companies(id,legal_name,display_name) values(c,'Cobranza fase 2','Cobranza fase 2');
  insert into public.user_roles(user_id,role_id,company_id) select u,id,c from public.roles where code='direccion_admin';
  insert into public.customers(id,company_id,code,display_name,credit_enabled,credit_limit,credit_term_days,is_active,created_by) values(customer,c,'C-F2','Cliente fase 2',true,100,30,true,u);
  insert into public.collection_cases(company_id,customer_id,technical_reason,created_by) values(c,customer,'Prueba operativa',u) returning id into v_case_id;
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);
  begin perform public.collection_schedule_action(c,v_case_id,now()+interval '1 day','Debe bloquearse sin política',u);exception when others then blocked:=position('no configurada' in lower(sqlerrm))>0;end;
  if not blocked then raise exception 'Una empresa no configurada pudo operar cobranza.';end if;
  policy_id:=(public.collection_save_policy_draft(c,'Política fase 2','America/Mexico_City','{1,2,3,4,5}','09:00','18:00','72 hours',3,u,u)->>'id')::uuid;
  perform public.collection_approve_policy(c,policy_id,'Autorizar prueba de operaciones');
  perform public.collection_schedule_action(c,v_case_id,now()+interval '1 day','Seguimiento comprometido',u);
  if not exists(select 1 from public.collection_cases where id=v_case_id and assigned_to=u and next_action_at is not null and next_action_reason='Seguimiento comprometido') then raise exception 'No persistió fecha, motivo y responsable.';end if;
  listed:=public.collection_list_cases(c,'open',null,1,25);
  if jsonb_array_length(listed->'items')<>1 then raise exception 'La bandeja agrupada no devolvió el caso.';end if;
  perform public.collection_escalate_case(c,v_case_id,'Disputa declarada',u);
  if(select status from public.collection_cases where id=v_case_id)<>'requires_human' then raise exception 'El escalamiento no detuvo la gestión automática.';end if;
  perform public.collection_close_case(c,v_case_id,'Cierre manual comprobado');
  if not exists(select 1 from public.collection_cases where id=v_case_id and status='closed' and closed_reason='Cierre manual comprobado') then raise exception 'El cierre no conservó motivo.';end if;
  if(select count(*) from public.collection_actions a where a.case_id=v_case_id)<>3 then raise exception 'La cronología no conservó las tres acciones.';end if;
end $test$;

rollback;
