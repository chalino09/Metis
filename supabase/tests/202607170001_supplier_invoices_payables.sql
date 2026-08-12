begin;
set constraints all immediate;

do $test$
declare
  v_actor uuid;v_warehouse uuid:='39000000-0000-4000-8000-000000000098';v_outsider uuid:='39000000-0000-4000-8000-000000000099';
  v_company uuid:='39000000-0000-4000-8000-000000000001';v_other uuid:='39000000-0000-4000-8000-000000000002';
  v_supplier uuid;v_product uuid;v_location uuid;v_order uuid;v_order_line uuid;v_receipt uuid;v_receipt_line uuid;v_invoice_one uuid;v_invoice_two uuid;v_invoice_diff uuid;v_payable uuid;v_credit uuid;v_cfg uuid;v_rules uuid;v_account uuid;v_controls jsonb;v_role text;
  v_result jsonb;v_forbidden boolean:=false;v_inventory numeric;v_ledger bigint;v_cost_rows bigint;v_cost numeric;v_stage_payables bigint;v_stage_payments bigint;
  v_confirm_one uuid:='39000000-0000-4000-8000-000000000010';v_reverse_two uuid:='39000000-0000-4000-8000-000000000011';v_credit_key uuid:='39000000-0000-4000-8000-000000000012';
