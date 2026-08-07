begin;

do $test$
declare
  c uuid:='26080400-0000-4000-8000-000000000001';u uuid:='26080400-0000-4000-8000-000000000002';
  collaborator_id uuid;historical_id uuid;result jsonb;period_start date;period_end date;movement public.payroll_movements%rowtype;blocked boolean:=false;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(u,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','payroll-retro-test@example.invalid','',now(),'{}','{}',now(),now());
  insert into public.companies(id,legal_name,display_name) values(c,'Nómina retroactiva','Nómina retroactiva');
  insert into public.user_roles(user_id,role_id,company_id) select u,id,c from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);
  collaborator_id:=(public.save_collaborator(c,null,'RETRO-001','Andrea Retro','Operaciones','active',current_date-90,null,'weekly',6000,current_date-90,'Alta inicial')->>'id')::uuid;
  perform public.save_payroll_operational_configuration(c,'weekly',6,8,50);
  select starts_on,ends_on into period_start,period_end from public.payroll_period_bounds('weekly',current_date);
  insert into public.payroll_periods(company_id,payment_frequency,starts_on,ends_on,payment_date,status,prepared_at,approved_at,paid_at)
  values(c,'weekly',period_start-7,period_start-1,period_start-1,'paid',now(),now(),now()) returning id into historical_id;

  begin
    perform public.save_payroll_adjustments_batch(c,'bonus',jsonb_build_array(jsonb_build_object('collaborator_id',collaborator_id,'effective_on',period_start-1,'amount',250)));
  exception when others then blocked:=position('motivo' in lower(sqlerrm))>0;end;
  if not blocked then raise exception 'Una incidencia retroactiva se guardó sin motivo.'; end if;

  result:=public.save_payroll_adjustments_batch(c,'bonus',jsonb_build_array(jsonb_build_object('collaborator_id',collaborator_id,'effective_on',period_start-1,'amount',250,'retroactive_reason','Corrección autorizada de semana cerrada','description','Bono de productividad')));
  select * into movement from public.payroll_movements where id=(result->'movement_ids'->>0)::uuid;
  if movement.occurred_on<>period_start-1 or movement.effective_on<>period_start or movement.origin_payroll_period_id<>historical_id or movement.retroactive_reason<>'Corrección autorizada de semana cerrada' then
    raise exception 'La corrección no conservó origen ni se aplicó al periodo vigente: %',to_jsonb(movement);
  end if;
  if not exists(select 1 from public.audit_log where entity_id=movement.id and action='payroll.bonus_saved' and metadata->>'retroactive_reason'='Corrección autorizada de semana cerrada') then
    raise exception 'La incidencia retroactiva no dejó auditoría individual.';
  end if;
  if public.payroll_payment_state(historical_id)<>'paid' then raise exception 'Una nómina pagada perdió su estado histórico.'; end if;
  if not coalesce((public.get_payroll_period(c,historical_id)->>'has_adjustments')::boolean,false) then raise exception 'La nómina histórica no indica que tiene ajustes.'; end if;
  raise notice 'Retroactividad auditada, nómina cerrada inmutable y estado de pago aprobados.';
end $test$;

rollback;
