begin;

do $setup$
declare
  c uuid:='4d030000-0000-4000-8000-000000000001';
  u1 uuid:='4d030000-0000-4000-8000-000000000002';
  u2 uuid:='4d030000-0000-4000-8000-000000000003';
  limited_user uuid:='4d030000-0000-4000-8000-000000000004';
  outsider uuid:='4d030000-0000-4000-8000-000000000005';
  la uuid:='4d030000-0000-4000-8000-000000000010';
  lb uuid:='4d030000-0000-4000-8000-000000000011';
  lc uuid:='4d030000-0000-4000-8000-000000000012';
  ra uuid:='4d030000-0000-4000-8000-000000000020';
  rb uuid:='4d030000-0000-4000-8000-000000000021';
  rc uuid:='4d030000-0000-4000-8000-000000000022';
  sa uuid:='4d030000-0000-4000-8000-000000000030';
  sb uuid:='4d030000-0000-4000-8000-000000000031';
  sc uuid:='4d030000-0000-4000-8000-000000000032';
  cfg uuid:='4d030000-0000-4000-8000-000000000040';
  rules uuid:='4d030000-0000-4000-8000-000000000041';
  cash_method uuid:='4d030000-0000-4000-8000-000000000050';
  external_method uuid:='4d030000-0000-4000-8000-000000000051';
  customer uuid:='4d030000-0000-4000-8000-000000000052';
  sale_id uuid:='4d030000-0000-4000-8000-000000000053';
  product_id uuid:='4d030000-0000-4000-8000-000000000056';
  cash_payment uuid:='4d030000-0000-4000-8000-000000000054';
  external_payment uuid:='4d030000-0000-4000-8000-000000000055';
  receiving_account uuid:='4d030000-0000-4000-8000-000000000057';
  supplier uuid:='4d030000-0000-4000-8000-000000000060';
  invoice uuid:='4d030000-0000-4000-8000-000000000061';
  expense_a uuid:='4d030000-0000-4000-8000-000000000062';
  expense_b uuid:='4d030000-0000-4000-8000-000000000063';
  cat_a uuid:='4d030000-0000-4000-8000-000000000064';
  cat_b uuid:='4d030000-0000-4000-8000-000000000065';
  account_id uuid;role_name text;n int;event_result jsonb;expense_lines jsonb;