begin
  if to_regprocedure('public.confirm_supplier_invoice(uuid,uuid,uuid)') is null then raise exception 'Faltan RPC de M3D.';end if;
  select ur.user_id into v_actor from public.user_roles ur join public.roles r on r.id=ur.role_id where r.code='super_admin' limit 1;
  if v_actor is null then raise exception 'La prueba requiere Super Admin.';end if;
  select count(*) into v_stage_payables from public.alpha_purchasing_import_payable_documents;
  select count(*) into v_stage_payments from public.alpha_purchasing_import_payment_evidence;
  insert into public.companies(id,legal_name,display_name) values(v_company,'Facturas 3D','Facturas 3D'),(v_other,'Otra 3D','Otra 3D');
  insert into auth.users(id,aud,role,email,encrypted_password) values(v_warehouse,'authenticated','authenticated','almacen-3d@example.com',''),(v_outsider,'authenticated','authenticated','ajeno-3d@example.com','');
  insert into public.user_roles(user_id,role_id,company_id) select v_actor,id,v_company from public.roles where code='super_admin' on conflict do nothing;
  insert into public.user_roles(user_id,role_id,company_id) select v_warehouse,id,v_company from public.roles where code='almacen';
  insert into public.user_roles(user_id,role_id,company_id) select v_outsider,id,v_other from public.roles where code='almacen';
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',v_actor::text,true);
  insert into public.suppliers(company_id,code,display_name,legal_entity_type,country_code,is_active) values(v_company,'SUP-3D','Proveedor 3D','moral','MX',true) returning id into v_supplier;
  insert into public.products(company_id,alpha_sku,name,unit,product_type,is_active,is_inventory_tracked) values(v_company,'SKU-3D','Producto 3D','PZA','P. TERMINADO',true,true) returning id into v_product;
  insert into public.locations(company_id,external_code,name,location_type,is_active,classification_source) values(v_company,'ALM-3D','Almacén 3D','almacen_operativo',true,'manual_review') returning id into v_location;
  insert into public.accounting_accounts(company_id,code,name,account_type,normal_balance,level) select v_company,lpad(n::text,4,'0'),'Cuenta M4B '||n,case when n between 11 and 30 then 'expense' else 'asset' end,case when n in(2,7,9) or n between 11 and 30 then 'credit' else 'debit' end,1 from generate_series(1,30)n;
  select jsonb_object_agg(k,a.id) into v_controls from (values('accounts_receivable','0001'),('accounts_payable','0002'),('inventory','0003'),('cash','0004'),('banks','0005'),('vat_pending','0006'),('vat_collected','0007'),('vat_paid','0008'),('withholdings','0009'))x(k,code) join public.accounting_accounts a on a.company_id=v_company and a.code=x.code;
  v_result:=public.save_accounting_config(v_company,'MXN','2026-07-16','{"format":"4"}','{"vat_pending":"x","vat_collected":"x","vat_paid":"x","withholdings":"x"}',jsonb_build_object('adjustments',v_actor,'close',v_actor,'reopen',v_actor),'M4B compras',v_controls);v_cfg:=(v_result->>'id')::uuid;perform public.approve_accounting_config(v_cfg);perform public.create_accounting_period(v_company,'2026-07','2026-07-01','2026-07-31');if date_trunc('month',current_date)<>date '2026-07-01' then perform public.create_accounting_period(v_company,to_char(current_date,'YYYY-MM'),date_trunc('month',current_date)::date,(date_trunc('month',current_date)+interval '1 month'-interval '1 day')::date);end if;v_result:=public.create_accounting_event_rule_set(v_company,'replacement_cost','{"purchases":"confirmation"}','M4B compras');v_rules:=(v_result->>'id')::uuid;
  for v_role in select unnest(array['sales_revenue','sales_discounts','cost_of_goods_sold','goods_received_not_invoiced','purchase_variance','supplier_expense','cash_opening_offset','cash_close_offset','cash_movement_offset','cash_over_short','supplier_credit_note_offset','inventory_adjustment']) loop select id into v_account from public.accounting_accounts where company_id=v_company and code=lpad((10+(select count(*) from public.accounting_event_role_accounts where rule_set_id=v_rules)+1)::text,4,'0');perform public.set_accounting_event_role_account(v_rules,v_role,v_account);end loop;perform public.approve_accounting_event_rule_set(v_rules,'Matriz de prueba aprobada');

  v_result:=public.save_purchase_order(v_company,null,v_supplier,'MXN','2026-07-16',null,null,null,null,0,jsonb_build_array(jsonb_build_object('product_id',v_product,'description','Producto 3D','quantity',10,'unit_cost',10)),null);
  v_order:=(v_result->>'id')::uuid;perform public.submit_purchase_order(v_company,v_order,null);perform public.decide_purchase_order(v_company,v_order,'approved',null);
  select id into v_order_line from public.purchase_order_lines where purchase_order_id=v_order;
  v_result:=public.save_purchase_receipt(v_company,null,v_order,v_location,'2026-07-16','REM-3D',null,jsonb_build_array(jsonb_build_object('purchase_order_line_id',v_order_line,'quantity',10)),gen_random_uuid(),null);
  v_receipt:=(v_result->>'id')::uuid;perform public.confirm_purchase_receipt(v_company,v_receipt,gen_random_uuid());
  select id into v_receipt_line from public.purchase_receipt_lines where purchase_receipt_id=v_receipt;
  select quantity_on_hand into v_inventory from public.inventory_balances where location_id=v_location and product_id=v_product;
  select count(*) into v_ledger from public.inventory_ledger where company_id=v_company;
  select count(*),max(amount) into v_cost_rows,v_cost from public.product_costs where company_id=v_company and product_id=v_product;

  v_result:=public.save_supplier_invoice(v_company,null,v_supplier,v_order,'A','100','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','2026-07-16','2026-08-15','MXN','Factura parcial',jsonb_build_array(jsonb_build_object('purchase_receipt_line_id',v_receipt_line,'quantity',4,'unit_price',10,'discount_amount',0,'tax_amount',0)),gen_random_uuid(),null);
  v_invoice_one:=(v_result->>'id')::uuid;
  if v_result->>'status'<>'draft' or exists(select 1 from public.accounts_payable where supplier_invoice_id=v_invoice_one) then raise exception 'El borrador creó CxP.';end if;
  v_result:=public.confirm_supplier_invoice(v_company,v_invoice_one,v_confirm_one);v_payable:=(v_result->>'payable_id')::uuid;
  if (select original_amount from public.accounts_payable where id=v_payable)<>40 or (select outstanding_amount from public.accounts_payable where id=v_payable)<>40 then raise exception 'CxP inicial distinta del total confirmado.';end if;
  v_result:=public.confirm_supplier_invoice(v_company,v_invoice_one,v_confirm_one);
  if coalesce((v_result->>'idempotent')::boolean,false)=false or (select count(*) from public.accounts_payable where supplier_invoice_id=v_invoice_one)<>1 then raise exception 'Reintento duplicó CxP.';end if;

  v_result:=public.get_invoiceable_purchase_order(v_company,v_order);
  if (v_result#>>'{lines,0,previously_invoiced}')::numeric<>4 or (v_result#>>'{lines,0,available_quantity}')::numeric<>6 then raise exception 'Pendiente tras factura parcial incorrecto: %',v_result;end if;
  v_result:=public.save_supplier_invoice(v_company,null,v_supplier,v_order,'A','101',null,'2026-07-17','2026-08-16','MXN',null,jsonb_build_array(jsonb_build_object('purchase_receipt_line_id',v_receipt_line,'quantity',6,'unit_price',10,'discount_amount',0,'tax_amount',0)),gen_random_uuid(),null);
  v_invoice_two:=(v_result->>'id')::uuid;
  v_result:=public.save_supplier_invoice(v_company,null,v_supplier,v_order,'A','101',null,'2026-07-17','2026-08-16','MXN',null,jsonb_build_array(jsonb_build_object('purchase_receipt_line_id',v_receipt_line,'quantity',6,'unit_price',10,'discount_amount',0,'tax_amount',0)),gen_random_uuid(),null);
  if v_result->>'status'<>'exception' or v_result->>'kind'<>'duplicate_identity' then raise exception 'La identidad alternativa duplicada no fue bloqueada.';end if;
  perform public.confirm_supplier_invoice(v_company,v_invoice_two,gen_random_uuid());
  if (select sum(quantity) from public.supplier_invoice_lines sil join public.supplier_invoices si on si.id=sil.supplier_invoice_id where sil.purchase_receipt_line_id=v_receipt_line and si.status='confirmed')<>10 then raise exception 'Segunda factura no completó el recibido.';end if;
  begin perform public.save_supplier_invoice(v_company,null,v_supplier,v_order,'A','102',null,'2026-07-18','2026-08-17','MXN',null,jsonb_build_array(jsonb_build_object('purchase_receipt_line_id',v_receipt_line,'quantity',1,'unit_price',10)),gen_random_uuid(),null);exception when others then v_forbidden:=position('supera lo recibido' in lower(sqlerrm))>0;end;if not v_forbidden then raise exception 'Se permitió facturar una partida agotada.';end if;v_forbidden:=false;

  v_result:=public.reverse_supplier_invoice(v_company,v_invoice_two,'Folio incorrecto.',v_reverse_two);
  if (select outstanding_amount from public.accounts_payable where supplier_invoice_id=v_invoice_two)<>0 or (select status from public.supplier_invoices where id=v_invoice_two)<>'reversed' then raise exception 'Reversa no anuló CxP.';end if;
  v_result:=public.reverse_supplier_invoice(v_company,v_invoice_two,'Folio incorrecto.',v_reverse_two);if coalesce((v_result->>'idempotent')::boolean,false)=false then raise exception 'Reversa no idempotente.';end if;

  v_result:=public.save_supplier_invoice(v_company,null,v_supplier,v_order,'A','103',null,'2026-07-18','2026-08-17','MXN',null,jsonb_build_array(jsonb_build_object('purchase_receipt_line_id',v_receipt_line,'quantity',6,'unit_price',11,'discount_amount',0,'tax_amount',0)),gen_random_uuid(),null);
  v_invoice_diff:=(v_result->>'id')::uuid;
  if jsonb_array_length(v_result->'differences')=0 then raise exception 'No se conservó la diferencia de precio.';end if;
  begin perform public.confirm_supplier_invoice(v_company,v_invoice_diff,gen_random_uuid());exception when others then v_forbidden:=position('requieren autorización' in lower(sqlerrm))>0;end;if not v_forbidden then raise exception 'Se confirmó una diferencia sin autorización.';end if;v_forbidden:=false;
  perform public.authorize_supplier_invoice_differences(v_company,v_invoice_diff,'Precio validado contra documento original.');
  perform public.confirm_supplier_invoice(v_company,v_invoice_diff,gen_random_uuid());
  v_result:=public.create_supplier_credit_note(v_company,v_invoice_diff,'NC','1',null,'2026-07-19',5,'Bonificación documentada.',v_credit_key);
  v_credit:=(v_result->>'credit_note_id')::uuid;
  if (select outstanding_amount from public.accounts_payable where supplier_invoice_id=v_invoice_diff)<>61 then raise exception 'Nota de crédito no disminuyó CxP.';end if;
  v_result:=public.create_supplier_credit_note(v_company,v_invoice_diff,'NC','1',null,'2026-07-19',5,'Bonificación documentada.',v_credit_key);if coalesce((v_result->>'idempotent')::boolean,false)=false then raise exception 'Nota de crédito no idempotente.';end if;
  begin perform public.create_supplier_credit_note(v_company,v_invoice_diff,'NC','2',null,'2026-07-19',100,'Excede saldo.',gen_random_uuid());exception when others then v_forbidden:=position('saldo contrario' in lower(sqlerrm))>0;end;if not v_forbidden then raise exception 'Nota de crédito generó saldo contrario.';end if;v_forbidden:=false;

  v_result:=public.save_supplier_invoice(v_company,null,v_supplier,v_order,'A','DUP','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','2026-07-20','2026-08-20','MXN',null,jsonb_build_array(jsonb_build_object('purchase_receipt_line_id',v_receipt_line,'quantity',1,'unit_price',10)),gen_random_uuid(),null);
  if v_result->>'status'<>'exception' or v_result->>'kind'<>'duplicate_uuid' or not exists(select 1 from public.supplier_invoice_exceptions where company_id=v_company and kind='duplicate_uuid') then raise exception 'UUID duplicado no fue bloqueado y enviado a revisión.';end if;
  begin perform public.reverse_purchase_receipt(v_company,v_receipt,'No procede.',gen_random_uuid());exception when others then v_forbidden:=position('cantidades facturadas' in lower(sqlerrm))>0;end;if not v_forbidden then raise exception 'Se revirtió una recepción facturada.';end if;v_forbidden:=false;

  v_result:=public.search_supplier_invoices(v_company,'A',null,v_supplier,v_order,v_receipt,null,null,1,25);if (v_result#>>'{pagination,total}')::int<>3 then raise exception 'Listado de facturas incorrecto: %',v_result;end if;
  v_result:=public.search_accounts_payable(v_company,null,v_supplier,v_order,v_receipt,null,null,null,1,25);if (v_result#>>'{pagination,total}')::int<>3 then raise exception 'Listado CxP incorrecto: %',v_result;end if;
  v_result:=public.get_supplier_invoice_detail(v_company,v_invoice_diff);if v_result#>>'{payable,outstanding_amount}'<>'61.000000' or jsonb_array_length(v_result->'audit')<2 then raise exception 'Detalle, CxP o auditoría incompletos: %',v_result;end if;

  if (select quantity_on_hand from public.inventory_balances where location_id=v_location and product_id=v_product)<>v_inventory or (select count(*) from public.inventory_ledger where company_id=v_company)<>v_ledger or (select count(*) from public.product_costs where company_id=v_company and product_id=v_product)<>v_cost_rows or (select max(amount) from public.product_costs where company_id=v_company and product_id=v_product)<>v_cost then raise exception 'M3D modificó inventario, movimientos o costo.';end if;
  if (select count(*) from public.alpha_purchasing_import_payable_documents)<>v_stage_payables or (select count(*) from public.alpha_purchasing_import_payment_evidence)<>v_stage_payments then raise exception 'M3D alteró evidencia Alpha.';end if;
  if exists(select 1 from public.supplier_invoices si join public.purchase_orders po on po.id=si.purchase_order_id where po.origin='imported_historical') then raise exception 'M3D creó facturas históricas.';end if;
  perform public.reverse_supplier_credit_note(v_company,v_credit,'Bonificación cancelada.',gen_random_uuid());if (select outstanding_amount from public.accounts_payable where supplier_invoice_id=v_invoice_diff)<>66 then raise exception 'La reversa de nota no restauró CxP.';end if;
  if not exists(select 1 from public.accounting_events where company_id=v_company and event_type='purchase_receipt_confirmed' and status='posted') or not exists(select 1 from public.accounting_events where company_id=v_company and event_type='supplier_invoice_reversed' and status='posted') or not exists(select 1 from public.accounting_events where company_id=v_company and event_type='supplier_credit_note_reversed' and status='posted') then raise exception 'M4B no trazó recepción, factura o nota/reversa.';end if;

  perform set_config('request.jwt.claim.sub',v_warehouse::text,true);
  begin perform public.search_supplier_invoices(v_company,null,null,null,null,null,null,null,1,25);exception when others then v_forbidden:=position('no autorizado' in lower(sqlerrm))>0;end;if not v_forbidden then raise exception 'Almacén consultó facturas sin permiso.';end if;v_forbidden:=false;
  perform set_config('request.jwt.claim.sub',v_outsider::text,true);
  begin perform public.search_accounts_payable(v_company,null,null,null,null,null,null,null,1,25);exception when others then v_forbidden:=position('no autorizado' in lower(sqlerrm))>0;end;if not v_forbidden then raise exception 'Una empresa ajena consultó CxP.';end if;v_forbidden:=false;
  raise notice 'Módulo 3D: parcial/complemento, diferencias, duplicados, CxP, idempotencia, reversa, crédito, RLS y no afectación aprobados.';
end;
$test$;

rollback;
