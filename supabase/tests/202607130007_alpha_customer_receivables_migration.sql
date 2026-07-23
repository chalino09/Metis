-- Satrapy · Alpha Clientes/CxC migration regression.
-- Run after migration 202607130007. All fixtures are rolled back.
begin;

do $contract$
declare v_definition text;
begin
  foreach v_definition in array array[
    'public.begin_alpha_customer_migration(uuid,date,text,jsonb)',
    'public.stage_alpha_customer_migration_rows(uuid,text,jsonb)',
    'public.declare_alpha_customer_opening_balance(uuid,text,numeric,text,text)',
    'public.reconcile_alpha_customer_migration(uuid)',
    'public.promote_alpha_customer_migration_chunk(uuid,integer)',
    'public.request_alpha_customer_migration_adjustment(uuid,uuid,uuid,text,jsonb,text,text)',
    'public.decide_alpha_customer_migration_adjustment(uuid,boolean,text)',
    'public.fail_alpha_customer_migration(uuid,text)'
  ] loop
    if to_regprocedure(v_definition) is null then
      raise exception 'Falta la RPC de migración Alpha: %', v_definition;
    end if;
  end loop;

  if not exists (select 1 from pg_class where oid = 'public.alpha_customer_migration_batches'::regclass)
    or not exists (select 1 from pg_class where oid = 'public.alpha_customer_migration_documents'::regclass)
    or not exists (select 1 from pg_class where oid = 'public.alpha_customer_migration_adjustments'::regclass) then
    raise exception 'Faltan tablas de staging, documentos o ajustes Alpha.';
  end if;

  if not exists (select 1 from pg_indexes where schemaname='public' and indexname='customer_receivables_alpha_document_key') then
    raise exception 'Falta la clave única reforzada de documentos Alpha.';
  end if;

  select pg_get_functiondef('public.prevent_receivable_document_mutation()'::regprocedure) into v_definition;
  if position('source_document_key' in v_definition) = 0 or position('source_row_hash' in v_definition) = 0 then
    raise exception 'La inmutabilidad de CxC no cubre la fuente Alpha.';
  end if;

  if has_table_privilege('authenticated', 'public.alpha_customer_migration_customers', 'insert')
    or has_table_privilege('authenticated', 'public.alpha_customer_migration_documents', 'update') then
    raise exception 'Staging Alpha no debe admitir escritura directa de authenticated.';
  end if;
end;
$contract$;

do $fixtures$
declare v_actor_id uuid;
begin
  select ur.user_id into v_actor_id
  from public.user_roles ur join public.roles r on r.id=ur.role_id
  where r.code='super_admin' limit 1;
  if v_actor_id is null then raise exception 'La prueba requiere un Super Admin existente.'; end if;
  perform set_config('app.alpha_migration_test_actor', v_actor_id::text, true);
  insert into public.companies(id,legal_name,display_name)
  values ('17000000-0000-4000-8000-000000000001','Empresa migración Alpha','Empresa migración Alpha');
  insert into public.user_roles(user_id,role_id,company_id)
  select v_actor_id,id,'17000000-0000-4000-8000-000000000001' from public.roles where code='super_admin'
  on conflict do nothing;
end;
$fixtures$;

create function pg_temp.alpha_validation_state(p_company uuid,p_external_code text,p_batch uuid default null)
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
  select jsonb_build_object(
    'customer_id',(select id from public.customers where company_id=p_company and alpha_external_code=p_external_code limit 1),
    'has_document',exists(select 1 from public.customer_receivables r join public.customers c on c.id=r.customer_id where r.company_id=p_company and c.alpha_external_code=p_external_code and r.source_kind='alpha_document'),
    'has_opening',exists(select 1 from public.customer_receivables r join public.customers c on c.id=r.customer_id where r.company_id=p_company and c.alpha_external_code=p_external_code and r.source_kind='alpha_opening_balance' and r.source_cutoff_date='2026-07-08'),
    'has_payments',exists(select 1 from public.receivable_payments where company_id=p_company),
    'batch_status',(select status from public.alpha_customer_migration_batches where id=p_batch)
  )
