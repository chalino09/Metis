begin;

do $test$
declare
  v_actor uuid;
  v_company uuid:='3d200000-0000-4000-8000-000000000001';
  v_supplier uuid;
  v_invoice uuid;
  v_mismatch uuid;
  v_result jsonb;
  v_payable uuid;
  v_forbidden boolean:=false;
  v_inventory bigint;
  v_ledger bigint;
  v_costs bigint;
  v_stage_payables bigint;
  v_stage_payments bigint;
  v_expense_account uuid:=gen_random_uuid();
  v_expense_category uuid:=gen_random_uuid();
begin
  if to_regprocedure('public.save_supplier_expense_invoice(uuid,uuid,uuid,text,text,text,date,date,text,numeric,text,text,text,jsonb,timestamptz)') is null then
    raise exception 'Falta la extensión final de M3D.';
  end if;
  select ur.user_id into v_actor from public.user_roles ur join public.roles r on r.id=ur.role_id where r.code='super_admin' limit 1;
  if v_actor is null then raise exception 'La prueba requiere Super Admin.';end if;
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_actor::text,true);
  select count(*) into v_inventory from public.inventory_balances;
  select count(*) into v_ledger from public.inventory_ledger;
  select count(*) into v_costs from public.product_costs;
  select count(*) into v_stage_payables from public.alpha_purchasing_import_payable_documents;
  select count(*) into v_stage_payments from public.alpha_purchasing_import_payment_evidence;

  insert into public.companies(id,legal_name,display_name,tax_id,base_currency_code)
  values(v_company,'Empresa receptora','Empresa receptora','BBB010101BBB','MXN');
  insert into public.user_roles(user_id,role_id,company_id) select v_actor,id,v_company from public.roles where code='super_admin' on conflict do nothing;
  insert into public.accounting_accounts(id,company_id,code,name,account_type,normal_balance,level)
  values(v_expense_account,v_company,'M3D-SERV','Servicios de prueba M3D','expense','debit',1);
  insert into public.accounting_expense_category_versions(
    company_id,category_id,version,code,display_name,account_id,status,valid_from,change_reason,created_by
  ) values(v_company,v_expense_category,1,'M3D-SERV','Servicios de prueba M3D',v_expense_account,'active','2026-01-01','Adaptación explícita M4D2',v_actor);
  insert into public.suppliers(company_id,code,display_name,legal_entity_type,tax_id,country_code,is_active,payable_term_days)
  values(v_company,'SERV-3D','Proveedor de servicios','moral','AAA010101AAA','MX',true,30) returning id into v_supplier;

  v_result:=public.save_supplier_expense_invoice(
    v_company,null,v_supplier,'S','200','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    '2026-07-01','2026-07-31','USD',17.5,'Servicio mensual','PPD','99',
    jsonb_build_array(jsonb_build_object('product_service_code','81112100','quantity',1,'unit_code','E48','unit_name','Unidad de servicio','description','Servicio mensual','unit_value',100,'subtotal',100,'discount_amount',0,'transferred_tax_amount',16,'withheld_tax_amount',0,'tax_object_code','02','tax_details',jsonb_build_array(jsonb_build_object('kind','transferred','tax_code','002','factor_type','Tasa','rate','0.160000','base','100','amount','16')))),null
  );
  v_invoice:=(v_result->>'id')::uuid;
  if v_result->>'status'<>'draft' or exists(select 1 from public.accounts_payable where supplier_invoice_id=v_invoice) then raise exception 'El gasto en borrador creó CxP.';end if;
  begin perform public.confirm_supplier_invoice(v_company,v_invoice,gen_random_uuid());exception when others then v_forbidden:=position('requiere aprobación' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Se confirmó un gasto sin aprobación.';end if;v_forbidden:=false;
  perform public.approve_supplier_expense_invoice(v_company,v_invoice,'Servicio revisado por administración.');
  v_result:=public.register_supplier_invoice_document(
    v_company,v_invoice,'cfdi_xml','servicio.xml',v_company||'/'||v_invoice||'/servicio.xml','application/xml',1024,repeat('a',64),
    jsonb_build_object('version','4.0','issued_at','2026-07-01T12:00:00','currency','USD','subtotal','100','discount_total','0','transferred_tax_total','16','withheld_tax_total','0','total','116','document_type','I','issuer_rfc','AAA010101AAA','receiver_rfc','BBB010101BBB','uuid','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','concepts',jsonb_build_array(jsonb_build_object('product_service_code','81112100','quantity','1','unit_code','E48','description','Servicio mensual','unit_value','100','subtotal','100','discount_amount','0','transferred_tax_amount','16','withheld_tax_amount','0','tax_object_code','02','tax_details',jsonb_build_array(jsonb_build_object('kind','transferred','tax_code','002','factor_type','Tasa','rate','0.160000','base','100','amount','16')))))
  );
  if v_result->>'status'<>'verified_local' then raise exception 'XML coincidente no validó localmente: %',v_result;end if;
  v_result:=public.register_supplier_invoice_document(
    v_company,v_invoice,'cfdi_xml','servicio.xml',v_company||'/'||v_invoice||'/servicio.xml','application/xml',1024,repeat('a',64),
    jsonb_build_object('version','4.0')
  );
  if coalesce((v_result->>'idempotent')::boolean,false)=false then raise exception 'El expediente duplicó el mismo archivo.';end if;
  perform public.record_supplier_invoice_sat_verification(v_company,v_invoice,'valid','2026-07-16T12:00:00Z',jsonb_build_object('source','SAT','reference','consulta controlada'));
  perform public.bulk_assign_expense_category(
    v_company,v_expense_category,v_invoice,null,
    array(select id from public.supplier_invoice_expense_lines where supplier_invoice_id=v_invoice),
    1000,gen_random_uuid()
  );
  v_result:=public.confirm_supplier_invoice(v_company,v_invoice,'3d200000-0000-4000-8000-000000000010');
  v_payable:=(v_result->>'payable_id')::uuid;
  if (select original_amount from public.accounts_payable where id=v_payable)<>116 or (select original_base_amount from public.accounts_payable where id=v_payable)<>2030 then raise exception 'CxP multimoneda incorrecta.';end if;
  perform public.create_supplier_credit_note(v_company,v_invoice,'NC','200',null,'2026-07-10',10,'Bonificación del servicio.','3d200000-0000-4000-8000-000000000011');
  if (select outstanding_amount from public.accounts_payable where id=v_payable)<>106 or (select outstanding_base_amount from public.accounts_payable where id=v_payable)<>1855 then raise exception 'Nota de crédito no sincronizó saldo base.';end if;
  v_result:=public.get_accounts_payable_aging(v_company,'2026-08-01');
  if (v_result#>>'{items,0,currency_code}')<>'USD' or (v_result#>>'{items,0,days_1_30}')::numeric<>106 then raise exception 'Antigüedad por moneda incorrecta: %',v_result;end if;

  v_result:=public.save_supplier_expense_invoice(
    v_company,null,v_supplier,'S','201','cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    '2026-07-02','2026-08-01','MXN',1,null,'PPD','99',
    jsonb_build_array(jsonb_build_object('product_service_code','81112100','quantity',1,'unit_code','E48','unit_name','Unidad de servicio','description','Otro servicio','unit_value',100,'subtotal',100,'discount_amount',0,'transferred_tax_amount',16,'withheld_tax_amount',0,'tax_object_code','02','tax_details',jsonb_build_array(jsonb_build_object('kind','transferred','tax_code','002','factor_type','Tasa','rate','0.160000','base','100','amount','16')))),null
  );
  v_mismatch:=(v_result->>'id')::uuid;
  perform public.approve_supplier_expense_invoice(v_company,v_mismatch,'Servicio revisado.');
  v_result:=public.register_supplier_invoice_document(
    v_company,v_mismatch,'cfdi_xml','mismatch.xml',v_company||'/'||v_mismatch||'/mismatch.xml','application/xml',1024,repeat('b',64),
    jsonb_build_object('version','4.0','issued_at','2026-07-02T12:00:00','currency','MXN','subtotal','100','discount_total','0','transferred_tax_total','16','withheld_tax_total','0','total','999','document_type','I','issuer_rfc','AAA010101AAA','receiver_rfc','BBB010101BBB','uuid','cccccccc-cccc-4ccc-8ccc-cccccccccccc','concepts',jsonb_build_array(jsonb_build_object('product_service_code','81112100','quantity','1','unit_code','E48','description','Otro servicio','unit_value','100','subtotal','100','discount_amount','0','transferred_tax_amount','16','withheld_tax_amount','0','tax_object_code','02','tax_details',jsonb_build_array(jsonb_build_object('kind','transferred','tax_code','002','factor_type','Tasa','rate','0.160000','base','100','amount','16')))))
  );
  if v_result->>'status'<>'mismatch' then raise exception 'El XML discordante no fue marcado.';end if;
  begin perform public.confirm_supplier_invoice(v_company,v_mismatch,gen_random_uuid());exception when others then v_forbidden:=position('xml adjunto presenta diferencias' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Se confirmó una factura con XML discordante.';end if;

  if (select count(*) from public.inventory_balances)<>v_inventory or (select count(*) from public.inventory_ledger)<>v_ledger or (select count(*) from public.product_costs)<>v_costs then raise exception 'La extensión M3D modificó inventario o costo.';end if;
  if (select count(*) from public.alpha_purchasing_import_payable_documents)<>v_stage_payables or (select count(*) from public.alpha_purchasing_import_payment_evidence)<>v_stage_payments then raise exception 'La extensión M3D alteró evidencia Alpha.';end if;
  raise notice 'M3D final: gasto aprobado, expediente CFDI, SAT evidenciado, multimoneda, crédito y antigüedad aprobados.';
end;
$test$;

rollback;