begin
  insert into public.companies(id,legal_name,display_name,base_currency_code)
  values(c,'M4D3 controlada','M4D3 controlada','MXN');
  insert into auth.users(id,aud,role,email,encrypted_password) values
    (u1,'authenticated','authenticated','m4d3-u1@example.com',''),
    (u2,'authenticated','authenticated','m4d3-u2@example.com',''),
    (limited_user,'authenticated','authenticated','m4d3-limited@example.com',''),
    (outsider,'authenticated','authenticated','m4d3-outsider@example.com','');
  insert into public.user_roles(user_id,role_id,company_id)
  select user_id,r.id,c from (values(u1),(u2))x(user_id) cross join public.roles r where r.code='direccion_admin';
  insert into public.user_roles(user_id,role_id,company_id)
  select limited_user,id,c from public.roles where code='punto_venta';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',u1::text,true);

  insert into public.locations(id,company_id,external_code,name,location_type) values
    (la,c,'LOC-A','Sucursal Norte','sucursal'),
    (lb,c,'LOC-B','Sucursal Sur','sucursal'),
    (lc,c,'LOC-C','Concentración existente','sucursal');
  insert into public.user_location_access(user_id,location_id) values(limited_user,la);
  insert into public.cash_registers(id,company_id,location_id,code,display_name,currency_code) values
    (ra,c,la,'CAJA-A','Caja Norte','MXN'),
    (rb,c,lb,'CAJA-B','Caja Sur','MXN'),
    (rc,c,lc,'CAJA-C','Caja de concentración existente','MXN');

  insert into public.accounting_accounts(company_id,code,name,account_type,normal_balance,level)
  select c,lpad(g.value::text,4,'0'),'Cuenta M4D3 '||g.value,
    case when g.value in (2,6,7,9) then 'liability' when g.value in (15,16,17,18,19,20,21,22,23,24) then 'expense' else 'asset' end,
    case when g.value in (2,6,7,9) then 'credit' else 'debit' end,1
  from generate_series(1,30)g(value);
  insert into public.accounting_config_versions(id,company_id,version,status,base_currency,cutoff_date,
    catalog_structure,tax_treatment,responsibilities,change_reason,approved_by,approved_at)
  values(cfg,c,1,'approved','MXN',current_date,'{}','{}','{}','M4D3',u1,now());
  insert into public.accounting_control_accounts(config_version_id,company_id,control_key,account_id)
  select cfg,c,v.key,a.id from (values
    ('accounts_receivable','0001'),('accounts_payable','0002'),('inventory','0003'),('cash','0004'),
    ('banks','0005'),('vat_pending','0006'),('vat_collected','0007'),('vat_paid','0008'),('withholdings','0009')
  )v(key,code) join public.accounting_accounts a on a.company_id=c and a.code=v.code;
  insert into public.accounting_periods(company_id,period_code,starts_on,ends_on)
  values(c,to_char(current_date,'YYYY-MM'),date_trunc('month',current_date)::date,(date_trunc('month',current_date)+interval '1 month - 1 day')::date);
  insert into public.accounting_periods(company_id,period_code,starts_on,ends_on,status,closed_by,closed_at)
  values(c,to_char(current_date-interval '1 month','YYYY-MM'),(date_trunc('month',current_date)-interval '1 month')::date,
    (date_trunc('month',current_date)-interval '1 day')::date,'closed',u1,now());
  insert into public.accounting_event_rule_sets(id,company_id,accounting_config_version_id,version,status,cost_method,
    recognition_policy,reason,approved_by,approved_at)
  values(rules,c,cfg,1,'approved','replacement_cost','{}','M4D3',u1,now());
  n:=10;
  for role_name in select unnest(array['sales_revenue','sales_discounts','cost_of_goods_sold','goods_received_not_invoiced',
    'purchase_variance','supplier_expense','cash_opening_offset','cash_close_offset','cash_movement_offset',
    'cash_over_short','supplier_credit_note_offset','inventory_adjustment'])
  loop
    select id into account_id from public.accounting_accounts where company_id=c and code=lpad(n::text,4,'0');
    insert into public.accounting_event_role_accounts(rule_set_id,company_id,account_role,account_id)
    values(rules,c,role_name,account_id);n:=n+1;
  end loop;

  insert into public.payment_methods(id,company_id,code,display_name,settlement_kind) values
    (cash_method,c,'CASH','Efectivo','cash_drawer'),(external_method,c,'EXT','Externo','external');
  insert into public.financial_accounts(id,company_id,institution_name,alias,currency_code,account_last4,created_by,updated_by)
  values(receiving_account,c,'Institución de prueba','Cobranza M4D3','MXN','0057',u1,u1);
  insert into public.customers(id,company_id,code,display_name) values(customer,c,'CLI-M4D3','Cliente M4D3');
  insert into public.products(id,company_id,internal_sku,name) values(product_id,c,'SKU-M4D3','Producto M4D3');
  insert into public.product_costs(company_id,product_id,cost_type,amount,currency_code,valid_from)
  values(c,product_id,'replacement_cost',100,'MXN',now()-interval '1 day');

  insert into public.cash_sessions(id,company_id,cash_register_id,location_id,opened_by,opening_amount,open_request_id) values
    (sa,c,ra,la,u1,1000,'4d030000-0000-4000-8000-000000000070'),
    (sb,c,rb,lb,u2,500,'4d030000-0000-4000-8000-000000000071'),
    (sc,c,rc,lc,limited_user,100,'4d030000-0000-4000-8000-000000000072');
  insert into public.cash_movements(company_id,cash_session_id,movement_type,amount,actor_id) values
    (c,sa,'opening',1000,u1),(c,sb,'opening',500,u1),(c,sc,'opening',100,u1);

  insert into public.sales(id,company_id,location_id,cash_register_id,cash_session_id,cashier_id,sale_type,
    currency_code,subtotal_amount,discount_amount,tax_amount,total_amount,client_request_id)
  values(sale_id,c,la,ra,sa,u1,'cash','MXN',250,0,0,250,'4d030000-0000-4000-8000-000000000073');
  insert into public.sale_items(sale_id,product_id,product_code,product_name,quantity,unit_price_amount,gross_amount,
    discount_percent,discount_amount,taxable_amount,tax_amount,total_amount)
  values(sale_id,product_id,'SKU-M4D3','Producto M4D3',1,250,250,0,0,250,0,250);
  insert into public.sale_payments(sale_id,payment_method_id,payment_method_code,settlement_kind,received_amount,change_amount,applied_amount)
  values(sale_id,cash_method,'CASH','cash_drawer',250,0,250);
  insert into public.cash_movements(company_id,cash_session_id,movement_type,amount,actor_id,source_entity_type,source_entity_id)
  values(c,sa,'cash_sale',250,u1,'sales',sale_id);

  insert into public.receivable_payments(id,company_id,customer_id,payment_method_id,payment_method_code,settlement_kind,
    cash_session_id,amount,client_request_id,received_by,financial_account_id,currency_code,bank_reference)
  values
    (cash_payment,c,customer,cash_method,'CASH','cash_drawer',sa,125,'4d030000-0000-4000-8000-000000000074',u1,null,null,null),
    (external_payment,c,customer,external_method,'EXT','external',null,80,'4d030000-0000-4000-8000-000000000075',u1,receiving_account,'MXN','M4D3-EXT-001');
  insert into public.cash_movements(company_id,cash_session_id,movement_type,amount,actor_id,source_entity_type,source_entity_id)
  values(c,sa,'receivable_payment',125,u1,'receivable_payments',cash_payment);

  select id into expense_a from public.accounting_accounts where company_id=c and code='0023';
  select id into expense_b from public.accounting_accounts where company_id=c and code='0024';
  insert into public.accounting_expense_category_versions(id,company_id,category_id,version,code,display_name,account_id,status,valid_from,change_reason)
  values
    ('4d030000-0000-4000-8000-000000000066',c,cat_a,1,'GA','Gasto A',expense_a,'active',current_date,'M4D3'),
    ('4d030000-0000-4000-8000-000000000067',c,cat_b,1,'GB','Gasto B',expense_b,'active',current_date,'M4D3');
  insert into public.suppliers(id,company_id,code,display_name,country_code) values(supplier,c,'SUP-M4D3','Proveedor M4D3','MX');
  insert into public.supplier_invoices(id,company_id,supplier_id,source_kind,status,folio,issued_date,due_date,
    currency_code,exchange_rate,base_currency_code,subtotal,tax_total,total,base_total)
  values(invoice,c,supplier,'expense','draft','EXP-M4D3',current_date,current_date+30,'MXN',1,'MXN',300,0,300,300);
  insert into public.supplier_invoice_expense_lines(company_id,supplier_invoice_id,line_number,description,subtotal,
    discount_amount,tax_amount,expense_category,cost_center_reference,project_reference,expense_category_id,
    expense_category_version_id,resolved_account_id,classification_reason,location_id)
  values
    (c,invoice,1,'Concepto Norte',100,0,0,'Histórico A','CC-A','PROY-A',cat_a,'4d030000-0000-4000-8000-000000000066',expense_a,'Explícita',la),
    (c,invoice,2,'Concepto Sur',200,0,0,'Histórico B','CC-B','PROY-B',cat_b,'4d030000-0000-4000-8000-000000000067',expense_b,'Explícita',lb);
  expense_lines:=public.build_expense_accounting_lines(invoice,300,'debit')||
    jsonb_build_array(jsonb_build_object('role','accounts_payable','debit',0,'credit',300,'description','CxP sin reparto'));
  event_result:=public.capture_accounting_event(c,'supplier_invoice_confirmed','supplier_invoice',invoice,1,current_date,now(),
    expense_lines,jsonb_build_object('description','Gasto M4D3'));

  -- Documento desconocido: no se inventa ubicación.
  perform public.capture_accounting_event(c,'cash_movement_recorded','unknown_document',
    '4d030000-0000-4000-8000-000000000068',1,current_date,now(),jsonb_build_array(
      jsonb_build_object('account_id',expense_a,'debit',10,'credit',0,'description','Sin asignar'),
      jsonb_build_object('account_id',expense_b,'debit',0,'credit',10,'description','Sin asignar')),
    jsonb_build_object('description','Movimiento histórico sin relación'));

  -- Cerrar no retira efectivo: conteo y diferencia cero.
  update public.cash_sessions set status='closed',expected_closing_amount=500,counted_closing_amount=500,
    variance_amount=0,closed_at=now(),close_requested_by=u2,close_request_id='4d030000-0000-4000-8000-000000000076'
  where id=sb;
