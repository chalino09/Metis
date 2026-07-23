begin;
do $setup$
declare
  c uuid:='4d020000-0000-4000-8000-000000000001';u uuid:='4d020000-0000-4000-8000-000000000002';outsider uuid:='4d020000-0000-4000-8000-000000000003';
  supplier uuid:='4d020000-0000-4000-8000-000000000010';invoice uuid:='4d020000-0000-4000-8000-000000000011';missing_invoice uuid:='4d020000-0000-4000-8000-000000000012';volume_invoice uuid:='4d020000-0000-4000-8000-000000000013';
  cat_a uuid:='4d020000-0000-4000-8000-000000000020';cat_b uuid:='4d020000-0000-4000-8000-000000000021';cat_versioned uuid:='4d020000-0000-4000-8000-000000000022';
  expense_a uuid;expense_b uuid;unused_account uuid;used_entry uuid;cfg uuid;rs uuid;role_name text;role_account uuid;controls jsonb;r jsonb;expected timestamptz;credit uuid;
begin
  insert into public.companies(id,legal_name,display_name) values(c,'M4D2 controlada','M4D2 controlada');
  insert into auth.users(id,aud,role,email,encrypted_password) values(u,'authenticated','authenticated','m4d2@example.com',''),(outsider,'authenticated','authenticated','outsider-m4d2@example.com','');
  insert into public.user_roles(user_id,role_id,company_id) select u,id,c from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);

  insert into public.accounting_accounts(company_id,code,name,account_type,normal_balance,level)
  select c,lpad(n::text,4,'0'),'Cuenta '||n,
    case when n in (11,12,13,14,15,16,17,18,19,20,21,22) then 'expense' when n in (2,6,7,9) then 'liability' else 'asset' end,
    case when n in (2,6,7,9) then 'credit' else 'debit' end,1
  from generate_series(1,24)n;
  select id into expense_a from public.accounting_accounts where company_id=c and code='0011';
  select id into expense_b from public.accounting_accounts where company_id=c and code='0012';
  select id,updated_at into unused_account,expected from public.accounting_accounts where company_id=c and code='0024';

  r:=public.save_accounting_account(c,unused_account,'0024','Cuenta editable', 'asset','debit',null,1,true,true,'Nombre comprensible',expected,'4d020000-0000-4000-8000-000000000030');
  if r->>'name'<>'Cuenta editable' then raise exception 'La cuenta sin movimientos no fue editable.';end if;

  select jsonb_object_agg(key_name,account.id) into controls
  from (values('accounts_receivable','0001'),('accounts_payable','0002'),('inventory','0003'),('cash','0004'),('banks','0005'),('vat_pending','0006'),('vat_collected','0007'),('vat_paid','0008'),('withholdings','0009')) value(key_name,code)
  join public.accounting_accounts account on account.company_id=c and account.code=value.code;
  r:=public.save_accounting_config(c,'MXN',current_date,'{"format":"4"}','{"vat_pending":"x","vat_collected":"x","vat_paid":"x","withholdings":"x"}',jsonb_build_object('adjustments',u,'close',u,'reopen',u),'M4D2',controls);
  cfg:=(r->>'id')::uuid;perform public.approve_accounting_config(cfg);
  perform public.create_accounting_period(c,to_char(current_date,'YYYY-MM'),date_trunc('month',current_date)::date,(date_trunc('month',current_date)+interval '1 month - 1 day')::date);
  r:=public.create_accounting_event_rule_set(c,'replacement_cost','{"expenses":"confirmation","inventory":"control"}','M4D2');rs:=(r->>'id')::uuid;
  for role_name in select unnest(array['sales_revenue','sales_discounts','cost_of_goods_sold','goods_received_not_invoiced','purchase_variance','supplier_expense','cash_opening_offset','cash_close_offset','cash_movement_offset','cash_over_short','supplier_credit_note_offset','inventory_adjustment']) loop
    select id into role_account from public.accounting_accounts where company_id=c and code=lpad((10+(select count(*) from public.accounting_event_role_accounts where rule_set_id=rs)+1)::text,4,'0');
    perform public.set_accounting_event_role_account(rs,role_name,role_account);
  end loop;
  perform public.approve_accounting_event_rule_set(rs,'Matriz M4D2');

  perform public.save_accounting_expense_category(c,cat_a,'CAT-A','Categoría A',expense_a,'active',current_date-10,'Alta A','4d020000-0000-4000-8000-000000000031');
  perform public.save_accounting_expense_category(c,cat_b,'CAT-B','Categoría B',expense_b,'active',current_date-10,'Alta B','4d020000-0000-4000-8000-000000000032');
  perform public.save_accounting_expense_category(c,cat_versioned,'CAT-V','Versión uno',expense_a,'active',current_date-30,'Alta versionada','4d020000-0000-4000-8000-000000000033');
  perform public.save_accounting_expense_category(c,cat_versioned,'CAT-V','Versión dos',expense_b,'active',current_date-20,'Cambio de cuenta','4d020000-0000-4000-8000-000000000034');
  perform public.save_accounting_expense_category(c,cat_versioned,'CAT-V','Versión dos',expense_b,'inactive',current_date-10,'Desactivación','4d020000-0000-4000-8000-000000000035');

  insert into public.suppliers(id,company_id,code,display_name,country_code) values(supplier,c,'SUP-M4D2','Proveedor M4D2','US');
  insert into public.supplier_invoices(id,company_id,supplier_id,source_kind,status,folio,issued_date,due_date,currency_code,exchange_rate,base_currency_code,subtotal,tax_total,total,base_total,expense_approved_at,expense_approved_by)
  values
    (invoice,c,supplier,'expense','draft','EXP-1',current_date,current_date+30,'MXN',1,'MXN',300,48,348,348,now(),u),
    (missing_invoice,c,supplier,'expense','draft','EXP-MISSING',current_date,current_date+30,'MXN',1,'MXN',10,0,10,10,now(),u),
    (volume_invoice,c,supplier,'expense','draft','EXP-VOLUME',current_date,current_date+30,'MXN',1,'MXN',2500,0,2500,2500,now(),u);
  insert into public.supplier_invoice_expense_lines(company_id,supplier_invoice_id,line_number,product_service_code,quantity,unit_code,description,unit_value,subtotal,discount_amount,tax_amount,withheld_tax_amount,tax_object_code,tax_details,expense_category,cost_center_reference,project_reference)
  values
    (c,invoice,1,'01010101',1,'E48','Concepto A',100,100,0,16,0,'02','[]','Texto histórico A','CC-A','PROY-A'),
    (c,invoice,2,'01010101',1,'E48','Concepto B',200,200,0,32,0,'02','[]','Texto histórico B','CC-B','PROY-B'),
    (c,missing_invoice,1,'01010101',1,'E48','Pan no inferible',10,10,0,0,0,'02','[]',null,null,null);
  insert into public.supplier_invoice_expense_lines(company_id,supplier_invoice_id,line_number,product_service_code,quantity,unit_code,description,unit_value,subtotal,discount_amount,tax_amount,withheld_tax_amount,tax_object_code,tax_details,expense_category)
  select c,volume_invoice,n,'01010101',1,'E48','Volumen '||n,1,1,0,0,0,'02','[]','LOTE' from generate_series(1,2500)n;

  r:=public.bulk_assign_expense_category(c,cat_a,invoice,null,array[(select id from public.supplier_invoice_expense_lines where supplier_invoice_id=invoice and line_number=1)],1000,'4d020000-0000-4000-8000-000000000040');
  r:=public.bulk_assign_expense_category(c,cat_b,invoice,null,array[(select id from public.supplier_invoice_expense_lines where supplier_invoice_id=invoice and line_number=2)],1000,'4d020000-0000-4000-8000-000000000041');
  r:=public.bulk_assign_expense_category(c,cat_a,volume_invoice,'LOTE',null,1000,'4d020000-0000-4000-8000-000000000042');
  if (r->>'updated')::int<>1000 or (r->>'remaining')::int<>1500 then raise exception 'Primer lote incorrecto: %',r;end if;
  r:=public.bulk_assign_expense_category(c,cat_a,volume_invoice,'LOTE',null,1000,'4d020000-0000-4000-8000-000000000042');
  if not (r->>'idempotent')::boolean or (r->>'updated')::int<>1000 then raise exception 'Reintento masivo no idempotente: %',r;end if;
  perform public.bulk_assign_expense_category(c,cat_a,volume_invoice,'LOTE',null,1000,'4d020000-0000-4000-8000-000000000043');
  r:=public.bulk_assign_expense_category(c,cat_a,volume_invoice,'LOTE',null,1000,'4d020000-0000-4000-8000-000000000044');
  if (r->>'updated')::int<>500 or (r->>'remaining')::int<>0 then raise exception 'Paginación masiva incorrecta: %',r;end if;

  begin
    perform public.confirm_supplier_invoice(c,missing_invoice,'4d020000-0000-4000-8000-000000000045');
    raise exception 'Se confirmó una categoría faltante.';
  exception when others then
    if position('clasificación pendiente' in lower(sqlerrm))=0 then raise;end if;
  end;
  perform public.confirm_supplier_invoice(c,invoice,'4d020000-0000-4000-8000-000000000046');
