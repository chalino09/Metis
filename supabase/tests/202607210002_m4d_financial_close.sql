begin;
do $m4d1$
declare
  c uuid:='4d000000-0000-4000-8000-000000000001';u uuid:='4d000000-0000-4000-8000-000000000002';outsider uuid:='4d000000-0000-4000-8000-000000000003';
  cfg uuid:='4d000000-0000-4000-8000-000000000010';p0 uuid:='4d000000-0000-4000-8000-000000000011';p1 uuid:='4d000000-0000-4000-8000-000000000012';p2 uuid:='4d000000-0000-4000-8000-000000000013';
  ar uuid:='4d000000-0000-4000-8000-000000000020';ap uuid:='4d000000-0000-4000-8000-000000000021';inv uuid:='4d000000-0000-4000-8000-000000000022';cash uuid:='4d000000-0000-4000-8000-000000000023';bank uuid:='4d000000-0000-4000-8000-000000000024';
  vatp uuid:='4d000000-0000-4000-8000-000000000025';vatc uuid:='4d000000-0000-4000-8000-000000000026';vatpaid uuid:='4d000000-0000-4000-8000-000000000027';wh uuid:='4d000000-0000-4000-8000-000000000028';rev uuid:='4d000000-0000-4000-8000-000000000029';exp uuid:='4d000000-0000-4000-8000-000000000030';eq uuid:='4d000000-0000-4000-8000-000000000031';
  j0 uuid:='4d000000-0000-4000-8000-000000000040';j1 uuid:='4d000000-0000-4000-8000-000000000041';jt uuid:='4d000000-0000-4000-8000-000000000042';j2 uuid:='4d000000-0000-4000-8000-000000000043';
  customer uuid:='4d000000-0000-4000-8000-000000000050';receivable uuid:='4d000000-0000-4000-8000-000000000051';method uuid:='4d000000-0000-4000-8000-000000000052';rp1 uuid:='4d000000-0000-4000-8000-000000000053';rp2 uuid:='4d000000-0000-4000-8000-000000000054';rp3 uuid:='4d000000-0000-4000-8000-000000000055';receiving_account uuid:='4d000000-0000-4000-8000-000000000056';
  supplier uuid:='4d000000-0000-4000-8000-000000000060';invoice uuid:='4d000000-0000-4000-8000-000000000061';credit uuid:='4d000000-0000-4000-8000-000000000062';payable uuid:='4d000000-0000-4000-8000-000000000063';paying uuid:='4d000000-0000-4000-8000-000000000064';sp1 uuid:='4d000000-0000-4000-8000-000000000065';sp2 uuid:='4d000000-0000-4000-8000-000000000066';sp3 uuid:='4d000000-0000-4000-8000-000000000067';
  location uuid:='4d000000-0000-4000-8000-000000000070';product uuid:='4d000000-0000-4000-8000-000000000071';register_id uuid:='4d000000-0000-4000-8000-000000000072';session_id uuid:='4d000000-0000-4000-8000-000000000073';
  batch uuid:='4d000000-0000-4000-8000-000000000080';bt1 uuid:='4d000000-0000-4000-8000-000000000081';bt2 uuid:='4d000000-0000-4000-8000-000000000082';bt3 uuid:='4d000000-0000-4000-8000-000000000083';
  r jsonb;a numeric;d jsonb;