end
$setup$;

set constraints all immediate;

do $assert_origin$
declare
  c uuid:='4d030000-0000-4000-8000-000000000001';la uuid:='4d030000-0000-4000-8000-000000000010';
  lb uuid:='4d030000-0000-4000-8000-000000000011';ra uuid:='4d030000-0000-4000-8000-000000000020';
  rb uuid:='4d030000-0000-4000-8000-000000000021';sa uuid:='4d030000-0000-4000-8000-000000000030';
  sale_id uuid:='4d030000-0000-4000-8000-000000000053';cash_payment uuid:='4d030000-0000-4000-8000-000000000054';
  external_payment uuid:='4d030000-0000-4000-8000-000000000055';invoice uuid:='4d030000-0000-4000-8000-000000000061';
  result jsonb;
begin
  if public.cash_register_custody_balance_as_of(c,ra,now())<>1375
    or public.cash_register_custody_balance_as_of(c,rb,now())<>500 then
    raise exception 'Dos ubicaciones no conservaron saldos exactos e independientes.';
  end if;
  if not exists(select 1 from public.accounting_events where source_entity_type='sale' and source_entity_id=sale_id and location_id=la)
    or not exists(select 1 from public.accounting_journal_lines line join public.accounting_events event on event.journal_entry_id=line.journal_entry_id
      where event.source_entity_id=sale_id and line.location_id=la and line.debit=250) then
    raise exception 'La venta en efectivo no conservó sesión, caja y ubicación.';
  end if;
  if not exists(select 1 from public.accounting_events where source_entity_id=cash_payment and location_id=la)
    or exists(select 1 from public.cash_movements where source_entity_id=external_payment)
    or (select location_id from public.accounting_events where source_entity_id=external_payment) is not null then
    raise exception 'Abonos de caja/externo no respetaron su origen canónico.';
  end if;
  if (select count(distinct line.location_id) from public.accounting_journal_lines line join public.accounting_events event
      on event.journal_entry_id=line.journal_entry_id where event.source_entity_id=invoice and line.debit>0)<>2
    or not exists(select 1 from public.supplier_invoice_expense_lines where supplier_invoice_id=invoice
      and expense_category='Histórico A' and cost_center_reference='CC-A' and project_reference='PROY-A') then
    raise exception 'El gasto multilínea perdió ubicación o referencias M4D2.';
  end if;
  if exists(select 1 from public.accounting_events where source_entity_type='cash_session'
    and source_entity_id='4d030000-0000-4000-8000-000000000031' and event_type='cash_closed') then
    raise exception 'El cierre sin diferencia creó un traslado o vaciado ficticio.';
  end if;
  result:=public.list_unassigned_accounting_locations(c,null,null,1,10);
  if (result->>'total')::int<2 or result#>>'{rows,0,location_name}' is distinct from 'Sin asignar' then
    raise exception 'Los movimientos sin ubicación no se presentan como Sin asignar: %',result;
  end if;
  update public.locations set name='Sucursal Norte Renombrada' where id=la;
  if not exists(select 1 from public.accounting_events where source_entity_id=sale_id and location_id=la)
  then raise exception 'El cambio de nombre perdió identidad histórica.';end if;
