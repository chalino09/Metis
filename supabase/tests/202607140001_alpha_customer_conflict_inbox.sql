-- Customer identity conflict inbox regression. Run after 202607140001.
-- The fixture is fully rolled back and contains eleven real (non-generic RFC)
-- identity conflicts plus one generic RFC that must remain outside the inbox.
begin;

do $fixture$
declare
  v_actor uuid;
  v_company uuid:='24000000-0000-4000-8000-000000000001';
  v_batch uuid:='24000000-0000-4000-8000-000000000002';
  v_future_batch uuid:='24000000-0000-4000-8000-000000000003';
  v_existing uuid:='24000000-0000-4000-8000-000000000004';
  v_taken uuid:='24000000-0000-4000-8000-000000000005';
  v_auto_customer uuid;
  v_conflicts jsonb;
  v_result jsonb;
  v_documents jsonb:=jsonb_build_array(
    jsonb_build_object('customer_external_code','ALPHA-C01','source_code','F','folio','FAC-01','document_date','2026-07-14','currency_code','MXN','original_amount',100.00,'outstanding_amount',100.00,'source_row_hash','doc-hash-01'),
    jsonb_build_object('customer_external_code','ALPHA-C04','source_code','F','folio','FAC-04','document_date','2026-07-14','currency_code','MXN','original_amount',40.00,'outstanding_amount',40.00,'source_row_hash','doc-hash-04')
  );
  v_code text;
  v_cash_failed boolean:=false;
  v_generic_failed boolean:=false;
