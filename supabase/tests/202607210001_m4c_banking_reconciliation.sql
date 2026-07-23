begin;
do $test$
declare
  c uuid:='4c000000-0000-4000-8000-000000000001';u uuid:='4c000000-0000-4000-8000-000000000002';outsider uuid:='4c000000-0000-4000-8000-000000000003';
  account_id uuid;customer_id uuid;method_id uuid;receipt_id uuid;batch_id uuid;transaction_id uuid;candidate_id uuid;reconciliation_id uuid;r jsonb;blocked boolean:=false;
  good_hash text:=repeat('a',64);bad_hash text:=repeat('b',64);
begin
  insert into public.companies(id,legal_name,display_name) values(c,'Bancos controlados','Bancos controlados');
  insert into auth.users(id,aud,role,email,encrypted_password) values(u,'authenticated','authenticated','m4c@example.com',''),(outsider,'authenticated','authenticated','m4c-outside@example.com','');
  insert into public.user_roles(user_id,role_id,company_id) select u,id,c from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);

  r:=public.save_supplier_paying_account(c,null,'Institución de prueba','Operativa','MXN','4321',true);account_id:=(r->>'id')::uuid;
  if not exists(select 1 from public.financial_accounts where id=account_id and legacy_paying_account_id=account_id and institution_name='Institución de prueba') then raise exception 'La cuenta pagadora no se promovió canónicamente conservando UUID.';end if;
  if (select count(*) from public.financial_accounts where company_id=c)<>1 then raise exception 'La conversión canónica duplicó cuentas.';end if;

  insert into public.customers(company_id,code,display_name) values(c,'C-1','Cliente bancario') returning id into customer_id;
  insert into public.payment_methods(company_id,code,display_name,settlement_kind) values(c,'BANK','Cobro bancario','external') returning id into method_id;
  insert into public.receivable_payments(company_id,customer_id,payment_method_id,payment_method_code,settlement_kind,amount,client_request_id,received_by,received_at,financial_account_id,currency_code,bank_reference)
  values(c,customer_id,method_id,'BANK','external',500,gen_random_uuid(),u,current_date,account_id,'MXN','COBRO-001') returning id into receipt_id;

  r:=public.create_bank_statement_staging(c,'4321','MXN','controlado.csv',good_hash,current_date,current_date,1000,1150,'{"source":"controlled"}');batch_id:=(r->>'id')::uuid;
  r:=public.create_bank_statement_staging(c,'4321','MXN','controlado.csv',good_hash,current_date,current_date,1000,1150,'{"source":"controlled"}');
  if coalesce((r->>'idempotent')::boolean,false)=false or (r->>'id')::uuid<>batch_id then raise exception 'La carga duplicada no fue idempotente.';end if;
  perform public.stage_bank_statement_rows(batch_id,jsonb_build_array(
    jsonb_build_object('row_number',9,'transaction_date',current_date,'value_date',current_date,'reference','COBRO-001','description','Cobro','credit',500,'debit',0,'running_balance',1500,'row_sha256',repeat('1',64),'raw_data','{}'::jsonb),
    jsonb_build_object('row_number',10,'transaction_date',current_date,'value_date',current_date,'reference','SIN-CANDIDATO','description','Cargo','credit',0,'debit',350,'running_balance',1150,'row_sha256',repeat('2',64),'raw_data','{}'::jsonb)
  ));
  r:=public.finalize_bank_statement_staging(batch_id);
  if r->>'status'<>'ready' or coalesce((r->>'balance_valid')::boolean,false)=false or (r->>'calculated_closing_balance')::numeric<>1150 then raise exception 'La explicación de saldo válida falló: %',r;end if;
  r:=public.promote_bank_statement(batch_id,'4c000000-0000-4000-8000-000000000010');
  if (r->>'transactions_created')::int<>2 or (select count(*) from public.bank_transactions where statement_batch_id=batch_id)<>2 then raise exception 'La promoción masiva no creó dos movimientos.';end if;
  r:=public.promote_bank_statement(batch_id,'4c000000-0000-4000-8000-000000000010');if coalesce((r->>'idempotent')::boolean,false)=false then raise exception 'La promoción no fue idempotente.';end if;
  select id into transaction_id from public.bank_transactions where statement_batch_id=batch_id and reference='COBRO-001';
  select id into candidate_id from public.bank_reconciliation_candidates where bank_transaction_id=transaction_id and source_type='receivable_payment' and source_id=receipt_id and match_quality='exact';
  if candidate_id is null then raise exception 'No se detectó el candidato exacto por cuenta, moneda, importe, fecha y referencia.';end if;
  if exists(select 1 from public.bank_reconciliations where bank_transaction_id=transaction_id) then raise exception 'El candidato exacto se confirmó sin autorización humana.';end if;
  r:=public.confirm_bank_reconciliations(c,array[candidate_id],'{}','4c000000-0000-4000-8000-000000000011');
  if (r->>'confirmed')::int<>1 then raise exception 'La conciliación exacta no se confirmó.';end if;
  select id into reconciliation_id from public.bank_reconciliations where bank_transaction_id=transaction_id and status='confirmed';
  r:=public.confirm_bank_reconciliations(c,array[candidate_id],'{}','4c000000-0000-4000-8000-000000000011');if coalesce((r->>'idempotent')::boolean,false)=false then raise exception 'La confirmación no fue idempotente.';end if;
  r:=public.disconnect_bank_reconciliations(c,array[reconciliation_id],'Referencia corregida','4c000000-0000-4000-8000-000000000012');
  if (r->>'disconnected')::int<>1 or not exists(select 1 from public.bank_reconciliations where id=reconciliation_id and status='disconnected' and disconnection_reason='Referencia corregida') then raise exception 'La desconciliación no conservó evidencia.';end if;
  begin update public.bank_transactions set amount=1 where id=transaction_id;exception when others then blocked:=position('inmutable' in lower(sqlerrm))>0;end;if not blocked then raise exception 'Se modificó un movimiento bancario.';end if;blocked:=false;

  r:=public.create_bank_statement_staging(c,'4321','MXN','descuadrado.csv',bad_hash,current_date,current_date,100,200,'{}');
  perform public.stage_bank_statement_rows((r->>'id')::uuid,jsonb_build_array(jsonb_build_object('row_number',9,'transaction_date',current_date,'reference','X','credit',10,'debit',0,'row_sha256',repeat('3',64),'raw_data','{}'::jsonb)));
  r:=public.finalize_bank_statement_staging((r->>'id')::uuid);
  if r->>'status'<>'rejected' or (r->>'balance_difference')::numeric<>-90 then raise exception 'No se bloqueó un estado con saldo inexplicable.';end if;

  perform set_config('request.jwt.claim.sub',outsider::text,true);
  begin perform public.list_banking_workspace(c,null,1,50);exception when others then blocked:=position('no autorizado' in lower(sqlerrm))>0;end;if not blocked then raise exception 'Un usuario ajeno consultó Bancos.';end if;
  if (select count(*) from pg_policies where schemaname='public' and tablename in ('financial_accounts','bank_statement_batches','bank_statement_staging_rows','bank_transactions','bank_reconciliation_candidates','bank_reconciliations','bank_reconciliation_exceptions'))<>7 then raise exception 'La matriz RLS bancaria está incompleta.';end if;
  if not exists(select 1 from public.audit_log where company_id=c and action='bank_reconciliation.bulk_disconnected') then raise exception 'Falta auditoría de desconciliación.';end if;
  raise notice 'Bancos: conversión canónica, duplicados, saldo, staging, inmutabilidad, candidato exacto, confirmación, desconciliación, permisos y RLS aprobados.';
end;$test$;
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true),set_config('request.jwt.claim.sub','4c000000-0000-4000-8000-000000000003',true);
do $$begin if exists(select 1 from public.financial_accounts where company_id='4c000000-0000-4000-8000-000000000001') then raise exception 'RLS expuso cuentas a un usuario ajeno.';end if;end$$;
reset role;
rollback;