end
$assert_origin$;

do $transfers_and_concentration$
declare
  c uuid:='4d030000-0000-4000-8000-000000000001';u1 uuid:='4d030000-0000-4000-8000-000000000002';
  u2 uuid:='4d030000-0000-4000-8000-000000000003';ra uuid:='4d030000-0000-4000-8000-000000000020';
  rb uuid:='4d030000-0000-4000-8000-000000000021';rc uuid:='4d030000-0000-4000-8000-000000000022';
  sa uuid:='4d030000-0000-4000-8000-000000000030';cash_a uuid;cash_b uuid;cash_c uuid;transit uuid;
  result jsonb;transfer_id uuid;v_batch_id uuid;line_a uuid;line_b uuid;event_count int;
begin
  select id into cash_a from public.accounting_accounts where company_id=c and code='0025';
  select id into cash_b from public.accounting_accounts where company_id=c and code='0026';
  select id into cash_c from public.accounting_accounts where company_id=c and code='0027';
  select id into transit from public.accounting_accounts where company_id=c and code='0028';
  perform public.configure_cash_custody_accounts(c,ra,cash_a,transit,'Cuenta aprobada A','4d030000-0000-4000-8000-000000000080');
  perform public.configure_cash_custody_accounts(c,rb,cash_b,transit,'Cuenta aprobada B','4d030000-0000-4000-8000-000000000081');
  perform public.configure_cash_custody_accounts(c,rc,cash_c,transit,'Cuenta aprobada C','4d030000-0000-4000-8000-000000000082');

  result:=public.prepare_cash_concentration(c,current_date,'MXN',rc,'4d030000-0000-4000-8000-000000000083');
  v_batch_id:=(result->>'id')::uuid;
  if (result->>'line_count')::int<>2 then raise exception 'La concentración no generó una partida por origen: %',result;end if;
  select line.id into line_a from public.cash_concentration_lines line where line.batch_id=v_batch_id and line.origin_cash_register_id=ra;
  select line.id into line_b from public.cash_concentration_lines line where line.batch_id=v_batch_id and line.origin_cash_register_id=rb;
  perform public.set_cash_concentration_exception(c,line_b,true,0,'Caja excluida con justificación','{"evidence":"acta"}',
    '4d030000-0000-4000-8000-000000000084');
  perform public.set_cash_concentration_exception(c,line_a,false,1000,'Se conserva fondo operativo','{"evidence":"política"}',
    '4d030000-0000-4000-8000-000000000085');
  if (select resulting_balance from public.cash_concentration_lines where id=line_a)<>375 then
    raise exception 'La reducción no preservó saldo anterior/propuesto/resultante.';end if;

  perform set_config('request.jwt.claim.sub',u2::text,true);
  perform public.approve_cash_concentration(c,v_batch_id,'Aprobación separada','4d030000-0000-4000-8000-000000000086');
  perform set_config('request.jwt.claim.sub',u1::text,true);
  insert into public.cash_movements(company_id,cash_session_id,movement_type,amount,actor_id,reason)
  values(c,sa,'paid_in',10,u1,'Cambio concurrente controlado');
  begin
    perform public.confirm_cash_concentration(c,v_batch_id,u2,'Concentración mensual','M4D3-MENSUAL','{"evidence":"recepción"}',
      '4d030000-0000-4000-8000-000000000087');
    raise exception 'La concentración ignoró el cambio concurrente.';
  exception when others then
    if position('saldo elegible cambió' in lower(sqlerrm))=0 then raise;end if;
  end;
  insert into public.cash_movements(company_id,cash_session_id,movement_type,amount,actor_id,reason)
  values(c,sa,'paid_out',-10,u1,'Restauración exacta para recalcular');
  result:=public.confirm_cash_concentration(c,v_batch_id,u2,'Concentración mensual','M4D3-MENSUAL','{"evidence":"recepción"}',
    '4d030000-0000-4000-8000-000000000087');
  if (result->>'confirmed_lines')::int<>1 then raise exception 'Confirmación masiva incorrecta: %',result;end if;
  result:=public.confirm_cash_concentration(c,v_batch_id,u2,'Concentración mensual','M4D3-MENSUAL','{"evidence":"recepción"}',
    '4d030000-0000-4000-8000-000000000087');
  if not (result->>'idempotent')::boolean then raise exception 'Reintento de concentración duplicó efectos.';end if;

  result:=public.prepare_cash_transfer(c,'MXN',rb,rc,200,current_date,u2,'Retiro de prueba','M4D3-TR-1',
    '{"evidence":"sobre sellado"}','4d030000-0000-4000-8000-000000000088');
  transfer_id:=(result->>'id')::uuid;
  perform set_config('request.jwt.claim.sub',u2::text,true);
  perform public.approve_cash_transfer(c,transfer_id,'Aprobación separada','4d030000-0000-4000-8000-000000000089');
  perform set_config('request.jwt.claim.sub',u1::text,true);
  perform public.confirm_cash_transfer_dispatch(c,transfer_id,'{"dispatch":"firmado"}','4d030000-0000-4000-8000-000000000090');
  if (select status from public.cash_custody_transfers where id=transfer_id)<>'in_transit'
    or (public.list_cash_transfers(c,'in_transit',null,null,null,1,10)->>'total')::int<>1 then
    raise exception 'El retiro pendiente de entrega no quedó representado.';
  end if;
  result:=public.confirm_cash_transfer(c,transfer_id,'{"receipt":"firmado"}','4d030000-0000-4000-8000-000000000091');
  if (result->>'status')<>'confirmed' or (select count(*) from public.accounting_journal_entries
    where id in ((result->>'journal_entry_id')::uuid,(result->>'receipt_journal_entry_id')::uuid) and status='posted')<>2 then
    raise exception 'El traslado no llegó a la caja central existente con pólizas confirmadas.';
  end if;
  select count(*) into event_count from public.accounting_events where source_entity_id=transfer_id;
  result:=public.confirm_cash_transfer(c,transfer_id,'{"receipt":"firmado"}','4d030000-0000-4000-8000-000000000091');
  if not (result->>'idempotent')::boolean or (select count(*) from public.accounting_events where source_entity_id=transfer_id)<>event_count
  then raise exception 'Reintento de traslado duplicó pólizas.';end if;
  perform public.reverse_cash_transfer(c,transfer_id,current_date,'Reversa exacta','4d030000-0000-4000-8000-000000000092');
  if exists(
    select line.account_id,line.location_id from public.accounting_events event
    join public.accounting_journal_lines line on line.journal_entry_id=event.journal_entry_id
    where event.source_entity_id=transfer_id group by line.account_id,line.location_id
    having abs(sum(line.debit-line.credit))>0.000001
  ) then raise exception 'La reversa no neutralizó cuentas, importes y ubicación.';end if;
  result:=public.reverse_cash_concentration(c,v_batch_id,current_date,'Reversa mensual exacta',
    '4d030000-0000-4000-8000-000000000097');
  if (result->>'status')<>'reversed' or (public.list_cash_concentrations(c,'reversed',1,10)->>'total')::int<>1
  then raise exception 'La concentración revertida no quedó consultable.';end if;

  -- Un periodo cerrado bloquea retiro retroactivo y deja el traslado aprobado.
  result:=public.prepare_cash_transfer(c,'MXN',rb,rc,50,current_date,u2,
    'Retroactivo bloqueado','M4D3-CLOSED','{}','4d030000-0000-4000-8000-000000000093');
  transfer_id:=(result->>'id')::uuid;
  perform set_config('request.jwt.claim.sub',u2::text,true);
  perform public.approve_cash_transfer(c,transfer_id,'Aprobación cerrada','4d030000-0000-4000-8000-000000000094');
  perform set_config('request.jwt.claim.sub',u1::text,true);
  update public.accounting_periods set status='closed',closed_by=u1,closed_at=now()
    where company_id=c and current_date between starts_on and ends_on;
  begin
    perform public.confirm_cash_transfer_dispatch(c,transfer_id,'{}','4d030000-0000-4000-8000-000000000095');
    raise exception 'El periodo cerrado aceptó un traslado retroactivo.';
  exception when others then
    if position('periodo inexistente o cerrado' in lower(sqlerrm))=0 then raise;end if;
  end;
