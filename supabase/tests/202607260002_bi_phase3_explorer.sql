-- BI Fase 3: permisos, aislamiento, compatibilidad y paginación/volumen.
begin;

do $installation$
begin
  if to_regprocedure('public.bi_get_metric_catalog(uuid)') is null then raise exception 'Falta catálogo BI.';end if;
  if to_regprocedure('public.bi_explorer_query(uuid,text[],text,text,date,date,uuid,uuid,uuid,uuid,boolean,integer,integer)') is null then raise exception 'Falta consulta BI.';end if;
  if not has_function_privilege('authenticated','public.bi_explorer_query(uuid,text[],text,text,date,date,uuid,uuid,uuid,uuid,boolean,integer,integer)','execute') then raise exception 'authenticated no puede consultar BI.';end if;
  if has_function_privilege('anon','public.bi_explorer_query(uuid,text[],text,text,date,date,uuid,uuid,uuid,uuid,boolean,integer,integer)','execute') then raise exception 'anon no debe consultar BI.';end if;
end;$installation$;

do $fixtures$
declare
  c1 uuid:='b1300000-0000-4000-8000-000000000001';
  c2 uuid:='b1300000-0000-4000-8000-000000000002';
  u1 uuid:='b1300000-0000-4000-8000-000000000003';
begin
  insert into public.companies(id,legal_name,display_name) values(c1,'BI Explorer A','BI Explorer A'),(c2,'BI Explorer B','BI Explorer B');
  insert into auth.users(id,aud,role,email,encrypted_password) values(u1,'authenticated','authenticated','bi-explorer@example.com','');
  insert into public.user_roles(user_id,role_id,company_id) select u1,id,c1 from public.roles where code='direccion_admin';
  insert into public.locations(id,company_id,external_code,name,location_type,classification_source,is_active)
  values('b1300000-0000-4000-8000-000000000010',c1,'A-1','Ubicación A','sucursal','manual_review',true),
        ('b1300000-0000-4000-8000-000000000011',c2,'B-1','Ubicación B','sucursal','manual_review',true);
  insert into public.payroll_periods(company_id,payment_frequency,starts_on,ends_on,payment_date,status,prepared_at,approved_at)
  select c1,'weekly',date '2026-01-01'+n,date '2026-01-01'+n,date '2026-01-01'+n,'approved',now(),now()
  from generate_series(0,149)n;
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',u1::text,true);
end;$fixtures$;

set local role authenticated;

do $assertions$
declare r jsonb;blocked boolean:=false;
begin
  r:=public.bi_get_metric_catalog('b1300000-0000-4000-8000-000000000001');
  if jsonb_array_length(r->'metrics')<16 then raise exception 'Catálogo incompleto: %',r;end if;

  begin perform public.bi_get_metric_catalog('b1300000-0000-4000-8000-000000000002');
  exception when others then blocked:=position('No autorizado' in sqlerrm)>0;end;
  if not blocked then raise exception 'Se permitió consultar otra empresa.';end if;

  blocked:=false;
  begin perform public.bi_explorer_query(
    'b1300000-0000-4000-8000-000000000001',array['payroll_runs'],'period','line','2026-01-01','2026-05-30',
    'b1300000-0000-4000-8000-000000000011',null,null,null,true,1,25);
  exception when others then blocked:=position('Ubicación no disponible' in sqlerrm)>0;end;
  if not blocked then raise exception 'Se permitió una ubicación de otra empresa.';end if;

  blocked:=false;
  begin perform public.bi_explorer_query(
    'b1300000-0000-4000-8000-000000000001',array['tickets','payroll_runs'],'period','line','2026-01-01','2026-05-30',
    null,null,null,null,true,1,25);
  exception when others then blocked:=position('granularidad' in sqlerrm)>0;end;
  if not blocked then raise exception 'Se permitió mezclar granularidades.';end if;

  r:=public.bi_explorer_query(
    'b1300000-0000-4000-8000-000000000001',array['payroll_runs'],'period','line','2026-01-01','2026-05-30',
    null,null,null,null,true,1,999);
  if (r->'pagination'->>'total')::integer<>150 then raise exception 'Total de volumen incorrecto: %',r->'pagination';end if;
  if (r->'pagination'->>'page_size')::integer<>100 or jsonb_array_length(r->'items')<>100 then raise exception 'No se respetó el límite server-side: %',r->'pagination';end if;
  if jsonb_array_length(r->'chart')<>120 then raise exception 'La gráfica descargó más o menos de 120 agregados: %',jsonb_array_length(r->'chart');end if;
end;$assertions$;

reset role;
rollback;