end
$setup$;

set constraints all immediate;

do $assert$
declare
  c uuid:='4d020000-0000-4000-8000-000000000001';u uuid:='4d020000-0000-4000-8000-000000000002';outsider uuid:='4d020000-0000-4000-8000-000000000003';
  invoice uuid:='4d020000-0000-4000-8000-000000000011';missing_invoice uuid:='4d020000-0000-4000-8000-000000000012';volume_invoice uuid:='4d020000-0000-4000-8000-000000000013';
  cat_versioned uuid:='4d020000-0000-4000-8000-000000000022';expense_a uuid;expense_b uuid;credit_note_id uuid;result jsonb;expected timestamptz;
begin
  select id into expense_a from public.accounting_accounts where company_id=c and code='0011';
  select id into expense_b from public.accounting_accounts where company_id=c and code='0012';
  if (select count(*) from public.accounting_expense_category_versions where category_id=cat_versioned)<>3 or (select status from public.accounting_expense_category_versions where category_id=cat_versioned and valid_to is null)<>'inactive' then raise exception 'Categoría no quedó versionada y desactivada.';end if;
  if (select count(distinct resolved_account_id) from public.supplier_invoice_expense_lines where supplier_invoice_id=invoice)<>2 then raise exception 'La factura no conservó varias categorías.';end if;
  if not exists(select 1 from public.supplier_invoice_expense_lines where supplier_invoice_id=invoice and expense_category='Texto histórico A' and cost_center_reference='CC-A' and project_reference='PROY-A') then raise exception 'Se perdió texto histórico de gasto.';end if;
  if (select count(*) from public.supplier_invoice_expense_lines where supplier_invoice_id=volume_invoice and expense_category_id is not null)<>2500 then raise exception 'La asignación masiva no cubrió 2,500 conceptos.';end if;
  if (select count(*) from public.audit_log where company_id=c and action='accounting.expense_category_bulk_assigned' and metadata#>>'{selector,invoice_id}'=volume_invoice::text)<>3 then raise exception 'El reintento duplicó auditoría masiva.';end if;
  if not exists(
    select 1 from public.accounting_events event join public.accounting_journal_entries journal on journal.id=event.journal_entry_id
    join public.accounting_journal_lines line on line.journal_entry_id=journal.id
    where event.source_entity_id=invoice and line.account_id=expense_a and line.debit=100 and line.expense_category_version_id is not null
  ) or not exists(
    select 1 from public.accounting_events event join public.accounting_journal_entries journal on journal.id=event.journal_entry_id
    join public.accounting_journal_lines line on line.journal_entry_id=journal.id
    where event.source_entity_id=invoice and line.account_id=expense_b and line.debit=200 and line.expense_category_version_id is not null
  ) then raise exception 'El gasto no se contabilizó automáticamente por categoría.';end if;

  result:=public.create_supplier_credit_note(c,invoice,null,'NC-M4D2',null,current_date,60,'Bonificación clasificada','4d020000-0000-4000-8000-000000000050');credit_note_id:=(result->>'credit_note_id')::uuid;
  if not exists(
    select 1 from public.accounting_events event join public.accounting_journal_entries journal on journal.id=event.journal_entry_id
    join public.accounting_journal_lines line on line.journal_entry_id=journal.id
    where event.source_entity_id=credit_note_id and line.account_id=expense_a and line.credit=20 and line.expense_category_version_id is not null
  ) or not exists(
    select 1 from public.accounting_events event join public.accounting_journal_entries journal on journal.id=event.journal_entry_id
    join public.accounting_journal_lines line on line.journal_entry_id=journal.id
    where event.source_entity_id=credit_note_id and line.account_id=expense_b and line.credit=40 and line.expense_category_version_id is not null
  ) then raise exception 'La nota de crédito no invirtió la clasificación original.';end if;
  perform public.reverse_supplier_credit_note(c,credit_note_id,'Reversa exacta','4d020000-0000-4000-8000-000000000051');
  if exists(
    select line.account_id from public.accounting_events event join public.accounting_journal_entries journal on journal.accounting_event_id=event.id
    join public.accounting_journal_lines line on line.journal_entry_id=journal.id
    where event.source_entity_type='supplier_invoice' and event.source_entity_id=credit_note_id
    group by line.account_id having abs(sum(line.debit-line.credit))>0.000001
  ) then raise exception 'La reversa de nota no neutralizó cuentas originales.';end if;
  perform public.reverse_supplier_invoice(c,invoice,'Reversa exacta de factura','4d020000-0000-4000-8000-000000000052');
  if exists(
    select line.account_id from public.accounting_events event join public.accounting_journal_entries journal on journal.accounting_event_id=event.id
    join public.accounting_journal_lines line on line.journal_entry_id=journal.id
    where event.source_entity_type='supplier_invoice' and event.source_entity_id=invoice
    group by line.account_id having abs(sum(line.debit-line.credit))>0.000001
  ) then raise exception 'La reversa de gasto no neutralizó clasificación original.';end if;

  select updated_at into expected from public.accounting_accounts where id=expense_a;
  result:=public.save_accounting_account(c,expense_a,'0011','Gasto comprensible renombrado','expense','debit',null,1,true,true,'Renombre permitido',expected,'4d020000-0000-4000-8000-000000000053');
  if result->>'name'<>'Gasto comprensible renombrado' then raise exception 'No se permitió renombrar cuenta utilizada.';end if;
  select updated_at into expected from public.accounting_accounts where id=expense_a;
  begin
    perform public.save_accounting_account(c,expense_a,'0011','Cambio inválido','asset','debit',null,1,true,true,'Cambio estructural',expected,'4d020000-0000-4000-8000-000000000054');
    raise exception 'Se alteró estructuralmente una cuenta utilizada.';
  exception when others then
    if position('históricos' in lower(sqlerrm))=0 then raise;end if;
  end;

  if exists(select 1 from information_schema.columns where table_schema='public' and table_name='products' and column_name in ('account_id','inventory_account_id','cost_of_goods_sold_account_id')) then raise exception 'M4D2 agregó asignación contable manual por producto.';end if;
  if not exists(select 1 from public.accounting_events where company_id=c and event_type='supplier_invoice_confirmed' and payload->>'classification'='explicit_expense_category') then raise exception 'Falta trazabilidad línea → evento.';end if;
  if (public.list_expense_classification_work(c,1,50)#>>'{pagination,total}')::int<1 then raise exception 'La excepción faltante no aparece agrupada.';end if;

  perform set_config('request.jwt.claim.sub',outsider::text,true);
  begin perform public.list_expense_classification_work(c,1,50);raise exception 'Aislamiento multiempresa roto.';exception when others then if position('no autorizado' in lower(sqlerrm))=0 then raise;end if;end;
  if has_function_privilege('anon','public.save_accounting_expense_category(uuid,uuid,text,text,uuid,text,date,text,uuid)','execute') or has_function_privilege('anon','public.bulk_assign_expense_category(uuid,uuid,uuid,text,uuid[],integer,uuid)','execute') then raise exception 'RPC M4D2 expuesto a anon.';end if;
  if to_regclass('public.cost_centers') is not null or to_regclass('public.projects') is not null or to_regclass('public.product_accounting_profiles') is not null then raise exception 'M4D2 duplicó centros, proyectos o perfiles sin evidencia.';end if;
  raise notice 'M4D2: cuentas seguras, categorías versionadas, gasto multilínea, bloqueo explícito, volumen, nota, reversa, RLS y no asignación por producto aprobados.';
end
$assert$;
rollback;