$$;

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub',current_setting('app.alpha_migration_test_actor',true),true);

do $assertions$
declare
  v_company uuid := '17000000-0000-4000-8000-000000000001';
  v_files jsonb := jsonb_build_array(
    jsonb_build_object('report_type','customers','original_name','cata_cte_fixture.xls','file_sha256','fixture-cata','snapshot_date','2026-07-08','row_count',1),
    jsonb_build_object('report_type','credit_terms','original_name','cat_ctee_fixture.xls','file_sha256','fixture-terms','logical_sha256','fixture-terms-logical','snapshot_date','2026-07-08','duplicate_group','credit_terms:fixture','row_count',1),
    jsonb_build_object('report_type','ledger','original_name','lis_sal_fixture.xls','file_sha256','fixture-ledger','snapshot_date','2026-07-08','row_count',1),
    jsonb_build_object('report_type','collections','original_name','cob_cte_fixture.xls','file_sha256','fixture-cob','snapshot_date','2026-07-08','row_count',1)
  );
  v_batch uuid; v_bad_cent_batch uuid; v_conflict_batch uuid; v_opening_batch uuid; v_customer uuid; v_result jsonb; v_state jsonb; v_status text;
begin
  v_result := public.begin_alpha_customer_migration(v_company,'2026-07-08','fixture-content-1',v_files);
  v_batch := (v_result->>'batch_id')::uuid;
  perform public.stage_alpha_customer_migration_rows(v_batch,'customers',jsonb_build_array(jsonb_build_object(
    'external_code','ALPHA-001','display_name','Cliente Alpha Uno','commercial_name','Cliente Alpha Uno','commercial_type','Contado','credit_limit',null,'credit_term_days',null,'catalog_present',true,'terms_present',true,'source_row_hash','customer-hash-1'
  )));
  perform public.stage_alpha_customer_migration_rows(v_batch,'documents',jsonb_build_array(jsonb_build_object(
    'customer_external_code','ALPHA-001','source_code','F','folio','FAC-001','document_date','2026-07-08','currency_code','MXN','original_amount',100.00,'outstanding_amount',100.00,'source_row_hash','document-hash-1','raw_data',jsonb_build_object('origin','lis_sal')
  )));
  perform public.stage_alpha_customer_migration_rows(v_batch,'collections',jsonb_build_array(jsonb_build_object(
    'customer_external_code','ALPHA-001','folio','COB-001','amount',100.00,'currency_code','MXN','source_row_hash','collection-evidence-1','raw_data',jsonb_build_object('origin','cob_cte')
  )));
  perform public.reconcile_alpha_customer_migration(v_batch);
  v_result := public.promote_alpha_customer_migration_chunk(v_batch, 200);
  if v_result->>'status' <> 'completed' then raise exception 'El cliente reconciliado no se promovió.'; end if;
  v_state := pg_temp.alpha_validation_state(v_company,'ALPHA-001',v_batch);
  v_customer := (v_state->>'customer_id')::uuid;
  if v_customer is null or not (v_state->>'has_document')::boolean then
    raise exception 'No se promovió el perfil o documento Alpha reconciliado.';
  end if;
  if (v_state->>'has_payments')::boolean then
    raise exception 'cob_cte no puede crear abonos.';
  end if;
  v_result := public.begin_alpha_customer_migration(v_company,'2026-07-08','fixture-content-1',v_files);
  if v_result->>'status' <> 'duplicate' or (v_result->>'batch_id')::uuid <> v_batch then
    raise exception 'La reimportación del mismo contenido no fue idempotente.';
  end if;

  v_result := public.begin_alpha_customer_migration(v_company,'2026-07-08','fixture-content-cent',v_files);
  v_bad_cent_batch := (v_result->>'batch_id')::uuid;
  perform public.stage_alpha_customer_migration_rows(v_bad_cent_batch,'customers',jsonb_build_array(jsonb_build_object(
    'external_code','ALPHA-002','display_name','Cliente Alpha Centavo','commercial_name','Cliente Alpha Centavo','commercial_type','Contado','catalog_present',true,'terms_present',true,'source_row_hash','customer-hash-2'
  )));
  perform public.stage_alpha_customer_migration_rows(v_bad_cent_batch,'documents',jsonb_build_array(jsonb_build_object(
    'customer_external_code','ALPHA-002','source_code','F','folio','FAC-002','document_date','2026-07-08','currency_code','MXN','original_amount',100.00,'outstanding_amount',100.01,'source_row_hash','document-hash-2','raw_data','{}'::jsonb
  )));
  perform public.reconcile_alpha_customer_migration(v_bad_cent_batch);
  v_result := public.promote_alpha_customer_migration_chunk(v_bad_cent_batch, 200);
  if v_result->>'status' <> 'failed' or (pg_temp.alpha_validation_state(v_company,'ALPHA-002',v_bad_cent_batch)->>'customer_id') is not null then
    raise exception 'Una diferencia de $0.01 no bloqueó al cliente.';
  end if;

  v_result := public.begin_alpha_customer_migration(v_company,'2026-07-08','fixture-content-conflict',v_files);
  v_conflict_batch := (v_result->>'batch_id')::uuid;
  perform public.stage_alpha_customer_migration_rows(v_conflict_batch,'customers',jsonb_build_array(jsonb_build_object(
    'external_code','ALPHA-003','display_name','Cliente Alpha Conflicto','commercial_name','Cliente Alpha Conflicto','commercial_type','Contado','catalog_present',true,'terms_present',true,'source_row_hash','customer-hash-3'
  )));
  perform public.stage_alpha_customer_migration_rows(v_conflict_batch,'documents',jsonb_build_array(
    jsonb_build_object('customer_external_code','ALPHA-003','source_code','F','folio','FAC-003','document_date','2026-07-08','currency_code','MXN','original_amount',20.00,'outstanding_amount',20.00,'source_row_hash','document-hash-3a','raw_data','{}'::jsonb),
    jsonb_build_object('customer_external_code','ALPHA-003','source_code','F','folio','FAC-003','document_date','2026-07-08','currency_code','MXN','original_amount',20.00,'outstanding_amount',20.00,'source_row_hash','document-hash-3b','raw_data','{}'::jsonb)
  ));
  perform public.reconcile_alpha_customer_migration(v_conflict_batch);
  v_result := public.promote_alpha_customer_migration_chunk(v_conflict_batch, 200);
  if v_result->>'status' <> 'failed' or (pg_temp.alpha_validation_state(v_company,'ALPHA-003',v_conflict_batch)->>'customer_id') is not null then
    raise exception 'Una clave documental con huellas distintas no bloqueó la promoción.';
  end if;

  v_result := public.begin_alpha_customer_migration(v_company,'2026-07-08','fixture-content-opening',v_files);
  v_opening_batch := (v_result->>'batch_id')::uuid;
  perform public.stage_alpha_customer_migration_rows(v_opening_batch,'customers',jsonb_build_array(jsonb_build_object(
    'external_code','ALPHA-004','display_name','Cliente Alpha Apertura','commercial_name','Cliente Alpha Apertura','commercial_type','Contado','catalog_present',true,'terms_present',true,'source_row_hash','customer-hash-4'
  )));
  perform public.declare_alpha_customer_opening_balance(v_opening_batch,'ALPHA-004',50.00,'lis-sal-opening-hash','lis_sal corte 2026-07-08, cliente ALPHA-004');
  perform public.reconcile_alpha_customer_migration(v_opening_batch);
  perform public.promote_alpha_customer_migration_chunk(v_opening_batch, 200);
  if not (pg_temp.alpha_validation_state(v_company,'ALPHA-004',v_opening_batch)->>'has_opening')::boolean then
    raise exception 'El saldo de apertura no quedó identificado explícitamente.';
  end if;

  v_status := pg_temp.alpha_validation_state(v_company,'ALPHA-002',v_bad_cent_batch)->>'batch_status';
  if v_status <> 'failed' then raise exception 'Estado de lote incorrecto para discrepancias.'; end if;
end;
$assertions$;

reset role;
rollback;
