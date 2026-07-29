begin;

do $test$
declare
  c uuid:='25010000-0000-4000-8000-000000000001';u uuid:='25010000-0000-4000-8000-000000000002';
  collaborator jsonb;period jsonb;detail jsonb;collaborator_id uuid;period_id uuid;blocked boolean:=false;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(u,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','payroll-test@example.invalid','',now(),'{}','{}',now(),now());
  insert into public.companies(id,legal_name,display_name) values(c,'Nómina de prueba','Nómina de prueba');
  insert into public.user_roles(user_id,role_id,company_id) select u,id,c from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);

  collaborator:=public.save_collaborator(c,null,'COL-001','Andrea Prueba','Operaciones','active','2026-07-01',null,'weekly',7000,'2026-07-01','Alta inicial');
  collaborator_id:=(collaborator->>'id')::uuid;
  if collaborator->>'code'<>'COL-000001' or collaborator->>'employment_status'<>'active' or collaborator->>'terminated_at' is not null then
    raise exception 'El alta no generó código canónico activo y sin baja: %',collaborator;
  end if;
  perform public.save_payroll_movements_batch(c,jsonb_build_array(jsonb_build_object('collaborator_id',collaborator_id,'movement_type','overtime','direction','addition','effective_on','2026-07-24','units',4,'amount',800,'description','Horas extra autorizadas')),true);
  period:=public.save_payroll_period(c,null,'weekly','2026-07-20','2026-07-26','2026-07-27','Semana de prueba');period_id:=(period->>'id')::uuid;
  detail:=public.prepare_payroll_period(c,period_id);
  if detail->>'status'<>'reviewing' or (detail#>>'{totals,total_pay}')::numeric<>7800 then raise exception 'La preparación no consolidó pago base y horas extra: %',detail;end if;
  detail:=public.advance_payroll_period(c,period_id,'approve',null);
  if detail->>'status'<>'approved' then raise exception 'La corrida no quedó aprobada: %',detail;end if;
  begin
    perform public.save_payroll_movements_batch(c,jsonb_build_array(jsonb_build_object('id',(select payroll_movement_id from public.payroll_period_line_concepts where payroll_period_line_id=(select id from public.payroll_period_lines where payroll_period_id=period_id limit 1) and payroll_movement_id is not null),'collaborator_id',collaborator_id,'movement_type','overtime','direction','addition','effective_on','2026-07-24','units',4,'amount',900,'description','No debe editarse')),true);
  exception when others then blocked:=position('aprobada o pagada' in lower(sqlerrm))>0;end;
  if not blocked then raise exception 'Un movimiento ya aprobado se pudo editar.';end if;
  detail:=public.set_payroll_line_payment_method(c,(select id from public.payroll_period_lines where payroll_period_id=period_id limit 1),'transfer');
  detail:=public.record_payroll_payment_batch(c,period_id,'transfer','2026-07-27','TRF-0001');
  if detail->>'status'<>'paid' or not exists(select 1 from jsonb_array_elements(detail->'payment_batches') batch where batch->>'payment_method'='transfer' and batch->>'payment_reference'='TRF-0001') then raise exception 'El pago no quedó cerrado y referenciado por método: %',detail;end if;
  if (public.search_collaborators(c,'andrea','active',1,50)#>>'{pagination,total}')::int<>1 then raise exception 'El directorio paginado no encontró el colaborador.';end if;
  raise notice 'Colaboradores: historial salarial, movimiento aprobado, corrida semanal, cierre e inmutabilidad aprobados.';
end $test$;

rollback;
