begin;

do $test$
declare
  c uuid:='82300004-0000-4000-8000-000000000001';
  u uuid:='82300004-0000-4000-8000-000000000002';
  collaborator_id uuid:='82300004-0000-4000-8000-000000000003';
  result jsonb;position_result jsonb;blocked boolean:=false;
begin
  insert into public.companies(id,legal_name,display_name,product_experience_code)
  values(c,'Restaurante horarios E2E','Restaurante horarios E2E','restaurant');
  insert into auth.users(id,aud,role,email,encrypted_password)
  values(u,'authenticated','authenticated','restaurant-schedules@example.invalid','');
  insert into public.user_roles(user_id,role_id,company_id)
  select u,id,c from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',u::text,true);

  insert into public.collaborators(id,company_id,code,display_name,hired_at,payment_frequency)
  values(collaborator_id,c,'COL-HORARIO','Leticia Gómez Huerta',current_date,'weekly');

  position_result:=public.create_collaborator_position(c,'Cocinera');
  if position_result->>'name'<>'Cocinera' then raise exception 'No se creó el puesto: %',position_result;end if;

  result:=public.save_collaborator_weekly_schedule(c,collaborator_id,current_date,
    jsonb_build_array(
      jsonb_build_object('weekday',1,'start_time','08:00','end_time','18:00','break_minutes',0),
      jsonb_build_object('weekday',2,'start_time','08:00','end_time','18:00','break_minutes',0),
      jsonb_build_object('weekday',3,'start_time','08:00','end_time','18:00','break_minutes',0),
      jsonb_build_object('weekday',4,'start_time','08:00','end_time','18:00','break_minutes',0),
      jsonb_build_object('weekday',5,'start_time','08:00','end_time','18:00','break_minutes',0),
      jsonb_build_object('weekday',6,'start_time','08:00','end_time','16:00','break_minutes',0)
    ),'Horario habitual de apertura');
  if result#>>'{current,version_number}'<>'1' or result#>>'{current,weekly_minutes}'<>'3480'
    or jsonb_array_length(result#>'{current,days}')<>6 then
    raise exception 'El primer horario no quedó completo: %',result;
  end if;

  result:=public.save_collaborator_weekly_schedule(c,collaborator_id,current_date+7,
    jsonb_build_array(jsonb_build_object('weekday',1,'start_time','20:00','end_time','02:00','break_minutes',30)),
    'Turno nocturno temporal');
  if result#>>'{current,version_number}'<>'2' or result#>>'{current,weekly_minutes}'<>'330'
    or jsonb_array_length(result->'history')<>2 then
    raise exception 'La segunda vigencia no conservó historial o turno nocturno: %',result;
  end if;

  begin
    perform public.save_collaborator_weekly_schedule(c,collaborator_id,current_date,
      jsonb_build_array(jsonb_build_object('weekday',1,'start_time','08:00','end_time','09:00','break_minutes',60)),
      'Debe fallar');
  exception when others then blocked:=position('descanso debe ser menor' in lower(sqlerrm))>0;end;
  if not blocked then raise exception 'Se aceptó un descanso igual a la jornada.';end if;

  if not exists(select 1 from public.audit_log where company_id=c and action='collaborator.weekly_schedule_created' and entity_id=collaborator_id)
  then raise exception 'El horario no dejó auditoría.';end if;
end $test$;

rollback;