end
$transfers_and_concentration$;

do $volume_pagination_rls$
declare
  c uuid:='4d030000-0000-4000-8000-000000000001';u1 uuid:='4d030000-0000-4000-8000-000000000002';
  limited_user uuid:='4d030000-0000-4000-8000-000000000004';outsider uuid:='4d030000-0000-4000-8000-000000000005';
  sa uuid:='4d030000-0000-4000-8000-000000000030';result jsonb;visible int;
begin
  insert into public.cash_movements(company_id,cash_session_id,movement_type,amount,actor_id,reason,occurred_at)
  select c,sa,'cash_sale',0.01,u1,'Volumen M4D3',now()-interval '1 second' from generate_series(1,10000);
  if (select count(*) from public.cash_movements where reason='Volumen M4D3')<>10000
  then raise exception 'No se probaron 10,000 movimientos.';end if;
  result:=public.list_cash_custody(c,current_date,'MXN',null,null,1,1);
  if (result->>'page_size')::int<>1 or (result->>'total')::int<>3
    or (result->>'total_amount')::numeric<>(475+500+1100) then
    raise exception 'Totales exactos/paginación no son independientes de la página: %',result;
  end if;
  result:=public.list_cash_concentration_lines(c,(select id from public.cash_concentration_batches where company_id=c),1,1);
  if (result->>'page_size')::int<>1 or (result->>'total')::int<>2 then raise exception 'Paginación de concentración incorrecta: %',result;end if;

  perform set_config('request.jwt.claim.sub',limited_user::text,true);
  set local role authenticated;
  select count(*) into visible from public.cash_registers where company_id=c;
  if visible<>1 then raise exception 'RLS por ubicación mostró % cajas.',visible;end if;
  if (public.list_cash_transfers(c,null,null,null,null,1,200)->>'total')::int<>0
  then raise exception 'La consulta amplió acceso silenciosamente entre ubicaciones.';end if;
  reset role;
  perform set_config('request.jwt.claim.sub',outsider::text,true);
  set local role authenticated;
  if exists(select 1 from public.cash_custody_transfers where company_id=c)
    or exists(select 1 from public.accounting_events where company_id=c) then
    raise exception 'RLS multiempresa expuso custodia o eventos.';
  end if;
  reset role;
