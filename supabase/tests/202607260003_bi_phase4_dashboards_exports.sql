-- BI Fase 4: vistas privadas/compartidas, RLS, compatibilidad, layout y exportación.
begin;

do $installation$
begin
  if to_regprocedure('public.bi_save_view(uuid,uuid,text,text,text,jsonb,integer,uuid)') is null then
    raise exception 'Falta BI Fase 4.';
  end if;
  if has_function_privilege('anon','public.bi_prepare_export(uuid,text,uuid,text,jsonb)','execute') then
    raise exception 'anon no debe preparar exportaciones.';
  end if;
end;$installation$;

do $fixtures$
declare
  c1 uuid:='b1400000-0000-4000-8000-000000000001';
  c2 uuid:='b1400000-0000-4000-8000-000000000002';
  u1 uuid:='b1400000-0000-4000-8000-000000000003';
  u2 uuid:='b1400000-0000-4000-8000-000000000004';
begin
  insert into public.companies(id,legal_name,display_name)
  values(c1,'BI Fase 4 A','BI Fase 4 A'),(c2,'BI Fase 4 B','BI Fase 4 B');
  insert into auth.users(id,aud,role,email,encrypted_password)
  values(u1,'authenticated','authenticated','bi-f4-owner@example.com',''),
        (u2,'authenticated','authenticated','bi-f4-viewer@example.com','');
  insert into public.user_roles(user_id,role_id,company_id)
  select users.id,roles.id,c1
  from(values(u1),(u2))users(id)
  cross join lateral(select id from public.roles where code='direccion_admin')roles;
  insert into public.payroll_periods(company_id,payment_frequency,starts_on,ends_on,payment_date,status,prepared_at,approved_at)
  select c1,'weekly',date'2026-01-01'+n,date'2026-01-01'+n,date'2026-01-01'+n,'approved',now(),now()
  from generate_series(0,149)n;
end;$fixtures$;

set local role authenticated;

do $assertions$
declare
  c1 constant uuid:='b1400000-0000-4000-8000-000000000001';
  c2 constant uuid:='b1400000-0000-4000-8000-000000000002';
  u1 constant uuid:='b1400000-0000-4000-8000-000000000003';
  u2 constant uuid:='b1400000-0000-4000-8000-000000000004';
  definition jsonb:='{"metric_codes":["payroll_runs"],"dimension":"period","visualization":"line","date_from":"2026-01-01","date_to":"2026-05-30","compare_previous":true,"order_by":"current_desc"}';
  incompatible jsonb:='{"metric_codes":["tickets","payroll_runs"],"dimension":"period","visualization":"line","date_from":"2026-01-01","date_to":"2026-05-30","compare_previous":true}';
  saved jsonb;listed jsonb;dashboard jsonb;widget jsonb;snapshot jsonb;prepared jsonb;
  view_id uuid;dashboard_id uuid;blocked boolean;index integer;
begin
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',u1::text,true);
  saved:=public.bi_save_view(c1,null,'Nómina privada','Prueba','private',definition,null,gen_random_uuid());
  view_id:=(saved->>'id')::uuid;

  perform set_config('request.jwt.claim.sub',u2::text,true);
  listed:=public.bi_list_saved_views(c1,1,999);
  if (listed->'pagination'->>'page_size')::integer<>100 then raise exception 'No se limitó la página server-side.';end if;
  if exists(select 1 from jsonb_array_elements(listed->'items')x where x->>'id'=view_id::text)then
    raise exception 'Una vista privada fue visible para otro usuario.';
  end if;

  perform set_config('request.jwt.claim.sub',u1::text,true);
  saved:=public.bi_save_view(c1,view_id,'Nómina compartida','Prueba','company',definition,1,gen_random_uuid());
  if (saved->>'current_version')::integer<>2 then raise exception 'La vista no se versionó.';end if;

  perform set_config('request.jwt.claim.sub',u2::text,true);
  listed:=public.bi_list_saved_views(c1,1,25);
  if not exists(select 1 from jsonb_array_elements(listed->'items')x where x->>'id'=view_id::text)then
    raise exception 'La vista compartida no fue visible en la empresa.';
  end if;
  blocked:=false;
  begin perform public.bi_list_saved_views(c2,1,25);
  exception when others then blocked:=position('No autorizado' in sqlerrm)>0;end;
  if not blocked then raise exception 'Se permitió leer vistas de otra empresa.';end if;

  blocked:=false;
  begin perform public.bi_save_view(c1,null,'Inválida',null,'private',incompatible,null,gen_random_uuid());
  exception when others then blocked:=position('granularidad' in sqlerrm)>0;end;
  if not blocked then raise exception 'Se guardó una combinación incompatible.';end if;

  dashboard:=public.bi_save_dashboard(c1,null,'Operación',null,null);
  dashboard_id:=(dashboard->>'id')::uuid;
  for index in 1..12 loop
    widget:=public.bi_add_dashboard_widget(c1,dashboard_id,view_id,case when index=1 then'kpi'else'chart'end,null,'inherit');
  end loop;
  blocked:=false;
  begin perform public.bi_add_dashboard_widget(c1,dashboard_id,view_id,'table',null,'inherit');
  exception when others then blocked:=position('12 widgets' in sqlerrm)>0;end;
  if not blocked then raise exception 'No se aplicó el límite de widgets.';end if;

  snapshot:=public.bi_get_dashboard_snapshot(c1,dashboard_id,'{"date_from":"2026-01-01","date_to":"2026-05-30"}');
  if jsonb_array_length(snapshot->'widgets')<>12 then raise exception 'Snapshot coordinado incompleto.';end if;
  if exists(select 1 from jsonb_array_elements(snapshot->'widgets')x where x->>'status'<>'ready')then
    raise exception 'Un widget válido falló: %',snapshot;
  end if;

  prepared:=public.bi_prepare_export(c1,'dashboard',dashboard_id,'xlsx','{"date_from":"2026-01-01","date_to":"2026-05-30"}');
  if jsonb_array_length(prepared->'configs')<>12 then raise exception 'Exportación no reconstruyó el tablero.';end if;
  perform public.bi_finish_export((prepared->>'job_id')::uuid,'completed',150,4096,'{"test":true}');
  if not exists(select 1 from public.bi_export_jobs where id=(prepared->>'job_id')::uuid and requested_by=u2 and status='completed')then
    raise exception 'No quedó trazabilidad canónica de la exportación.';
  end if;

  if not exists(select 1 from public.audit_log where company_id=c1 and action='bi.view_shared' and entity_id=view_id)then
    raise exception 'No se auditó la compartición.';
  end if;
  if not exists(select 1 from public.audit_log where company_id=c1 and action='bi.export_completed' and entity_id=(prepared->>'job_id')::uuid)then
    raise exception 'No se auditó el resultado de exportación.';
  end if;
end;$assertions$;

reset role;
rollback;
