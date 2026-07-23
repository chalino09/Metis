begin;
do $m4a_staging_first$
declare v_company uuid:='4a040000-0000-4000-8000-000000000001';v_user uuid:='4a040000-0000-4000-8000-000000000010';v_batch uuid;v_result jsonb;v_blocked boolean:=false;
begin
  if to_regprocedure('public.create_accounting_import_staging(uuid,text,date,text,jsonb,jsonb,jsonb,text,text)') is null or to_regprocedure('public.finalize_accounting_staging(uuid,text)') is null then raise exception 'Faltan RPC de staging primero.';end if;
  if has_function_privilege('anon','public.create_accounting_import_staging(uuid,text,date,text,jsonb,jsonb,jsonb,text,text)','execute') then raise exception 'anon puede crear staging contable.';end if;
  insert into public.companies(id,legal_name,display_name) values(v_company,'M4A staging','M4A staging');
  insert into auth.users(id,aud,role,email,encrypted_password) values(v_user,'authenticated','authenticated','m4a-staging@example.com','');
  insert into public.user_roles(user_id,role_id,company_id) select v_user,id,v_company from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',v_user::text,true);

  v_result:=public.create_accounting_import_staging(v_company,'chart_of_accounts',date '2026-07-08','MXN','{"format":"4","segments":[4]}','{"cutoffDate":{"status":"detected","value":"2026-07-08"}}','[]','catalogo.xlsx',repeat('c',64));v_batch:=(v_result->>'id')::uuid;
  perform public.stage_accounting_import_rows(v_batch,'[{"row_number":1,"external_account_code":"1000","account_name":"Activo","account_type":"asset","normal_balance":"debit","accepts_posting":true}]');
  v_result:=public.finalize_accounting_staging(v_batch,'external');
  if v_result->>'status'<>'staged' then raise exception 'El catálogo no quedó en staging antes de configurar: %',v_result;end if;
  v_result:=public.create_accounting_import_staging(v_company,'chart_of_accounts',date '2026-07-08','MXN','{"format":"4","segments":[4]}','{}','[]','catalogo-copia.xlsx',repeat('c',64));
  if not coalesce((v_result->>'idempotent')::boolean,false) or (v_result->>'id')::uuid<>v_batch then raise exception 'El staging contable no fue idempotente.';end if;

  v_result:=public.create_accounting_import_staging(v_company,'trial_balance',null,null,'{}','{}','[{"field":"cutoffDate","status":"missing"}]','balanza-sin-corte.xlsx',repeat('d',64));v_batch:=(v_result->>'id')::uuid;
  perform public.stage_accounting_import_rows(v_batch,'[{"row_number":1,"external_account_code":"1000","debit":10,"credit":0},{"row_number":2,"external_account_code":"3000","debit":0,"credit":10}]');
  v_result:=public.finalize_accounting_staging(v_batch,'external');
  if v_result->>'status'<>'awaiting_metadata' then raise exception 'La falta de fecha/moneda no quedó en revisión: %',v_result;end if;

  begin perform public.create_accounting_period(v_company,'2026-07',date '2026-07-01',date '2026-07-31');exception when others then v_blocked:=position('aprueba la configuración' in lower(sqlerrm))>0;end;
  if not v_blocked then raise exception 'El servidor permitió crear periodo antes de catálogo/configuración.';end if;
  raise notice 'M4A staging-first: carga previa, evidencia pendiente, idempotencia y gate de periodo validados.';
end;$m4a_staging_first$;
rollback;
