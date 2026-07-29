begin;

do $test$
declare
  v_actor uuid;v_warehouse uuid:='38000000-0000-4000-8000-000000000098';v_outsider uuid:='38000000-0000-4000-8000-000000000099';
  v_company uuid:='38000000-0000-4000-8000-000000000001';v_other uuid:='38000000-0000-4000-8000-000000000002';
  v_supplier uuid;v_product uuid;v_product_other uuid;v_location uuid;v_other_location uuid;v_order uuid;v_order_line uuid;v_rejected uuid;v_cancelled uuid;v_receipt uuid;v_receipt_two uuid;
  v_cfg uuid;v_rules uuid;v_account uuid;v_controls jsonb;v_role text;
  v_result jsonb;v_forbidden boolean:=false;v_balance numeric;v_cost numeric;v_order_count bigint;v_line_count bigint;v_stage_orders bigint;v_stage_lines bigint;
  v_create_key uuid:='38000000-0000-4000-8000-000000000010';v_confirm_key uuid:='38000000-0000-4000-8000-000000000011';v_reverse_key uuid:='38000000-0000-4000-8000-000000000012';
begin
  if to_regprocedure('public.save_purchase_receipt(uuid,uuid,uuid,uuid,date,text,text,jsonb,uuid,timestamptz)') is null then raise exception 'Faltan RPC de M3C.';end if;
  select ur.user_id into v_actor from public.user_roles ur join public.roles r on r.id=ur.role_id where r.code='super_admin' limit 1;
  if v_actor is null then raise exception 'La prueba requiere Super Admin.';end if;
  select count(*) into v_stage_orders from public.alpha_purchasing_import_orders;
  select count(*) into v_stage_lines from public.alpha_purchasing_import_order_lines;
  insert into public.companies(id,legal_name,display_name) values(v_company,'Recepciones 3C','Recepciones 3C'),(v_other,'Otra 3C','Otra 3C');
  insert into auth.users(id,aud,role,email,encrypted_password) values(v_warehouse,'authenticated','authenticated','almacen-3c@example.com',''),(v_outsider,'authenticated','authenticated','ajeno-3c@example.com','');
  insert into public.user_roles(user_id,role_id,company_id) select v_actor,id,v_company from public.roles where code='super_admin' on conflict do nothing;
  insert into public.user_roles(user_id,role_id,company_id) select v_warehouse,id,v_company from public.roles where code='almacen';
  insert into public.user_roles(user_id,role_id,company_id) select v_outsider,id,v_other from public.roles where code='almacen';
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',v_actor::text,true);
  insert into public.suppliers(company_id,code,display_name,legal_entity_type,country_code,is_active) values(v_company,'SUP-3C','Proveedor 3C','moral','MX',true) returning id into v_supplier;
  insert into public.products(company_id,alpha_sku,name,unit,product_type,is_active,is_inventory_tracked) values(v_company,'SKU-3C','Producto 3C','PZA','P. TERMINADO',true,true) returning id into v_product;
  insert into public.products(company_id,alpha_sku,name,unit,product_type,is_active,is_inventory_tracked) values(v_other,'SKU-X-3C','Producto ajeno','PZA','P. TERMINADO',true,true) returning id into v_product_other;
  insert into public.locations(company_id,external_code,name,location_type,is_active,classification_source) values(v_company,'ALM-3C','Almacén 3C','almacen_operativo',true,'manual_review') returning id into v_location;
  insert into public.locations(company_id,external_code,name,location_type,is_active,classification_source) values(v_other,'ALM-X','Almacén ajeno','almacen_operativo',true,'manual_review') returning id into v_other_location;
  insert into public.user_location_access(user_id,location_id) values(v_warehouse,v_location),(v_outsider,v_other_location);
  insert into public.product_costs(company_id,product_id,cost_type,amount,currency_code,valid_from,source_file_name,created_by) values(v_company,v_product,'replacement_cost',7,'MXN','2026-07-01','baseline-3c',v_actor);
  insert into public.accounting_accounts(company_id,code,name,account_type,normal_balance,level) select v_company,lpad(n::text,4,'0'),'Cuenta M4B '||n,case when n between 11 and 30 then 'expense' else 'asset' end,case when n in(2,7,9) or n between 11 and 30 then 'credit' else 'debit' end,1 from generate_series(1,30)n;
  select jsonb_object_agg(k,a.id) into v_controls from (values('accounts_receivable','0001'),('accounts_payable','0002'),('inventory','0003'),('cash','0004'),('banks','0005'),('vat_pending','0006'),('vat_collected','0007'),('vat_paid','0008'),('withholdings','0009'))x(k,code) join public.accounting_accounts a on a.company_id=v_company and a.code=x.code;
  v_result:=public.save_accounting_config(v_company,'MXN','2026-07-16','{"format":"4"}','{"vat_pending":"x","vat_collected":"x","vat_paid":"x","withholdings":"x"}',jsonb_build_object('adjustments',v_actor,'close',v_actor,'reopen',v_actor),'M4B recepciones',v_controls);v_cfg:=(v_result->>'id')::uuid;perform public.approve_accounting_config(v_cfg);perform public.create_accounting_period(v_company,'2026-07','2026-07-01','2026-07-31');v_result:=public.create_accounting_event_rule_set(v_company,'replacement_cost','{"purchase_receipt":"confirmation"}','M4B recepciones');v_rules:=(v_result->>'id')::uuid;
  for v_role in select unnest(array['sales_revenue','sales_discounts','cost_of_goods_sold','goods_received_not_invoiced','purchase_variance','supplier_expense','cash_opening_offset','cash_close_offset','cash_movement_offset','cash_over_short','supplier_credit_note_offset','inventory_adjustment']) loop select id into v_account from public.accounting_accounts where company_id=v_company and code=lpad((10+(select count(*) from public.accounting_event_role_accounts where rule_set_id=v_rules)+1)::text,4,'0');perform public.set_accounting_event_role_account(v_rules,v_role,v_account);end loop;perform public.approve_accounting_event_rule_set(v_rules,'Matriz de prueba aprobada');

  v_result:=public.save_purchase_order(v_company,null,v_supplier,'MXN','2026-07-10',null,null,null,null,10,jsonb_build_array(jsonb_build_object('product_id',v_product,'description','Producto 3C','quantity',10,'unit_cost',12,'discount_percent_1',10)),null);
  v_order:=(v_result->>'id')::uuid;perform public.submit_purchase_order(v_company,v_order,null);perform public.decide_purchase_order(v_company,v_order,'approved',null);
  select id into v_order_line from public.purchase_order_lines where purchase_order_id=v_order;
  select count(*) into v_order_count from public.purchase_orders;select count(*) into v_line_count from public.purchase_order_lines;

  v_result:=public.save_purchase_receipt(v_company,null,v_order,v_location,'2026-07-16','REM-001','Parcial',jsonb_build_array(jsonb_build_object('purchase_order_line_id',v_order_line,'quantity',4)),v_create_key,null);
  v_receipt:=(v_result->>'id')::uuid;
  if v_result->>'status'<>'draft' or (select count(*) from public.inventory_ledger where purchase_receipt_id=v_receipt)<>0 or exists(select 1 from public.inventory_balances where location_id=v_location and product_id=v_product) then raise exception 'El borrador modificó inventario.';end if;
  v_result:=public.save_purchase_receipt(v_company,null,v_order,v_location,'2026-07-16','REM-001','Parcial',jsonb_build_array(jsonb_build_object('purchase_order_line_id',v_order_line,'quantity',4)),v_create_key,null);
  if (v_result->>'id')::uuid<>v_receipt or (select count(*) from public.purchase_receipts where company_id=v_company)<>1 then raise exception 'La creación no es idempotente.';end if;

  v_result:=public.confirm_purchase_receipt(v_company,v_receipt,v_confirm_key);
  select quantity_on_hand into v_balance from public.inventory_balances where location_id=v_location and product_id=v_product;
  select amount into v_cost from public.product_costs where company_id=v_company and product_id=v_product and cost_type='replacement_cost' and currency_code='MXN' and valid_to is null;
  if v_balance<>4 or v_cost<>9.72 or v_result->>'fulfillment_status'<>'partially_received' or (select count(*) from public.inventory_ledger where purchase_receipt_id=v_receipt and movement_type='purchase_receipt')<>1 then raise exception 'Confirmación parcial, costo o cumplimiento incorrectos: %, %, %',v_result,v_balance,v_cost;end if;
  v_result:=public.confirm_purchase_receipt(v_company,v_receipt,v_confirm_key);
  if coalesce((v_result->>'idempotent')::boolean,false)=false or (select quantity_on_hand from public.inventory_balances where location_id=v_location and product_id=v_product)<>4 or (select count(*) from public.inventory_ledger where purchase_receipt_id=v_receipt and movement_type='purchase_receipt')<>1 then raise exception 'Reintento de confirmación duplicó inventario.';end if;
  begin perform public.confirm_purchase_receipt(v_company,v_receipt,gen_random_uuid());exception when others then v_forbidden:=position('ya fue confirmada' in lower(sqlerrm))>0 or position('no está disponible' in lower(sqlerrm))>0;end;if not v_forbidden then raise exception 'Una confirmación con otra clave fue aceptada.';end if;v_forbidden:=false;

  begin perform public.save_purchase_receipt(v_company,null,v_order,v_location,'2026-07-16',null,null,jsonb_build_array(jsonb_build_object('purchase_order_line_id',v_order_line,'quantity',7)),gen_random_uuid(),null);exception when others then v_forbidden:=position('supera la cantidad pendiente' in lower(sqlerrm))>0;end;if not v_forbidden then raise exception 'Se permitió sobreentrega.';end if;v_forbidden:=false;
  begin perform public.save_purchase_receipt(v_company,null,v_order,v_other_location,'2026-07-16',null,null,jsonb_build_array(jsonb_build_object('purchase_order_line_id',v_order_line,'quantity',1)),gen_random_uuid(),null);exception when others then v_forbidden:=position('ubicación no disponible' in lower(sqlerrm))>0;end;if not v_forbidden then raise exception 'Se permitió ubicación ajena.';end if;v_forbidden:=false;

  v_result:=public.save_purchase_receipt(v_company,null,v_order,v_location,'2026-07-17','REM-002',null,jsonb_build_array(jsonb_build_object('purchase_order_line_id',v_order_line,'quantity',6)),gen_random_uuid(),null);v_receipt_two:=(v_result->>'id')::uuid;
  v_result:=public.confirm_purchase_receipt(v_company,v_receipt_two,gen_random_uuid());
  if (select quantity_on_hand from public.inventory_balances where location_id=v_location and product_id=v_product)<>10 or v_result->>'fulfillment_status'<>'fully_received' then raise exception 'La segunda recepción no completó únicamente el pendiente.';end if;

  begin update public.purchase_receipts set notes='Mutación' where id=v_receipt;exception when others then v_forbidden:=position('inmutable' in lower(sqlerrm))>0;end;if not v_forbidden then raise exception 'Se editó una recepción confirmada.';end if;v_forbidden:=false;
  begin delete from public.purchase_receipt_lines where purchase_receipt_id=v_receipt;exception when others then v_forbidden:=position('inmutables' in lower(sqlerrm))>0;end;if not v_forbidden then raise exception 'Se eliminó una partida confirmada.';end if;v_forbidden:=false;

  begin perform public.reverse_purchase_receipt(v_company,v_receipt,'',gen_random_uuid());exception when others then v_forbidden:=position('motivo' in lower(sqlerrm))>0;end;if not v_forbidden then raise exception 'Se permitió reversa sin motivo.';end if;v_forbidden:=false;
  v_result:=public.reverse_purchase_receipt(v_company,v_receipt,'Remisión equivocada.',v_reverse_key);
  if (select quantity_on_hand from public.inventory_balances where location_id=v_location and product_id=v_product)<>6 or v_result->>'fulfillment_status'<>'partially_received' or (select count(*) from public.inventory_ledger where purchase_receipt_id=v_receipt)<>2 then raise exception 'La reversa no restauró existencias y cantidades.';end if;
  v_result:=public.reverse_purchase_receipt(v_company,v_receipt,'Remisión equivocada.',v_reverse_key);if coalesce((v_result->>'idempotent')::boolean,false)=false or (select quantity_on_hand from public.inventory_balances where location_id=v_location and product_id=v_product)<>6 then raise exception 'La reversa no es idempotente.';end if;

  if not exists(select 1 from public.inventory_ledger where purchase_receipt_id=v_receipt and purchase_order_id=v_order and supplier_id=v_supplier and product_id=v_product and location_id=v_location) then raise exception 'El movimiento perdió relaciones canónicas.';end if;
  if not exists(select 1 from public.audit_log where entity_id=v_receipt and action='purchase_receipt.confirmed') or not exists(select 1 from public.audit_log where entity_id=v_receipt and action='purchase_receipt.reversed' and metadata->>'reason'='Remisión equivocada.') then raise exception 'Falta auditoría de confirmar o reversar.';end if;
  v_result:=public.search_purchase_receipts(v_company,'REM-00',null,v_location,v_supplier,null,null,1,1);if (v_result#>>'{pagination,total}')::int<>2 or jsonb_array_length(v_result->'items')<>1 then raise exception 'Listado server-side incorrecto.';end if;
  v_result:=public.get_purchase_receipt_detail(v_company,v_receipt);if jsonb_array_length(v_result->'lines')<>1 or jsonb_array_length(v_result->'movements')<>2 then raise exception 'Detalle incompleto.';end if;
  v_result:=public.get_receivable_purchase_order(v_company,v_order);if (v_result#>>'{lines,0,previously_received}')::numeric<>6 or (v_result#>>'{lines,0,pending_quantity}')::numeric<>4 then raise exception 'Cantidades acumuladas de OC incorrectas: %',v_result;end if;
  v_result:=public.list_purchase_order_receipts(v_company,v_order);if jsonb_array_length(v_result->'receipts')<>2 or jsonb_array_length(v_result->'movements')<>3 then raise exception 'La OC no muestra recepciones o movimientos.';end if;

  v_result:=public.save_purchase_order(v_company,null,v_supplier,'MXN','2026-07-16',null,null,null,null,0,jsonb_build_array(jsonb_build_object('product_id',v_product,'description','Rechazada','quantity',1,'unit_cost',1)),null);v_rejected:=(v_result->>'id')::uuid;perform public.submit_purchase_order(v_company,v_rejected,null);perform public.decide_purchase_order(v_company,v_rejected,'rejected','No procede.');
  begin perform public.save_purchase_receipt(v_company,null,v_rejected,v_location,'2026-07-16',null,null,jsonb_build_array(jsonb_build_object('purchase_order_line_id',(select id from public.purchase_order_lines where purchase_order_id=v_rejected),'quantity',1)),gen_random_uuid(),null);exception when others then v_forbidden:=position('sólo una oc aprobada' in lower(sqlerrm))>0;end;if not v_forbidden then raise exception 'Se recibió una OC rechazada.';end if;v_forbidden:=false;
  v_result:=public.save_purchase_order(v_company,null,v_supplier,'MXN','2026-07-16',null,null,null,null,0,jsonb_build_array(jsonb_build_object('product_id',v_product,'description','Cancelada','quantity',1,'unit_cost',1)),null);v_cancelled:=(v_result->>'id')::uuid;perform public.submit_purchase_order(v_company,v_cancelled,null);perform public.decide_purchase_order(v_company,v_cancelled,'approved',null);perform public.cancel_purchase_order(v_company,v_cancelled,'Cancelación de prueba.');
  begin perform public.save_purchase_receipt(v_company,null,v_cancelled,v_location,'2026-07-16',null,null,jsonb_build_array(jsonb_build_object('purchase_order_line_id',(select id from public.purchase_order_lines where purchase_order_id=v_cancelled),'quantity',1)),gen_random_uuid(),null);exception when others then v_forbidden:=position('sólo una oc aprobada' in lower(sqlerrm))>0;end;if not v_forbidden then raise exception 'Se recibió una OC cancelada.';end if;v_forbidden:=false;

  perform set_config('request.jwt.claim.sub',v_warehouse::text,true);
  v_result:=public.search_receivable_purchase_orders(v_company,null,1,50);if (v_result#>>'{pagination,total}')::int<1 then raise exception 'Almacén no pudo consultar OC recibibles.';end if;
  v_result:=public.get_purchase_receipt_detail(v_company,v_receipt_two);if v_result#>>'{lines,0,unit_cost}' is not null then raise exception 'Almacén consultó costos sin permiso.';end if;
  begin perform public.reverse_purchase_receipt(v_company,v_receipt_two,'Sin permiso.',gen_random_uuid());exception when others then v_forbidden:=position('no autorizado' in lower(sqlerrm))>0;end;if not v_forbidden then raise exception 'Almacén autorizó una reversa.';end if;v_forbidden:=false;
  perform set_config('request.jwt.claim.sub',v_outsider::text,true);
  begin perform public.search_purchase_receipts(v_company,null,null,null,null,null,null,1,25);exception when others then v_forbidden:=position('no autorizado' in lower(sqlerrm))>0;end;if not v_forbidden then raise exception 'Una empresa ajena consultó recepciones.';end if;

  if (select count(*) from public.alpha_purchasing_import_orders)<>v_stage_orders or (select count(*) from public.alpha_purchasing_import_order_lines)<>v_stage_lines then raise exception 'M3C alteró staging histórico.';end if;
  if exists(select 1 from public.purchase_receipts r join public.purchase_orders po on po.id=r.purchase_order_id where po.origin='imported_historical' and r.company_id=v_company) then raise exception 'M3C inventó recepciones históricas.';end if;
  if (select count(*) from public.purchase_orders)<v_order_count or (select count(*) from public.purchase_order_lines)<v_line_count then raise exception 'M3C dañó M3B.';end if;
  raise notice 'Módulo 3C: borrador, parcial/total, costo de reemplazo, idempotencia, reversa, permisos, RLS, auditoría y staging aprobados.';
end;
$test$;

set constraints all immediate;

do $m4b_assert$
declare c uuid:='38000000-0000-4000-8000-000000000001';receipt uuid;d numeric;h numeric;
begin
  select id into receipt from public.purchase_receipts where company_id=c and document_reference='REM-001';
  if (select count(*) from public.accounting_events where company_id=c and event_type='purchase_receipt_confirmed' and status='posted')<>2 or (select count(*) from public.accounting_events where company_id=c and event_type='purchase_receipt_reversed' and status='posted')<>1 then raise exception 'Recepciones y reversa no produjeron exactamente una contabilización por evento.';end if;
  if exists(select l.account_id from public.accounting_events e join public.accounting_journal_entries j on j.accounting_event_id=e.id join public.accounting_journal_lines l on l.journal_entry_id=j.id where e.company_id=c and e.source_entity_id=receipt and e.event_type in ('purchase_receipt_confirmed','purchase_receipt_reversed') group by l.account_id having abs(sum(l.debit-l.credit))>0.000001) then raise exception 'La reversa de recepción no neutralizó exactamente la póliza original.';end if;
  select sum(l.debit),sum(l.credit) into d,h from public.accounting_journal_lines l where l.company_id=c;if d<>h then raise exception 'La cadena de recepciones quedó desbalanceada: % / %',d,h;end if;
  raise notice 'M4B recepciones: confirmación e inversa exacta aprobadas.';
end;
$m4b_assert$;

rollback;
