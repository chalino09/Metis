begin;

do $test$
declare
  v_payer uuid:='3e200000-0000-4000-8000-000000000091';v_reverser uuid:='3e200000-0000-4000-8000-000000000092';v_outsider uuid:='3e200000-0000-4000-8000-000000000093';
  v_company uuid:='3e200000-0000-4000-8000-000000000001';v_other uuid:='3e200000-0000-4000-8000-000000000002';v_supplier uuid;
  v_invoice_a uuid;v_invoice_b uuid;v_invoice_c uuid;v_invoice_d uuid;v_payable_a uuid;v_payable_b uuid;v_payable_c uuid;v_payable_d uuid;
  v_account uuid;v_result jsonb;v_proposal uuid;v_payment uuid;v_overlap_a uuid;v_overlap_b uuid;v_overlap_payment uuid;v_reverted_proposal uuid;v_usd_proposal uuid;
  v_cfg uuid;v_rule_set uuid;v_controls jsonb;v_role text;v_role_account uuid;
  v_forbidden boolean:=false;v_inventory bigint;v_ledger bigint;v_cost bigint;v_alpha bigint;v_invoice_states jsonb;
  v_confirm_request uuid:='3e200000-0000-4000-8000-000000000010';v_reverse_request uuid:='3e200000-0000-4000-8000-000000000011';
