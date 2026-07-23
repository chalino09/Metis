begin;

do $test$
declare
  v_actor uuid;
  v_company uuid:='3d200000-0000-4000-8000-000000000003';
  v_supplier uuid;
  v_invoice uuid;
  v_result jsonb;
  v_blocked boolean:=false;
  v_expense_account uuid:=gen_random_uuid();
  v_expense_category uuid:=gen_random_uuid();
begin
  select ur.user_id into v_actor from public.user_roles ur join public.roles r on r.id=ur.role_id where r.code='super_admin' limit 1;
  if v_actor is null then raise exception 'La prueba requiere Super Admin.';end if;
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_actor::text,true);

  insert into public.companies(id,legal_name,display_name,tax_id,base_currency_code)
  values(v_company,'Empresa CFDI','Empresa CFDI','BBB010101BBB','MXN');
  insert into public.user_roles(user_id,role_id,company_id) select v_actor,id,v_company from public.roles where code='super_admin' on conflict do nothing;
  insert into public.accounting_accounts(id,company_id,code,name,account_type,normal_balance,level)
  values(v_expense_account,v_company,'M3D-CFDI','Servicios profesionales de prueba','expense','debit',1);
  insert into public.accounting_expense_category_versions(
    company_id,category_id,version,code,display_name,account_id,status,valid_from,change_reason,created_by
  ) values(v_company,v_expense_category,1,'M3D-CFDI','Servicios profesionales de prueba',v_expense_account,'active','2026-01-01','Adaptación explícita M4D2',v_actor);
  insert into public.suppliers(company_id,code,display_name,legal_entity_type,tax_id,country_code,is_active)
  values(v_company,'SERV-CFDI','Servicios CFDI','moral','AAA010101AAA','MX',true) returning id into v_supplier;

  v_result:=public.save_supplier_expense_invoice(
    v_company,null,v_supplier,'A','300','dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    '2026-07-17','2026-08-16','MXN',1,'Honorarios julio','PPD','99',
    jsonb_build_array(jsonb_build_object(
      'product_service_code','84111506','identification_number','HON-JUL','quantity',1,'unit_code','E48','unit_name','Unidad de servicio',
      'description','Servicios de contabilidad','unit_value',1000,'subtotal',1000,'discount_amount',0,
      'transferred_tax_amount',160,'withheld_tax_amount',100,'tax_object_code','02',
      'tax_details',jsonb_build_array(
        jsonb_build_object('kind','transferred','tax_code','002','factor_type','Tasa','rate','0.160000','base','1000','amount','160'),
        jsonb_build_object('kind','withheld','tax_code','001','factor_type','Tasa','rate','0.100000','base','1000','amount','100')
      ),'expense_category','Servicios profesionales','cost_center_reference','ADMIN','project_reference','CIERRE-MENSUAL'
    )),null
  );
  v_invoice:=(v_result->>'id')::uuid;
  if (select total from public.supplier_invoices where id=v_invoice)<>1060 or (select withholding_total from public.supplier_invoices where id=v_invoice)<>100 then raise exception 'Totales con retención incorrectos.';end if;
  if not exists(select 1 from public.supplier_invoice_expense_lines where supplier_invoice_id=v_invoice and product_service_code='84111506' and unit_code='E48' and tax_object_code='02' and cost_center_reference='ADMIN' and project_reference='CIERRE-MENSUAL' and total=1060) then raise exception 'El concepto fiscal o su distribución interna no se conservó.';end if;

  perform public.approve_supplier_expense_invoice(v_company,v_invoice,'Servicio y distribución revisados.');
  begin perform public.confirm_supplier_invoice(v_company,v_invoice,gen_random_uuid());exception when others then v_blocked:=position('requiere un xml cfdi 4.0 coincidente' in lower(sqlerrm))>0;end;
  if not v_blocked then raise exception 'Una factura mexicana de gasto se confirmó sin XML.';end if;

  v_result:=public.register_supplier_invoice_document(
    v_company,v_invoice,'cfdi_xml','honorarios.xml',v_company||'/'||v_invoice||'/honorarios.xml','application/xml',2048,repeat('d',64),
    jsonb_build_object('version','4.0','issued_at','2026-07-17T10:00:00','currency','MXN','subtotal','1000','discount_total','0','transferred_tax_total','160','withheld_tax_total','100','total','1060','document_type','I','payment_method_code','PPD','payment_form_code','99','issuer_rfc','AAA010101AAA','receiver_rfc','BBB010101BBB','uuid','dddddddd-dddd-4ddd-8ddd-dddddddddddd','concepts',jsonb_build_array(jsonb_build_object('product_service_code','84111506','identification_number','HON-JUL','quantity','1','unit_code','E48','unit_name','Unidad de servicio','description','Servicios de contabilidad','unit_value','1000','subtotal','1000','discount_amount','0','transferred_tax_amount','160','withheld_tax_amount','100','tax_object_code','02','tax_details',jsonb_build_array(jsonb_build_object('kind','transferred','tax_code','002','factor_type','Tasa','rate','0.160000','base','1000','amount','160'),jsonb_build_object('kind','withheld','tax_code','001','factor_type','Tasa','rate','0.100000','base','1000','amount','100')))))
  );
  if v_result->>'status'<>'verified_local' then raise exception 'El XML con conceptos e impuestos coincidentes no validó: %',v_result;end if;
  perform public.bulk_assign_expense_category(
    v_company,v_expense_category,v_invoice,'Servicios profesionales',null,
    1000,gen_random_uuid()
  );
  v_result:=public.confirm_supplier_invoice(v_company,v_invoice,'3d200000-0000-4000-8000-000000000030');
  if (select original_amount from public.accounts_payable where id=(v_result->>'payable_id')::uuid)<>1060 then raise exception 'La CxP no respetó traslados menos retenciones.';end if;

  raise notice 'M3D cerrado: XML previo, conceptos CFDI, impuestos, distribución interna y CxP aprobados.';
end;
$test$;

rollback;