begin
  insert into public.companies(id,legal_name,display_name) values(c,'M4D1 controlada','M4D1 controlada');
  insert into auth.users(id,aud,role,email,encrypted_password) values(u,'authenticated','authenticated','m4d1@example.com',''),(outsider,'authenticated','authenticated','outsider-m4d1@example.com','');
  insert into public.user_roles(user_id,role_id,company_id) select u,id,c from public.roles where code='direccion_admin';

  insert into public.accounting_accounts(id,company_id,code,name,account_type,normal_balance,level) values
    (ar,c,'1100','CxC','asset','debit',1),(ap,c,'2100','CxP','liability','credit',1),(inv,c,'1200','Inventario','asset','debit',1),(cash,c,'1000','Caja','asset','debit',1),(bank,c,'1050','Bancos','asset','debit',1),
    (vatp,c,'2150','IVA pendiente','liability','credit',1),(vatc,c,'2160','IVA cobrado','liability','credit',1),(vatpaid,c,'1180','IVA pagado','asset','debit',1),(wh,c,'2170','Retenciones','liability','credit',1),
    (rev,c,'4000','Ingresos','revenue','credit',1),(exp,c,'5000','Gastos','expense','debit',1),(eq,c,'3000','Capital','equity','credit',1);
  insert into public.accounting_config_versions(id,company_id,version,status,base_currency,cutoff_date,catalog_structure,tax_treatment,responsibilities,change_reason,approved_by,approved_at)
  values(cfg,c,1,'approved','MXN','2026-01-01','{"format":"4"}','{"vat_pending":"effective_cash_flow","vat_collected":"on_collection","vat_paid":"on_payment","withholdings":"separate_by_tax"}',jsonb_build_object('adjustments',u,'close',u,'reopen',u),'Fixture M4D1',u,'2026-01-01');
  insert into public.accounting_control_accounts(config_version_id,company_id,control_key,account_id) values
    (cfg,c,'accounts_receivable',ar),(cfg,c,'accounts_payable',ap),(cfg,c,'inventory',inv),(cfg,c,'cash',cash),(cfg,c,'banks',bank),(cfg,c,'vat_pending',vatp),(cfg,c,'vat_collected',vatc),(cfg,c,'vat_paid',vatpaid),(cfg,c,'withholdings',wh);
  insert into public.accounting_periods(id,company_id,period_code,starts_on,ends_on) values(p0,c,'2026-H1','2026-01-01','2026-06-30'),(p1,c,'2026-07','2026-07-01','2026-07-31'),(p2,c,'2026-08','2026-08-01','2026-08-31');

  insert into public.accounting_journal_entries(id,company_id,period_id,entry_number,entry_date,description,source_type,status,immutable,client_request_id) values
    (j0,c,p0,1,'2026-06-30','Saldo anterior','manual_adjustment','draft',false,gen_random_uuid()),
    (j1,c,p1,2,'2026-07-15','Actividad del periodo','manual_adjustment','draft',false,gen_random_uuid()),
    (jt,c,p1,3,'2026-07-20','Eventos fiscales efectivos','operational_event','draft',false,gen_random_uuid()),
    (j2,c,p2,4,'2026-08-05','Actividad posterior','manual_adjustment','draft',false,gen_random_uuid());
  insert into public.accounting_journal_lines(company_id,journal_entry_id,line_number,account_id,debit,credit,description) values
    (c,j0,1,cash,100,0,'Apertura'),(c,j0,2,eq,0,100,'Capital'),
    (c,j1,1,cash,60,0,'Entrada'),(c,j1,2,exp,60,0,'Gasto'),(c,j1,3,rev,0,100,'Ingreso'),(c,j1,4,ap,0,20,'Pasivo'),
    (c,jt,1,ar,16,0,'IVA venta pendiente'),(c,jt,2,vatp,0,16,'IVA venta pendiente'),(c,jt,3,vatp,8,0,'IVA cobrado'),(c,jt,4,vatc,0,8,'IVA cobrado'),
    (c,jt,5,vatpaid,5,0,'IVA pagado'),(c,jt,6,vatp,0,5,'IVA pagado'),(c,jt,7,exp,3,0,'Retención'),(c,jt,8,wh,0,3,'Retención'),
    (c,j2,1,cash,999,0,'Posterior'),(c,j2,2,rev,0,999,'Posterior');
  update public.accounting_journal_entries set status='posted',immutable=true,posted_by=u,posted_at=entry_date::timestamptz where id in (j0,j1,jt,j2);
  insert into public.accounting_events(company_id,event_type,source_entity_type,source_entity_id,accounting_date,occurred_at,payload,requested_lines,status,journal_entry_id,posted_at) values
    (c,'sale_confirmed','fixture',gen_random_uuid(),'2026-07-10','2026-07-10','{}','[{"role":"vat_pending","debit":0,"credit":16}]','posted',jt,'2026-07-20'),
    (c,'receivable_payment_confirmed','fixture',gen_random_uuid(),'2026-07-15','2026-07-15','{}','[{"role":"vat_pending","debit":8,"credit":0},{"role":"vat_collected","debit":0,"credit":8}]','posted',jt,'2026-07-20'),
    (c,'supplier_payment_confirmed','fixture',gen_random_uuid(),'2026-07-16','2026-07-16','{}','[{"role":"vat_paid","debit":5,"credit":0},{"role":"vat_pending","debit":0,"credit":5}]','posted',jt,'2026-07-20'),
    (c,'supplier_invoice_confirmed','fixture',gen_random_uuid(),'2026-07-17','2026-07-17','{}','[{"role":"withholdings","debit":0,"credit":3}]','posted',jt,'2026-07-20');

  insert into public.customers(id,company_id,code,display_name,credit_enabled,credit_limit,credit_term_days) values(customer,c,'C1','Cliente M4D1',true,1000,30);
  insert into public.payment_methods(id,company_id,code,display_name,settlement_kind) values(method,c,'TR','Transferencia','external');
  insert into public.financial_accounts(id,company_id,institution_name,alias,currency_code,account_last4,created_by,updated_by) values(receiving_account,c,'Institución de prueba','Cobranza M4D1','MXN','0056',u,u);
  insert into public.customer_receivables(id,company_id,customer_id,issued_at,due_date,original_amount,outstanding_amount,source_kind,source_document_key,source_row_hash,source_cutoff_date) values(receivable,c,customer,'2026-07-01','2026-08-01',100,20,'alpha_document','M4D1-CXC',repeat('c',64),'2026-07-01');
  insert into public.receivable_payments(id,company_id,customer_id,payment_method_id,payment_method_code,settlement_kind,amount,client_request_id,received_by,received_at,financial_account_id,currency_code,bank_reference) values
    (rp1,c,customer,method,'TR','external',40,gen_random_uuid(),u,'2026-07-10',receiving_account,'MXN','M4D1-RP1'),(rp2,c,customer,method,'TR','external',10,gen_random_uuid(),u,'2026-07-20',receiving_account,'MXN','M4D1-RP2'),(rp3,c,customer,method,'TR','external',20,gen_random_uuid(),u,'2026-08-02',receiving_account,'MXN','M4D1-RP3');
  insert into public.receivable_payment_applications(receivable_payment_id,receivable_id,amount,created_at) values(rp1,receivable,40,'2026-07-10'),(rp2,receivable,10,'2026-07-20'),(rp3,receivable,20,'2026-08-02');
  insert into public.receivable_payment_reversals(company_id,receivable_payment_id,reason,client_request_id,reversed_by,reversed_at) values(c,rp1,'Posterior',gen_random_uuid(),u,'2026-08-05'),(c,rp2,'Anterior',gen_random_uuid(),u,'2026-07-25');

  insert into public.suppliers(id,company_id,code,display_name,country_code) values(supplier,c,'P1','Proveedor M4D1','US');
  insert into public.supplier_invoices(id,company_id,supplier_id,document_type,original_invoice_id,status,folio,issued_date,due_date,currency_code,subtotal,tax_total,total,confirmed_at,source_kind,exchange_rate,base_currency_code,base_total) values
    (invoice,c,supplier,'invoice',null,'confirmed','F1','2026-07-01','2026-08-01','MXN',180,20,200,'2026-07-01','expense',1,'MXN',200),
    (credit,c,supplier,'credit_note',invoice,'confirmed','NC1','2026-07-05','2026-07-05','MXN',20,0,20,'2026-07-05','expense',1,'MXN',20);
  insert into public.accounts_payable(id,company_id,supplier_id,supplier_invoice_id,currency_code,original_amount,outstanding_amount,issued_date,due_date,exchange_rate,base_currency_code) values(payable,c,supplier,invoice,'MXN',200,110,'2026-07-01','2026-08-01',1,'MXN');
  insert into public.supplier_paying_accounts(id,company_id,bank_name,alias,currency_code,account_last4) values(paying,c,'Banco fixture','Operativa','MXN','0001');
  insert into public.supplier_payment_proposals(id,company_id,supplier_id,currency_code,status,total_proposed,approved_at,approved_by) values
    (gen_random_uuid(),c,supplier,'MXN','approved',50,'2026-07-10',u),(gen_random_uuid(),c,supplier,'MXN','approved',30,'2026-07-15',u),(gen_random_uuid(),c,supplier,'MXN','approved',10,'2026-08-02',u);
  insert into public.supplier_payments(id,company_id,proposal_id,supplier_id,paying_account_id,currency_code,effective_date,payment_method,reference,total_amount,status,confirmed_at,reversed_at,reversed_by,reversal_reason) values
    (sp1,c,(select id from public.supplier_payment_proposals where company_id=c and total_proposed=50),supplier,paying,'MXN','2026-07-10','03','SP1',50,'reversed','2026-07-10','2026-08-05',u,'Posterior'),
    (sp2,c,(select id from public.supplier_payment_proposals where company_id=c and total_proposed=30),supplier,paying,'MXN','2026-07-15','03','SP2',30,'reversed','2026-07-15','2026-07-20',u,'Anterior'),
    (sp3,c,(select id from public.supplier_payment_proposals where company_id=c and total_proposed=10),supplier,paying,'MXN','2026-08-02','03','SP3',10,'confirmed','2026-08-02',null,null,null);
  insert into public.supplier_payment_applications(company_id,payment_id,accounts_payable_id,supplier_invoice_id,amount,balance_before,balance_after,applied_at) values
    (c,sp1,payable,invoice,50,200,150,'2026-07-10'),(c,sp2,payable,invoice,30,150,120,'2026-07-15'),(c,sp3,payable,invoice,10,120,110,'2026-08-02');

  insert into public.locations(id,company_id,external_code,name,location_type,classification_source) values(location,c,'L1','Almacén M4D1','almacen_operativo','manual_review');
  insert into public.products(id,company_id,internal_sku,name,is_inventory_tracked) values(product,c,'SKU-M4D1','Producto M4D1',true);
  insert into public.product_costs(company_id,product_id,cost_type,amount,currency_code,valid_from,valid_to) values(c,product,'replacement_cost',5,'MXN','2026-01-01','2026-08-01'),(c,product,'replacement_cost',7,'MXN','2026-08-01',null);
  insert into public.inventory_ledger(company_id,location_id,product_id,quantity_delta,balance_after,movement_type,occurred_at,actor_id) values(c,location,product,10,10,'controlled_adjustment','2026-07-01',u),(c,location,product,-2,8,'controlled_adjustment','2026-08-03',u);
  insert into public.cash_registers(id,company_id,location_id,code,display_name) values(register_id,c,location,'CAJA-1','Caja M4D1');
  insert into public.cash_sessions(id,company_id,cash_register_id,location_id,opened_by,opened_at,status,opening_amount) values(session_id,c,register_id,location,u,'2026-07-01','open',100);
  insert into public.cash_movements(company_id,cash_session_id,movement_type,amount,occurred_at,actor_id) values(c,session_id,'opening',100,'2026-07-01',u),(c,session_id,'paid_in',20,'2026-07-10',u),(c,session_id,'paid_out',-10,'2026-07-20',u),(c,session_id,'paid_out',-40,'2026-08-02',u);

  insert into public.bank_statement_batches(id,company_id,financial_account_id,content_sha256,original_name,period_start,period_end,currency_code,opening_balance,closing_balance,total_credits,total_debits,calculated_closing_balance,balance_difference,balance_valid,status,row_count,exception_count,promoted_by,promoted_at)
  values(batch,c,paying,repeat('a',64),'m4d1.csv','2026-07-01','2026-07-31','MXN',875,1000,175,50,1000,0,true,'promoted',3,0,u,'2026-07-31');
  insert into public.bank_statement_staging_rows(id,batch_id,company_id,row_number,transaction_date,reference,credit,debit,row_sha256,raw_data,validation_status) values
    (gen_random_uuid(),batch,c,1,'2026-07-10','B1',100,0,repeat('1',64),'{}','valid'),(gen_random_uuid(),batch,c,2,'2026-07-11','B2',0,50,repeat('2',64),'{}','valid'),(gen_random_uuid(),batch,c,3,'2026-07-12','B3',25,0,repeat('3',64),'{}','valid');
  insert into public.bank_transactions(id,company_id,financial_account_id,statement_batch_id,source_row_id,transaction_date,reference,direction,amount,currency_code,row_sha256) select bt1,c,paying,batch,id,transaction_date,reference,'credit',100,'MXN',row_sha256 from public.bank_statement_staging_rows where batch_id=batch and row_number=1;
  insert into public.bank_transactions(id,company_id,financial_account_id,statement_batch_id,source_row_id,transaction_date,reference,direction,amount,currency_code,row_sha256) select bt2,c,paying,batch,id,transaction_date,reference,'debit',50,'MXN',row_sha256 from public.bank_statement_staging_rows where batch_id=batch and row_number=2;
  insert into public.bank_transactions(id,company_id,financial_account_id,statement_batch_id,source_row_id,transaction_date,reference,direction,amount,currency_code,row_sha256) select bt3,c,paying,batch,id,transaction_date,reference,'credit',25,'MXN',row_sha256 from public.bank_statement_staging_rows where batch_id=batch and row_number=3;
  insert into public.bank_reconciliations(company_id,bank_transaction_id,source_type,source_id,status,match_quality,confirmed_by,confirmed_at) values(c,bt1,'supplier_payment',sp1,'confirmed','exact',u,'2026-07-15');
  insert into public.bank_reconciliations(company_id,bank_transaction_id,source_type,source_id,status,match_quality,confirmed_by,confirmed_at,disconnected_by,disconnected_at,disconnection_reason) values(c,bt2,'supplier_payment',sp2,'disconnected','exact',u,'2026-07-15',u,'2026-07-20','Desconexión controlada');

  select amount,detail into a,d from public.canonical_accounting_auxiliaries(c,'2026-07-31') where control_key='accounts_receivable';if a<>60 then raise exception 'CxC histórica incorrecta: %',a;end if;
  select amount into a from public.canonical_accounting_auxiliaries(c,'2026-07-31') where control_key='accounts_payable';if a<>130 then raise exception 'CxP histórica incorrecta: %',a;end if;
  select amount into a from public.canonical_accounting_auxiliaries(c,'2026-07-31') where control_key='inventory';if a<>50 then raise exception 'Inventario histórico incorrecto: %',a;end if;
  select amount into a from public.canonical_accounting_auxiliaries(c,'2026-07-31') where control_key='cash';if a<>110 then raise exception 'Caja histórica incorrecta: %',a;end if;
  select amount,detail into a,d from public.canonical_accounting_auxiliaries(c,'2026-07-31') where control_key='banks';
  if a<>1000 or d->>'reconciliation_status'<>'confirmed' or (d->>'reconciled_movements')::int<>1 or (d->>'disconnected_movements')::int<>1 or (d->>'pending_movements')::int<>1 then raise exception 'Banco histórico/confirmed incorrecto: %, %',a,d;end if;
  select amount into a from public.canonical_accounting_auxiliaries(c,'2026-07-31') where control_key='vat_pending';if a<>13 then raise exception 'IVA pendiente incorrecto: %',a;end if;
  select amount into a from public.canonical_accounting_auxiliaries(c,'2026-07-31') where control_key='vat_collected';if a<>8 then raise exception 'IVA cobrado incorrecto: %',a;end if;
  select amount into a from public.canonical_accounting_auxiliaries(c,'2026-07-31') where control_key='vat_paid';if a<>5 then raise exception 'IVA pagado incorrecto: %',a;end if;
  select amount into a from public.canonical_accounting_auxiliaries(c,'2026-07-31') where control_key='withholdings';if a<>3 then raise exception 'Retenciones incorrectas: %',a;end if;

  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);
  r:=public.list_accounting_report(c,'general_ledger','2026-07-01','2026-07-31',cash,1,50);
  if (r->>'total')::int<>1 or (r#>>'{rows,0,opening_balance}')::numeric<>100 or (r#>>'{rows,0,running_balance}')::numeric<>160 then raise exception 'Mayor/saldo anterior incorrecto: %',r;end if;
  r:=public.list_accounting_report(c,'trial_balance','2026-07-01','2026-07-31',null,1,50);
  if (r#>>'{totals,debit}')::numeric<>152 or (r#>>'{totals,credit}')::numeric<>152 or (select (x->>'ending_balance')::numeric from jsonb_array_elements(r->'rows')x where x->>'account_id'=ap::text)<>20 then raise exception 'Balanza/naturaleza incorrecta: %',r;end if;
  r:=public.list_accounting_report(c,'income_statement','2026-07-01','2026-07-31',null,1,50);
  if (r#>>'{totals,revenue}')::numeric<>100 or (r#>>'{totals,expense}')::numeric<>63 or (r#>>'{totals,net_income}')::numeric<>37 then raise exception 'Resultados acumuló fuera del periodo: %',r;end if;
  r:=public.list_accounting_report(c,'balance_sheet','2026-07-01','2026-07-31',null,1,50);
  if not (r->>'balanced')::boolean or (r#>>'{totals,assets}')::numeric<>181 or (r#>>'{totals,liabilities_and_equity}')::numeric<>181 or not exists(select 1 from jsonb_array_elements(r->'rows')x where x->>'code'='RESULTADO-EJERCICIO' and (x->>'ending_balance')::numeric=37) then raise exception 'Balance general no cuadra: %',r;end if;
  r:=public.list_accounting_report(c,'cash_flow','2026-07-01','2026-07-31',null,1,50);if (r#>>'{totals,inflows}')::numeric<>60 or (r#>>'{totals,outflows}')::numeric<>0 then raise exception 'Flujo básico incorrecto: %',r;end if;
  r:=public.list_accounting_report(c,'auxiliaries','2026-07-01','2026-07-31',null,2,4);if (r->>'total')::int<>9 or jsonb_array_length(r->'rows')<>4 then raise exception 'Auxiliares no paginan exactamente: %',r;end if;

  perform set_config('request.jwt.claim.sub',outsider::text,true);
  begin perform public.list_accounting_report(c,'trial_balance','2026-07-01','2026-07-31');raise exception 'RLS/RPC permitió empresa ajena';exception when others then if position('no autorizado' in lower(sqlerrm))=0 then raise;end if;end;
  if has_function_privilege('anon','public.list_accounting_report(uuid,text,date,date,uuid,integer,integer)','execute') then raise exception 'Reporte expuesto a anon.';end if;
  raise notice 'M4D1: corte histórico, parciales, reversas, inventario, caja, banco confirmed/disconnected/pending, IVA, mayor, balanza, resultados, balance, flujo, paginación y RLS aprobados.';
end;$m4d1$;
rollback;
