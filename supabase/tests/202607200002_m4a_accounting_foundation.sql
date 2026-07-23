begin;

do $m4a$
declare
  v_company uuid:='4a000000-0000-4000-8000-000000000001';
  v_other uuid:='4a000000-0000-4000-8000-000000000002';
  v_accountant uuid:='4a000000-0000-4000-8000-000000000010';
  v_reopener uuid:='4a000000-0000-4000-8000-000000000011';
  v_outsider uuid:='4a000000-0000-4000-8000-000000000012';
  v_chart uuid;v_trial uuid;v_config uuid;v_period uuid;v_entry uuid;v_adjust uuid;v_asset uuid;v_equity uuid;v_result jsonb;
  v_controls jsonb;v_rows jsonb;v_forbidden boolean:=false;v_hash text:=repeat('a',64);
begin
  if to_regprocedure('public.promote_accounting_import(uuid,uuid)') is null
    or to_regprocedure('public.change_accounting_period_status(uuid,text,text)') is null then
    raise exception 'Faltan RPC de M4A.';
  end if;
  if has_table_privilege('authenticated','public.accounting_journal_entries','insert')
    or has_table_privilege('authenticated','public.accounting_import_rows','update')
    or has_function_privilege('anon','public.promote_accounting_import(uuid,uuid)','execute') then
    raise exception 'M4A expone escrituras directas o RPC a anon.';
  end if;
  insert into public.companies(id,legal_name,display_name) values(v_company,'M4A temporal','M4A temporal'),(v_other,'Ajena M4A','Ajena M4A');
  insert into auth.users(id,aud,role,email,encrypted_password) values
    (v_accountant,'authenticated','authenticated','contador-m4a@example.com',''),
    (v_reopener,'authenticated','authenticated','reapertura-m4a@example.com',''),
    (v_outsider,'authenticated','authenticated','ajeno-m4a@example.com','');
  insert into public.user_roles(user_id,role_id,company_id)
  select v_accountant,id,v_company from public.roles where code='direccion_admin'
  union all select v_reopener,id,v_company from public.roles where code='super_admin'
  union all select v_outsider,id,v_other from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_accountant::text,true);

  v_result:=public.create_accounting_import_staging(v_company,'chart_of_accounts',date '2026-06-30','MXN','{"format":"4 digits","segments":[4]}','{"cutoffDate":{"status":"detected"},"currency":{"status":"detected"},"catalogStructure":{"status":"detected"}}','[]','catalogo.xlsx',v_hash);
  v_chart:=(v_result->>'id')::uuid;
  v_rows:='[
    {"row_number":1,"external_account_code":"1000","account_name":"Activo","account_type":"asset","normal_balance":"debit","accepts_posting":false},
    {"row_number":2,"external_account_code":"1100","account_name":"Activo fijo","parent_external_code":"1000","account_type":"asset","normal_balance":"debit","accepts_posting":true},
    {"row_number":3,"external_account_code":"2000","account_name":"Pasivo","account_type":"liability","normal_balance":"credit","accepts_posting":true},
    {"row_number":4,"external_account_code":"3000","account_name":"Capital","account_type":"equity","normal_balance":"credit","accepts_posting":true},
    {"row_number":5,"external_account_code":"1010","account_name":"CxC control","account_type":"asset","normal_balance":"debit","accepts_posting":true},
    {"row_number":6,"external_account_code":"2010","account_name":"CxP control","account_type":"liability","normal_balance":"credit","accepts_posting":true},
    {"row_number":7,"external_account_code":"1020","account_name":"Inventario control","account_type":"asset","normal_balance":"debit","accepts_posting":true},
    {"row_number":8,"external_account_code":"1030","account_name":"Caja control","account_type":"asset","normal_balance":"debit","accepts_posting":true},
    {"row_number":9,"external_account_code":"1040","account_name":"Bancos control","account_type":"asset","normal_balance":"debit","accepts_posting":true},
    {"row_number":10,"external_account_code":"1050","account_name":"IVA pendiente","account_type":"asset","normal_balance":"debit","accepts_posting":true},
    {"row_number":11,"external_account_code":"2020","account_name":"IVA cobrado","account_type":"liability","normal_balance":"credit","accepts_posting":true},
    {"row_number":12,"external_account_code":"1060","account_name":"IVA pagado","account_type":"asset","normal_balance":"debit","accepts_posting":true},
    {"row_number":13,"external_account_code":"2030","account_name":"Retenciones","account_type":"liability","normal_balance":"credit","accepts_posting":true}
  ]'::jsonb;
  perform public.stage_accounting_import_rows(v_chart,v_rows);
  v_result:=public.validate_accounting_import(v_chart,'external');
  if v_result->>'status'<>'staged' then raise exception 'Catálogo no validó: %',v_result;end if;
  v_result:=public.save_accounting_config(v_company,'MXN',date '2026-06-30',
    '{"format":"4 digits","segments":[4]}'::jsonb,
    '{"vat_pending":"separate","vat_collected":"on_collection","vat_paid":"on_payment","withholdings":"separate"}'::jsonb,
    jsonb_build_object('adjustments',v_accountant,'close',v_accountant,'reopen',v_reopener),
    'Base confirmada antes del catálogo','{}');v_config:=(v_result->>'id')::uuid;
  v_result:=public.promote_accounting_import(v_chart,gen_random_uuid());
  if (v_result->>'accounts_promoted')::int<>13 then raise exception 'Promoción de catálogo incompleta.';end if;
  v_result:=public.create_accounting_import_staging(v_company,'chart_of_accounts',date '2026-06-30','MXN','{"format":"4 digits","segments":[4]}','{}','[]','catalogo-copia.xlsx',v_hash);
  if coalesce((v_result->>'idempotent')::boolean,false)=false or (v_result->>'id')::uuid<>v_chart then raise exception 'Catálogo duplicado no fue idempotente.';end if;

  select jsonb_object_agg(k,a.id) into v_controls from (values
    ('accounts_receivable','1010'),('accounts_payable','2010'),('inventory','1020'),('cash','1030'),('banks','1040'),
    ('vat_pending','1050'),('vat_collected','2020'),('vat_paid','1060'),('withholdings','2030')
  )x(k,code) join public.accounting_accounts a on a.company_id=v_company and a.code=x.code;
  v_result:=public.complete_accounting_config(v_config,v_controls,'Configuración aprobada por responsable contable para prueba controlada');
  if v_result->>'status'<>'approved' then raise exception 'Configuración completa reportada incompleta.';end if;
  v_result:=public.create_accounting_period(v_company,'2026-06',date '2026-06-01',date '2026-06-30');v_period:=(v_result->>'id')::uuid;

  v_hash:=repeat('b',64);
  v_result:=public.create_accounting_import_staging(v_company,'trial_balance',date '2026-06-30','MXN','{}','{"cutoffDate":{"status":"detected"},"currency":{"status":"detected"}}','[]','balanza.xlsx',v_hash);v_trial:=(v_result->>'id')::uuid;
  perform public.stage_accounting_import_rows(v_trial,'[
    {"row_number":1,"external_account_code":"1100","account_name":"Activo fijo","debit":100,"credit":0},
    {"row_number":2,"external_account_code":"3000","account_name":"Capital","debit":0,"credit":100}
  ]'::jsonb);
  v_result:=public.validate_accounting_import(v_trial,'external');
  if v_result->>'status'<>'staged' or (select count(*) from public.accounting_auxiliary_comparisons where batch_id=v_trial)<>9 then raise exception 'Balanza/auxiliares no validaron: %',v_result;end if;
  v_result:=public.promote_accounting_import(v_trial,'4a000000-0000-4000-8000-000000000020');v_entry:=(v_result->>'entry_id')::uuid;
  if (select status from public.accounting_journal_entries where id=v_entry)<>'posted'
    or not (select immutable from public.accounting_journal_entries where id=v_entry)
    or (select sum(debit) from public.accounting_journal_lines where journal_entry_id=v_entry)<>100
    or (select sum(credit) from public.accounting_journal_lines where journal_entry_id=v_entry)<>100 then raise exception 'Póliza de apertura inválida.';end if;
  v_result:=public.promote_accounting_import(v_trial,'4a000000-0000-4000-8000-000000000020');
  if coalesce((v_result->>'idempotent')::boolean,false)=false or (select count(*) from public.accounting_journal_entries where source_batch_id=v_trial)<>1 then raise exception 'Promoción de apertura no idempotente.';end if;
  begin update public.accounting_journal_lines set debit=99 where journal_entry_id=v_entry and debit>0;exception when others then v_forbidden:=position('inmutable' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'La póliza de apertura pudo modificarse.';end if;v_forbidden:=false;

  select id into v_asset from public.accounting_accounts where company_id=v_company and code='1100';
  select id into v_equity from public.accounting_accounts where company_id=v_company and code='3000';
  v_result:=public.post_accounting_adjustment(v_company,date '2026-06-30','Ajuste controlado de prueba',jsonb_build_array(
    jsonb_build_object('line_number',1,'account_id',v_asset,'debit',5,'credit',0),
    jsonb_build_object('line_number',2,'account_id',v_equity,'debit',0,'credit',5)
  ),'4a000000-0000-4000-8000-000000000021');v_adjust:=(v_result->>'id')::uuid;
  v_result:=public.post_accounting_adjustment(v_company,date '2026-06-30','Ignorado por idempotencia',jsonb_build_array(
    jsonb_build_object('line_number',1,'account_id',v_asset,'debit',5,'credit',0),jsonb_build_object('line_number',2,'account_id',v_equity,'debit',0,'credit',5)
  ),'4a000000-0000-4000-8000-000000000021');
  if coalesce((v_result->>'idempotent')::boolean,false)=false or (select count(*) from public.accounting_journal_entries where id=v_adjust)<>1 then raise exception 'Ajuste no fue idempotente.';end if;

  perform public.change_accounting_period_status(v_period,'close','Control de periodo M4A');
  if (select status from public.accounting_periods where id=v_period)<>'closed' then raise exception 'M4A no cerró el periodo.';end if;
  perform set_config('request.jwt.claim.sub',v_reopener::text,true);
  perform public.change_accounting_period_status(v_period,'reopen','Corrección auditada M4A');
  if (select status from public.accounting_periods where id=v_period)<>'open' then raise exception 'M4A no reabrió el periodo.';end if;

  perform set_config('request.jwt.claim.sub',v_outsider::text,true);
  begin perform public.create_accounting_import_batch(v_company,'trial_balance',date '2026-06-30','MXN','ajena.xlsx',repeat('c',64));exception when others then v_forbidden:=position('no autorizado' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Usuario de empresa ajena creó staging.';end if;
  if not exists(select 1 from public.audit_log where company_id=v_company and action='accounting.opening_posted') then raise exception 'Falta auditoría de apertura.';end if;
  raise notice 'M4A: configuración versionada, catálogo, conciliación, apertura balanceada/inmutable, idempotencia, RLS y control de periodo aprobados.';
end;
$m4a$;

rollback;