begin
  if to_regprocedure('public.list_alpha_customer_identity_conflicts(uuid)') is null
    or to_regprocedure('public.decide_alpha_customer_identity_conflict(uuid,text,text,uuid,text)') is null
    or to_regprocedure('public.promote_alpha_customer_migration_chunk(uuid,integer)') is null
    or to_regprocedure('public.apply_alpha_repaired_customer_receivable_backfill(uuid,text,jsonb)') is null then
    raise exception 'Faltan las RPC de bandeja, promoción o CxC.';
  end if;
  select ur.user_id into v_actor
  from public.user_roles ur join public.roles r on r.id=ur.role_id
  where r.code='super_admin' limit 1;
  if v_actor is null then raise exception 'La prueba requiere un Super Admin existente.'; end if;

  insert into public.companies(id,legal_name,display_name)
  values(v_company,'Empresa prueba bandeja','Empresa prueba bandeja');
  insert into public.user_roles(user_id,role_id,company_id)
  select v_actor,id,v_company from public.roles where code='super_admin' on conflict do nothing;
  insert into public.alpha_customer_migration_batches(id,company_id,cutoff_date,content_sha256,status,imported_by,summary)
  values(v_batch,v_company,'2026-07-14','identity-inbox-fixture','completed_with_discrepancies',v_actor,
    '{"blocked_customers":12,"receivable_repair":{"status":"completed"}}'::jsonb);
  insert into public.alpha_customer_migration_files(batch_id,report_type,original_name,file_sha256,snapshot_date,row_count)
  values(v_batch,'ledger','lis_sal_fixture.xls','ledger-fixture','2026-07-14',2);
  insert into public.customers(id,company_id,code,display_name,tax_id,credit_enabled,credit_limit,credit_term_days,created_by,migration_status)
  values
    (v_existing,v_company,'MAN-001','Cliente 01','AAA010101AAA',true,500,30,v_actor,'manual'),
    (v_taken,v_company,'TAKEN-CASH','Cliente protegido','BBB010101BBB',true,900,45,v_actor,'manual');

  insert into public.alpha_customer_migration_customers(batch_id,external_code,display_name,tax_id,source_row_hash,status,commercial_type,credit_limit,credit_term_days,document_mode)
  values
    (v_batch,'ALPHA-C01','Cliente 01','AAA010101AAA','source-01','discrepancy','Crédito',100,15,'documents'),
    (v_batch,'TAKEN-CASH','Cliente protegido','BBB010101BBB','source-02','discrepancy','Crédito',100,15,'none'),
    (v_batch,'ALPHA-C03','Cliente 03','CCC010101CCC','source-03','discrepancy','Crédito',100,15,'none'),
    (v_batch,'ALPHA-C04','Cliente 04','DDD010101DDD','source-04','discrepancy','Crédito',100,15,'documents'),
    (v_batch,'ALPHA-GENERIC','Cliente genérico','XAXX010101000','source-generic','discrepancy','Contado',0,0,'none');
  insert into public.alpha_customer_migration_customers(batch_id,external_code,display_name,tax_id,source_row_hash,status,commercial_type,credit_limit,credit_term_days)
  select v_batch,'ALPHA-C'||lpad(n::text,2,'0'),'Cliente '||lpad(n::text,2,'0'),'RFC'||lpad(n::text,10,'0'),'source-'||n,'discrepancy','Crédito',100,15
  from generate_series(5,11) n;
  insert into public.alpha_customer_migration_differences(batch_id,customer_external_code,severity,difference_code,message)
  select v_batch,c.external_code,'error','PROMOTION_FAILED','duplicate key value violates unique constraint "customers_company_tax_id_key"'
  from public.alpha_customer_migration_customers c
  where c.batch_id=v_batch;
  insert into public.alpha_customer_migration_documents(batch_id,customer_external_code,source_code,folio,document_date,currency_code,original_amount,outstanding_amount,source_row_hash,source_document_key)
  values
    (v_batch,'ALPHA-C01','F','FAC-01','2026-07-14','MXN',100,100,'doc-hash-01',encode(digest('ALPHA-C01|F|FAC-01|2026-07-14|MXN|10000','sha256'),'hex')),
    (v_batch,'ALPHA-C04','F','FAC-04','2026-07-14','MXN',40,40,'doc-hash-04',encode(digest('ALPHA-C04|F|FAC-04|2026-07-14|MXN|4000','sha256'),'hex'));
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_actor::text,true);

  v_conflicts:=public.list_alpha_customer_identity_conflicts(v_company);
  if jsonb_array_length(v_conflicts)<>11
    or exists(select 1 from jsonb_array_elements(v_conflicts) c where c->>'external_code'='ALPHA-GENERIC') then
    raise exception 'La bandeja debe mostrar exactamente los once conflictos reales y excluir RFC genéricos.';
  end if;
  if not exists(select 1 from jsonb_array_elements(v_conflicts) c where c->>'external_code'='ALPHA-C01' and jsonb_array_length(c->'candidates')=1) then
    raise exception 'El conflicto fiscal real no mostró su candidato canónico.';
  end if;

  v_result:=public.decide_alpha_customer_identity_conflict(v_batch,'ALPHA-C01','link_existing',v_existing,'RFC y razón social coinciden con el cliente manual.');
  if v_result->>'status'<>'resolved' or (v_result->>'promoted_customer_id')::uuid<>v_existing then raise exception 'No se vinculó el cliente existente.'; end if;
  v_result:=public.decide_alpha_customer_identity_conflict(v_batch,'ALPHA-C01','link_existing',v_existing,'RFC y razón social coinciden con el cliente manual.');
  if coalesce((v_result->>'idempotent')::boolean,false) is not true then raise exception 'El reintento de vínculo no fue idempotente.'; end if;

  begin
    perform public.decide_alpha_customer_identity_conflict(v_batch,'TAKEN-CASH','create_cash_without_rfc',null,'Se intenta contado sobre una clave ya ocupada.');
  exception when others then
    v_cash_failed:=position('usa la opción Vincular' in sqlerrm)>0;
  end;
  if not v_cash_failed or exists(select 1 from public.customers where id=v_taken and (tax_id<>'BBB010101BBB' or not credit_enabled or credit_limit<>900 or credit_term_days<>45)) then
    raise exception 'Contado modificó un cliente existente o no exigió vínculo.';
  end if;
  perform public.decide_alpha_customer_identity_conflict(v_batch,'TAKEN-CASH','link_existing',v_taken,'La clave existente fue revisada y corresponde al cliente canónico.');
  perform public.decide_alpha_customer_identity_conflict(v_batch,'ALPHA-C03','create_cash_without_rfc',null,'Cliente de contado sin identidad fiscal canónica.');
  perform public.decide_alpha_customer_identity_conflict(v_batch,'ALPHA-C04','leave_pending',null,'Requiere confirmación documental antes de vincular.');
  for n in 5..11 loop
    v_code:='ALPHA-C'||lpad(n::text,2,'0');
    perform public.decide_alpha_customer_identity_conflict(v_batch,v_code,'create_cash_without_rfc',null,'Cliente de contado validado sin RFC canónico.');
  end loop;
  if (select count(*) from public.alpha_customer_migration_customers where batch_id=v_batch and status='promoted')<>10
    or (select count(*) from public.alpha_customer_migration_customers where batch_id=v_batch and status='discrepancy')<>2 then
    raise exception 'Las decisiones no mantuvieron bloqueados el pendiente y el RFC genérico.';
  end if;
  if not exists(select 1 from public.customers where company_id=v_company and code='ALPHA-C03' and tax_id is null and not credit_enabled and credit_limit=0 and credit_term_days=0) then
    raise exception 'Contado no creó un cliente nuevo, sin RFC y sin crédito.';
  end if;
  begin
    perform public.decide_alpha_customer_identity_conflict(v_batch,'ALPHA-GENERIC','create_cash_without_rfc',null,'No debe requerir decisión manual.');
  exception when others then
    v_generic_failed:=position('RFC genérico' in sqlerrm)>0;
  end;
  if not v_generic_failed then raise exception 'Un RFC genérico entró incorrectamente a la bandeja.'; end if;

  v_result:=public.apply_alpha_repaired_customer_receivable_backfill(v_batch,'ledger-fixture',v_documents);
  if v_result->>'status'<>'partial' or (v_result->>'remaining_customer_documents')::integer<>1
    or (select count(*) from public.customer_receivables where company_id=v_company and source_kind='alpha_document')<>1 then
    raise exception 'CxC se marcó como completada antes de resolver todos los clientes.';
  end if;
  perform public.decide_alpha_customer_identity_conflict(v_batch,'ALPHA-C04','create_cash_without_rfc',null,'Confirmado como cliente de contado sin RFC canónico.');
  v_result:=public.apply_alpha_repaired_customer_receivable_backfill(v_batch,'ledger-fixture',v_documents);
  if v_result->>'status'<>'completed' or (select count(*) from public.customer_receivables where company_id=v_company and source_kind='alpha_document')<>2 then
    raise exception 'CxC no incorporó el documento desbloqueado después de la resolución.';
  end if;
  v_result:=public.apply_alpha_repaired_customer_receivable_backfill(v_batch,'ledger-fixture',v_documents);
  if v_result->>'status'<>'already_applied' or (select count(*) from public.customer_receivables where company_id=v_company and source_kind='alpha_document')<>2 then
    raise exception 'El reintento de CxC duplicó documentos.';
  end if;

  insert into public.alpha_customer_migration_batches(id,company_id,cutoff_date,content_sha256,status,imported_by)
  values(v_future_batch,v_company,'2026-09-14','identity-inbox-future','ready_to_promote',v_actor);
  insert into public.alpha_customer_migration_customers(batch_id,external_code,display_name,tax_id,source_row_hash,status)
  values(v_future_batch,'ALPHA-C01','Cliente 01 actualizado','AAA010101AAA','source-01-new','reconciled');
  insert into public.alpha_customer_migration_customers(batch_id,external_code,display_name,tax_id,address_line,neighborhood,municipality,state_name,postal_code,phone,contact_name,source_row_hash,status)
  values(v_future_batch,'ALPHA-C12','Cliente canónico','EEE010101EEE','Calle 12','Centro','Monterrey','Nuevo León','64000','8181818181','Contacto canónico','source-12','reconciled');
  v_result:=public.promote_alpha_customer_migration_chunk(v_future_batch,200);
  if v_result->>'status'<>'completed'
    or not exists(select 1 from public.alpha_customer_migration_customers where batch_id=v_future_batch and external_code='ALPHA-C01' and status='promoted' and promoted_customer_id=v_existing)
    or (select count(*) from public.customers where company_id=v_company and tax_id='AAA010101AAA')<>1 then
    raise exception 'La promoción futura no reutilizó el vínculo Alpha → Satrapy.';
  end if;
  select promoted_customer_id into v_auto_customer
  from public.alpha_customer_migration_customers
  where batch_id=v_future_batch and external_code='ALPHA-C12' and status='promoted';
  if v_auto_customer is null
    or exists(select 1 from public.customers c where c.id=v_auto_customer and (
      c.phone is not null or c.address_line is not null or c.neighborhood is not null
      or c.municipality is not null or c.state_name is not null or c.postal_code is not null or c.contact_name is not null
    )) then
    raise exception 'La promoción canónica escribió datos de dirección o contacto en customers.';
  end if;
  if not exists(select 1 from public.customer_addresses a where a.customer_id=v_auto_customer and a.is_primary and a.address_line='Calle 12' and a.neighborhood='Centro' and a.municipality='Monterrey' and a.state_name='Nuevo León' and a.postal_code='64000')
    or not exists(select 1 from public.customer_contacts c where c.customer_id=v_auto_customer and c.is_primary and c.display_name='Contacto canónico' and c.phone='8181818181') then
    raise exception 'La promoción canónica no creó la dirección y el contacto separados.';
  end if;
end;
$fixture$;

rollback;
