begin;

do $test$
declare
  c uuid:='25030000-0000-4000-8000-000000000001';u uuid:='25030000-0000-4000-8000-000000000002';
  collaborator jsonb;current_period jsonb;detail jsonb;again jsonb;collaborator_id uuid;blocked boolean:=false;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(u,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','payroll-schedule-test@example.invalid','',now(),'{}','{}',now(),now());
  insert into public.companies(id,legal_name,display_name) values(c,'Prueba de nómina','Prueba de nómina');
  insert into public.user_roles(user_id,role_id,company_id) select u,id,c from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);

  collaborator:=public.save_collaborator(c,null,null,'Andrea Prueba','Operaciones','active',current_date-1,null,'weekly',7000,current_date-1,'Alta inicial');
  collaborator_id:=(collaborator->>'id')::uuid;
  perform public.save_payroll_movements_batch(c,jsonb_build_array(jsonb_build_object('collaborator_id',collaborator_id,'movement_type','overtime','direction','addition','effective_on',current_date,'units',4,'amount',800,'description','Horas extra autorizadas')),true);
  if public.save_payroll_schedule(c,'weekly')->>'payment_frequency'<>'weekly' then raise exception 'No se guardó la periodicidad semanal.'; end if;
  current_period:=public.get_current_payroll_period(c);
  if current_period->>'period' is not null or current_period#>>'{proposed,payment_frequency}'<>'weekly' then raise exception 'El periodo vigente no se propuso correctamente: %',current_period; end if;
  detail:=public.start_current_payroll(c);
  again:=public.start_current_payroll(c);
  if detail->>'status'<>'reviewing' or detail->>'id'<>again->>'id' or (detail#>>'{totals,total_pay}')::numeric<=0 then
    raise exception 'La nómina vigente no fue preparada de forma idempotente: %, %',detail,again;
  end if;
  begin
    perform public.save_payroll_schedule(c,'biweekly');
  exception when others then blocked:=position('nómina vigente abierta' in lower(sqlerrm))>0; end;
  if not blocked then raise exception 'Se permitió cambiar periodicidad con nómina vigente abierta.'; end if;
  raise notice 'Calendario de nómina y periodo vigente automáticos aprobados.';
end $test$;

rollback;