end
$volume_pagination_rls$;

do $direct_immutability$
declare
  c uuid:='4d030000-0000-4000-8000-000000000001';u1 uuid:='4d030000-0000-4000-8000-000000000002';
  event_id uuid;line_id uuid;lb uuid:='4d030000-0000-4000-8000-000000000011';result jsonb;
begin
  perform set_config('request.jwt.claim.sub',u1::text,true);
  select event.id,line.id into event_id,line_id from public.accounting_events event
  join public.accounting_journal_lines line on line.journal_entry_id=event.journal_entry_id
  where event.company_id=c and line.location_id is null order by event.created_at limit 1;
  begin
    update public.accounting_journal_lines set location_id=lb where id=line_id;
    raise exception 'Se modificó directamente una póliza contabilizada.';
  exception when others then
    if position('inmutable' in lower(sqlerrm))=0 then raise;end if;
  end;
  result:=public.correct_accounting_location(c,event_id,line_id,lb,'Corrección documentada',
    '4d030000-0000-4000-8000-000000000096');
  if (result->>'corrected_location_id')::uuid<>lb or not exists(select 1 from public.audit_log
    where action='accounting.location_corrected' and metadata->>'request_id'='4d030000-0000-4000-8000-000000000096')
  then raise exception 'La corrección server-side no conservó motivo, usuario, fecha e idempotencia.';end if;
  result:=public.correct_accounting_location(c,event_id,line_id,lb,'Corrección documentada',
    '4d030000-0000-4000-8000-000000000096');
  if not (result->>'idempotent')::boolean then raise exception 'La corrección no fue idempotente.';end if;
end
$direct_immutability$;

do $final$
begin
  if exists(select 1 from pg_class where relnamespace='public'::regnamespace
    and relname ilike '%inge%' and relkind in ('r','p')) then raise exception 'M4D3 creó una dimensión inge.';end if;
  if exists(select 1 from public.locations where lower(name) like '%inge%')
    or exists(select 1 from public.cash_registers where lower(display_name) like '%inge%') then raise exception 'M4D3 reinterpretó al ingeniero.';end if;
  raise notice 'M4D3: ubicación, caja, abonos, custodia, concentración, reversa, periodo, volumen, paginación y RLS aprobados.';
end
$final$;

rollback;