begin
  if to_regprocedure('public.confirm_supplier_payment(uuid,uuid,uuid,date,text,text,uuid)') is null or to_regprocedure('public.reverse_supplier_payment(uuid,uuid,text,uuid)') is null then raise exception 'Faltan RPC de M3E2.';end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='supplier_payments' and policyname='supplier_payments_read') or not exists(select 1 from pg_policies where schemaname='public' and tablename='supplier_payment_applications' and policyname='supplier_payment_applications_read') then raise exception 'Faltan políticas RLS de pagos.';end if;
  insert into public.companies(id,legal_name,display_name) values(v_company,'Pagos M3E2','Pagos M3E2'),(v_other,'Otra M3E2','Otra M3E2');
  insert into auth.users(id,aud,role,email,encrypted_password) values(v_payer,'authenticated','authenticated','paga-m3e2@example.com',''),(v_reverser,'authenticated','authenticated','revierte-m3e2@example.com',''),(v_outsider,'authenticated','authenticated','ajeno-m3e2@example.com','');
  insert into public.role_permissions(role_id,permission_id) select r.id,p.id from public.roles r cross join public.permissions p where r.code='almacen' and p.code in ('view_accounts_payable','prepare_supplier_payment_proposals','approve_supplier_payment_proposals','manage_supplier_paying_accounts','view_supplier_payments','confirm_supplier_payments','configure_accounting','approve_accounting_config','configure_accounting_events','approve_accounting_events') on conflict do nothing;
  insert into public.role_permissions(role_id,permission_id) select r.id,p.id from public.roles r cross join public.permissions p where r.code='sucursal' and p.code in ('view_supplier_payments','reverse_supplier_payments') on conflict do nothing;
  insert into public.user_roles(user_id,role_id,company_id) select v_payer,id,v_company from public.roles where code='almacen';
  insert into public.user_roles(user_id,role_id,company_id) select v_reverser,id,v_company from public.roles where code='sucursal';
  insert into public.user_roles(user_id,role_id,company_id) select v_outsider,id,v_other from public.roles where code='almacen';
  insert into public.suppliers(company_id,code,display_name,legal_entity_type,country_code,is_active) values(v_company,'SUP-E2','Proveedor E2','moral','MX',true) returning id into v_supplier;
  insert into public.supplier_invoices(company_id,supplier_id,source_kind,status,series,folio,issued_date,due_date,currency_code,subtotal,total,base_total,expense_approved_at,confirmed_at)
  values(v_company,v_supplier,'expense','confirmed','E2','001',current_date-20,current_date-5,'MXN',100,100,100,now(),now()) returning id into v_invoice_a;
  insert into public.supplier_invoices(company_id,supplier_id,source_kind,status,series,folio,issued_date,due_date,currency_code,subtotal,total,base_total,expense_approved_at,confirmed_at)
  values(v_company,v_supplier,'expense','confirmed','E2','002',current_date-10,current_date+5,'MXN',200,200,200,now(),now()) returning id into v_invoice_b;
  insert into public.supplier_invoices(company_id,supplier_id,source_kind,status,series,folio,issued_date,due_date,currency_code,subtotal,total,base_total,expense_approved_at,confirmed_at)
  values(v_company,v_supplier,'expense','confirmed','E2','003',current_date-10,current_date+8,'MXN',100,100,100,now(),now()) returning id into v_invoice_c;
  insert into public.supplier_invoices(company_id,supplier_id,source_kind,status,series,folio,issued_date,due_date,currency_code,exchange_rate,subtotal,total,base_total,expense_approved_at,confirmed_at)
  values(v_company,v_supplier,'expense','confirmed','E2','004',current_date-10,current_date+8,'USD',18,50,50,900,now(),now()) returning id into v_invoice_d;
  insert into public.accounts_payable(company_id,supplier_id,supplier_invoice_id,currency_code,original_amount,outstanding_amount,issued_date,due_date) values(v_company,v_supplier,v_invoice_a,'MXN',100,100,current_date-20,current_date-5) returning id into v_payable_a;
  insert into public.accounts_payable(company_id,supplier_id,supplier_invoice_id,currency_code,original_amount,outstanding_amount,issued_date,due_date) values(v_company,v_supplier,v_invoice_b,'MXN',200,200,current_date-10,current_date+5) returning id into v_payable_b;
  insert into public.accounts_payable(company_id,supplier_id,supplier_invoice_id,currency_code,original_amount,outstanding_amount,issued_date,due_date) values(v_company,v_supplier,v_invoice_c,'MXN',100,100,current_date-10,current_date+8) returning id into v_payable_c;
  insert into public.accounts_payable(company_id,supplier_id,supplier_invoice_id,currency_code,exchange_rate,original_amount,outstanding_amount,issued_date,due_date) values(v_company,v_supplier,v_invoice_d,'USD',18,50,50,current_date-10,current_date+8) returning id into v_payable_d;
  select count(*) into v_inventory from public.inventory_balances;select count(*) into v_ledger from public.inventory_ledger;select count(*) into v_cost from public.product_costs;select count(*) into v_alpha from public.alpha_purchasing_import_payment_evidence;
  select jsonb_agg(jsonb_build_object('id',id,'status',status,'total',total) order by id) into v_invoice_states from public.supplier_invoices where company_id=v_company;

  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',v_payer::text,true);
  insert into public.accounting_accounts(company_id,code,name,account_type,normal_balance,level)
  select v_company,lpad(n::text,4,'0'),'Cuenta M4B '||n,case when n between 11 and 30 then 'expense' else 'asset' end,case when n in(2,7,9) or n between 11 and 30 then 'credit' else 'debit' end,1 from generate_series(1,30)n;
  select jsonb_object_agg(k,a.id) into v_controls from (values('accounts_receivable','0001'),('accounts_payable','0002'),('inventory','0003'),('cash','0004'),('banks','0005'),('vat_pending','0006'),('vat_collected','0007'),('vat_paid','0008'),('withholdings','0009'))x(k,code) join public.accounting_accounts a on a.company_id=v_company and a.code=x.code;
  v_result:=public.save_accounting_config(v_company,'MXN',current_date,'{"format":"4"}','{"vat_pending":"x","vat_collected":"x","vat_paid":"x","withholdings":"x"}',jsonb_build_object('adjustments',v_payer,'close',v_payer,'reopen',v_payer),'M4B pagos',v_controls);v_cfg:=(v_result->>'id')::uuid;perform public.approve_accounting_config(v_cfg);perform public.create_accounting_period(v_company,to_char(current_date,'YYYY-MM'),date_trunc('month',current_date)::date,(date_trunc('month',current_date)+interval '1 month'-interval '1 day')::date);if date_trunc('month',current_date-20)<>date_trunc('month',current_date) then perform public.create_accounting_period(v_company,to_char(current_date-20,'YYYY-MM'),date_trunc('month',current_date-20)::date,(date_trunc('month',current_date-20)+interval '1 month'-interval '1 day')::date);end if;
  v_result:=public.create_accounting_event_rule_set(v_company,'replacement_cost','{"supplier_payment":"confirmation"}','Matriz pagos');v_rule_set:=(v_result->>'id')::uuid;
  for v_role in select unnest(array['sales_revenue','sales_discounts','cost_of_goods_sold','goods_received_not_invoiced','purchase_variance','supplier_expense','cash_opening_offset','cash_close_offset','cash_movement_offset','cash_over_short','supplier_credit_note_offset','inventory_adjustment']) loop select id into v_role_account from public.accounting_accounts where company_id=v_company and code=lpad((10+(select count(*) from public.accounting_event_role_accounts where rule_set_id=v_rule_set)+1)::text,4,'0');perform public.set_accounting_event_role_account(v_rule_set,v_role,v_role_account);end loop;perform public.approve_accounting_event_rule_set(v_rule_set,'Prueba M4B pagos');
  v_result:=public.save_supplier_paying_account(v_company,null,'Banco de prueba','Operativa MXN','MXN','4321',true);v_account:=(v_result->>'id')::uuid;
  if v_result->>'masked_ending'<>'•••• 4321' or v_result->>'account_last4'<>'4321' then raise exception 'Enmascaramiento de cuenta incorrecto.';end if;
  v_result:=public.save_supplier_payment_proposal(v_company,null,v_supplier,'MXN',jsonb_build_array(jsonb_build_object('accounts_payable_id',v_payable_a,'proposed_amount',40),jsonb_build_object('accounts_payable_id',v_payable_b,'proposed_amount',200)),gen_random_uuid(),null);v_proposal:=(v_result->>'id')::uuid;
  perform public.submit_supplier_payment_proposal(v_company,v_proposal,gen_random_uuid());perform public.decide_supplier_payment_proposal(v_company,v_proposal,'approved',null,gen_random_uuid());
  begin perform public.confirm_supplier_payment(v_company,v_proposal,v_account,current_date,'TRANSFERENCIA','FORMA-INVALIDA',gen_random_uuid());exception when others then v_forbidden:=position('forma de pago sat inválida' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Se aceptó una forma de pago SAT inválida.';end if;v_forbidden:=false;
  v_result:=public.confirm_supplier_payment(v_company,v_proposal,v_account,current_date,'03','REF-E2-001',v_confirm_request);v_payment:=(v_result->>'id')::uuid;
  if v_result#>>'{total_amount}'<>'240.000000' or v_result->>'status'<>'confirmed' or v_result->>'reconciliation_status'<>'unreconciled' then raise exception 'Confirmación parcial/total incorrecta: %',v_result;end if;
  if (select payment_method from public.supplier_payments where id=v_payment)<>'03' then raise exception 'La forma de pago SAT no se conservó exactamente.';end if;
  if (select outstanding_amount from public.accounts_payable where id=v_payable_a)<>60 or (select outstanding_amount from public.accounts_payable where id=v_payable_b)<>0 then raise exception 'Saldos parcial/total incorrectos.';end if;
  if (select count(*) from public.supplier_payment_applications where payment_id=v_payment)<>2 then raise exception 'Faltan aplicaciones explícitas.';end if;
  v_result:=public.confirm_supplier_payment(v_company,v_proposal,v_account,current_date,'03','IGNORADA',v_confirm_request);
  if coalesce((v_result->>'idempotent')::boolean,false)=false or (select count(*) from public.supplier_payments where proposal_id=v_proposal)<>1 or (select outstanding_amount from public.accounts_payable where id=v_payable_a)<>60 then raise exception 'Confirmación no idempotente.';end if;
  begin perform public.confirm_supplier_payment(v_company,v_proposal,v_account,current_date,'03','DUPLICADO',gen_random_uuid());exception when others then v_forbidden:=position('ya tiene un pago' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Se duplicó el pago de una propuesta.';end if;v_forbidden:=false;
  begin update public.supplier_payment_applications set amount=1 where payment_id=v_payment;exception when others then v_forbidden:=position('inmutables' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Se modificó una aplicación confirmada.';end if;v_forbidden:=false;

  v_result:=public.save_supplier_payment_proposal(v_company,null,v_supplier,'MXN',jsonb_build_array(jsonb_build_object('accounts_payable_id',v_payable_c,'proposed_amount',70)),gen_random_uuid(),null);v_overlap_a:=(v_result->>'id')::uuid;perform public.submit_supplier_payment_proposal(v_company,v_overlap_a,gen_random_uuid());perform public.decide_supplier_payment_proposal(v_company,v_overlap_a,'approved',null,gen_random_uuid());
  v_result:=public.save_supplier_payment_proposal(v_company,null,v_supplier,'MXN',jsonb_build_array(jsonb_build_object('accounts_payable_id',v_payable_c,'proposed_amount',50)),gen_random_uuid(),null);v_overlap_b:=(v_result->>'id')::uuid;perform public.submit_supplier_payment_proposal(v_company,v_overlap_b,gen_random_uuid());perform public.decide_supplier_payment_proposal(v_company,v_overlap_b,'approved',null,gen_random_uuid());
  v_result:=public.confirm_supplier_payment(v_company,v_overlap_a,v_account,current_date,'03','REF-OVERLAP-A',gen_random_uuid());v_overlap_payment:=(v_result->>'id')::uuid;
  begin perform public.confirm_supplier_payment(v_company,v_overlap_b,v_account,current_date,'03','REF-OVERLAP-B',gen_random_uuid());exception when others then v_forbidden:=position('excede el saldo' in lower(sqlerrm))>0;end;
  if not v_forbidden or (select outstanding_amount from public.accounts_payable where id=v_payable_c)<>30 then raise exception 'No se bloqueó el sobrepago.';end if;v_forbidden:=false;

  v_result:=public.save_supplier_payment_proposal(v_company,null,v_supplier,'USD',jsonb_build_array(jsonb_build_object('accounts_payable_id',v_payable_d,'proposed_amount',10)),gen_random_uuid(),null);v_usd_proposal:=(v_result->>'id')::uuid;perform public.submit_supplier_payment_proposal(v_company,v_usd_proposal,gen_random_uuid());perform public.decide_supplier_payment_proposal(v_company,v_usd_proposal,'approved',null,gen_random_uuid());
  begin perform public.confirm_supplier_payment(v_company,v_usd_proposal,v_account,current_date,'03','REF-USD',gen_random_uuid());exception when others then v_forbidden:=position('misma moneda' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Se usó una cuenta de otra moneda.';end if;v_forbidden:=false;

  perform set_config('request.jwt.claim.sub',v_reverser::text,true);
  begin perform public.confirm_supplier_payment(v_company,v_overlap_b,v_account,current_date,'03','SIN-PERMISO',gen_random_uuid());exception when others then v_forbidden:=position('no autorizado' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Usuario sin permiso confirmó pago.';end if;v_forbidden:=false;
  begin perform public.reverse_supplier_payment(v_company,v_payment,'',gen_random_uuid());exception when others then v_forbidden:=position('requiere motivo' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Se permitió reversa sin motivo.';end if;v_forbidden:=false;
  v_result:=public.reverse_supplier_payment(v_company,v_payment,'Referencia bancaria capturada incorrectamente.',v_reverse_request);
  if (select outstanding_amount from public.accounts_payable where id=v_payable_a)<>100 or (select outstanding_amount from public.accounts_payable where id=v_payable_b)<>200 or (select status from public.supplier_payments where id=v_payment)<>'reversed' then raise exception 'La reversa no restauró saldos.';end if;
  v_result:=public.reverse_supplier_payment(v_company,v_payment,'Ignorado por idempotencia',v_reverse_request);
  if coalesce((v_result->>'idempotent')::boolean,false)=false or (select outstanding_amount from public.accounts_payable where id=v_payable_a)<>100 then raise exception 'Reversa no idempotente.';end if;
  begin perform public.reverse_supplier_payment(v_company,v_payment,'Segundo intento',gen_random_uuid());exception when others then v_forbidden:=position('no disponible' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Se restauraron saldos dos veces.';end if;v_forbidden:=false;

  perform set_config('request.jwt.claim.sub',v_payer::text,true);
  begin perform public.reverse_supplier_payment(v_company,v_overlap_payment,'Sin permiso',gen_random_uuid());exception when others then v_forbidden:=position('no autorizado' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Confirmador revirtió sin permiso.';end if;v_forbidden:=false;
  perform set_config('request.jwt.claim.sub',v_outsider::text,true);
  begin perform public.search_supplier_payments(v_company,null,null,null,null,1,25);exception when others then v_forbidden:=position('no autorizado' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Empresa ajena consultó pagos.';end if;v_forbidden:=false;

  perform set_config('request.jwt.claim.sub',v_payer::text,true);
  if exists(
    select 1 from public.accounts_payable ap where ap.company_id=v_company and ap.reversed_at is null and ap.outstanding_amount<>
      round(ap.original_amount-coalesce((select sum(a.amount) from public.supplier_payment_applications a join public.supplier_payments p on p.id=a.payment_id where a.accounts_payable_id=ap.id and p.status='confirmed'),0),6)
  ) then raise exception 'La reconciliación matemática de CxP no coincide.';end if;
  if (select jsonb_agg(jsonb_build_object('id',id,'status',status,'total',total) order by id) from public.supplier_invoices where company_id=v_company)<>v_invoice_states then raise exception 'Los pagos modificaron facturas.';end if;
  if (select count(*) from public.inventory_balances)<>v_inventory or (select count(*) from public.inventory_ledger)<>v_ledger or (select count(*) from public.product_costs)<>v_cost then raise exception 'Los pagos modificaron inventario o costos.';end if;
  if (select count(*) from public.alpha_purchasing_import_payment_evidence)<>v_alpha then raise exception 'Se promovió evidencia histórica Alpha.';end if;
  raise notice 'M3E2: cuentas, parcial/total, múltiples CxP, duplicados, sobrepago, idempotencia, reversa, permisos, RLS y conciliación aprobados.';
end;
$test$;

set constraints all immediate;

do $m4b_assert$
declare c uuid:='3e200000-0000-4000-8000-000000000001';d numeric;h numeric;
begin
  if (select count(*) from public.accounting_events where company_id=c and event_type='supplier_payment_confirmed' and status='posted')<>2 then raise exception 'Los pagos confirmados no generaron exactamente dos eventos contables.';end if;
  if (select count(*) from public.accounting_events where company_id=c and event_type='supplier_payment_reversed' and status='posted')<>1 then raise exception 'La reversa de pago no generó exactamente un evento contable.';end if;
  if exists(select l.account_id from public.accounting_events e join public.accounting_journal_entries j on j.accounting_event_id=e.id join public.accounting_journal_lines l on l.journal_entry_id=j.id where e.company_id=c and e.source_entity_type='supplier_payment' and e.source_entity_id=(select id from public.supplier_payments where company_id=c and status='reversed' limit 1) group by l.account_id having abs(sum(l.debit-l.credit))>0.000001) then raise exception 'La reversa de pago no neutralizó exactamente la póliza original.';end if;
  select sum(l.debit),sum(l.credit) into d,h from public.accounting_journal_lines l where l.company_id=c;if d<>h then raise exception 'La cadena contable de pagos quedó desbalanceada: % / %',d,h;end if;
  if exists(select 1 from public.accounting_events e left join public.accounting_journal_entries j on j.accounting_event_id=e.id where e.company_id=c and e.status='posted' group by e.id having count(j.id)<>1) then raise exception 'Un evento de pagos produjo cero o más de una póliza.';end if;
  raise notice 'M4B pagos: confirmación, idempotencia, doble entrada y reversa exacta aprobadas.';
end;
$m4b_assert$;

rollback;
