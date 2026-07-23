begin;

do $test$
declare
  v_actor uuid;v_outsider uuid:='3e300000-0000-4000-8000-000000000099';
  v_company uuid:='3e300000-0000-4000-8000-000000000001';v_other uuid:='3e300000-0000-4000-8000-000000000002';
  v_supplier uuid;v_invoice uuid;v_pue_invoice uuid;v_payable uuid;v_pue_payable uuid;v_proposal uuid;v_pue_proposal uuid;v_account uuid;v_payment uuid;v_pue_payment uuid;v_application uuid;v_document uuid;
  v_result jsonb;v_forbidden boolean:=false;v_xml text;v_xml_duplicate text;v_xml_discordant text;v_hash text;v_duplicate_hash text;v_discordant_hash text;
  v_inventory bigint;v_ledger bigint;v_cost bigint;v_alpha bigint;v_invoice_state jsonb;v_payable_state jsonb;v_payment_state jsonb;v_bucket_public boolean;
begin
  if to_regprocedure('public.register_supplier_payment_document(uuid,uuid,text,text,text,text,bigint,text,jsonb)') is null or to_regprocedure('public.record_supplier_payment_rep_sat_verification(uuid,uuid,text,timestamptz,jsonb)') is null then raise exception 'Faltan RPC de M3E3.';end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='supplier_payment_documents' and policyname='supplier_payment_documents_read') or not exists(select 1 from pg_policies where schemaname='public' and tablename='supplier_payment_rep_sat_verifications' and policyname='supplier_payment_rep_sat_read') then raise exception 'Faltan RLS de comprobantes o verificación SAT.';end if;
  if to_regclass('storage.buckets') is not null then
    execute 'select public from storage.buckets where id=$1' into v_bucket_public using 'supplier-payment-documents';
    if v_bucket_public is distinct from false then raise exception 'El bucket de pagos no es privado.';end if;
  end if;
  select ur.user_id into v_actor from public.user_roles ur join public.roles r on r.id=ur.role_id where r.code='super_admin' limit 1;
  if v_actor is null then raise exception 'La prueba requiere Super Admin.';end if;
  insert into public.companies(id,legal_name,display_name,tax_id,base_currency_code) values(v_company,'Empresa M3E3','Empresa M3E3','BBB010101BBB','MXN'),(v_other,'Otra M3E3','Otra M3E3','CCC010101CCC','MXN');
  insert into auth.users(id,aud,role,email,encrypted_password) values(v_outsider,'authenticated','authenticated','ajeno-m3e3@example.com','');
  insert into public.user_roles(user_id,role_id,company_id) select v_actor,id,v_company from public.roles where code='super_admin' on conflict do nothing;
  insert into public.user_roles(user_id,role_id,company_id) select v_outsider,id,v_other from public.roles where code='direccion_admin';
  insert into public.suppliers(company_id,code,display_name,legal_entity_type,tax_id,country_code,is_active) values(v_company,'SUP-E3','Proveedor REP','moral','AAA010101AAA','MX',true) returning id into v_supplier;
  insert into public.supplier_invoices(company_id,supplier_id,source_kind,status,series,folio,fiscal_uuid,issued_date,due_date,currency_code,payment_method_code,payment_form_code,subtotal,total,base_total,expense_approved_at,confirmed_at)
  values(v_company,v_supplier,'expense','confirmed','E3','001','11111111-1111-4111-8111-111111111111',current_date-20,current_date+10,'MXN','PPD','99',100,100,100,now(),now()) returning id into v_invoice;
  insert into public.supplier_invoices(company_id,supplier_id,source_kind,status,series,folio,fiscal_uuid,issued_date,due_date,currency_code,payment_method_code,payment_form_code,subtotal,total,base_total,expense_approved_at,confirmed_at)
  values(v_company,v_supplier,'expense','confirmed','E3','002','22222222-2222-4222-8222-222222222222',current_date-10,current_date+5,'MXN','PUE','03',50,50,50,now(),now()) returning id into v_pue_invoice;
  insert into public.accounts_payable(company_id,supplier_id,supplier_invoice_id,currency_code,original_amount,outstanding_amount,issued_date,due_date) values(v_company,v_supplier,v_invoice,'MXN',100,60,current_date-20,current_date+10) returning id into v_payable;
  insert into public.accounts_payable(company_id,supplier_id,supplier_invoice_id,currency_code,original_amount,outstanding_amount,issued_date,due_date) values(v_company,v_supplier,v_pue_invoice,'MXN',50,0,current_date-10,current_date+5) returning id into v_pue_payable;
  insert into public.supplier_payment_proposals(company_id,supplier_id,currency_code,status,total_proposed,submitted_at,approved_at) values(v_company,v_supplier,'MXN','approved',40,now(),now()) returning id into v_proposal;
  insert into public.supplier_payment_proposals(company_id,supplier_id,currency_code,status,total_proposed,submitted_at,approved_at) values(v_company,v_supplier,'MXN','approved',50,now(),now()) returning id into v_pue_proposal;
  insert into public.supplier_paying_accounts(company_id,bank_name,alias,currency_code,account_last4) values(v_company,'Banco M3E3','Operativa','MXN','1234') returning id into v_account;
  insert into public.supplier_payments(company_id,proposal_id,supplier_id,paying_account_id,currency_code,effective_date,payment_method,reference,total_amount) values(v_company,v_proposal,v_supplier,v_account,'MXN',current_date,'03','REP-001',40) returning id into v_payment;
  insert into public.supplier_payment_applications(company_id,payment_id,accounts_payable_id,supplier_invoice_id,amount,balance_before,balance_after) values(v_company,v_payment,v_payable,v_invoice,40,100,60) returning id into v_application;
  insert into public.supplier_payments(company_id,proposal_id,supplier_id,paying_account_id,currency_code,effective_date,payment_method,reference,total_amount) values(v_company,v_pue_proposal,v_supplier,v_account,'MXN',current_date,'03','PUE-001',50) returning id into v_pue_payment;
  insert into public.supplier_payment_applications(company_id,payment_id,accounts_payable_id,supplier_invoice_id,amount,balance_before,balance_after) values(v_company,v_pue_payment,v_pue_payable,v_pue_invoice,50,50,0);
  if (select rep_status from public.supplier_payments where id=v_payment)<>'pending' or (select rep_status from public.supplier_payments where id=v_pue_payment)<>'not_required' then raise exception 'PUE/PPD no inicializaron el seguimiento REP correcto.';end if;
  if (select status from public.supplier_payments where id=v_payment)<>'confirmed' or (select outstanding_amount from public.accounts_payable where id=v_payable)<>60 then raise exception 'Un REP faltante alteró el pago o la CxP.';end if;

  select count(*) into v_inventory from public.inventory_balances;select count(*) into v_ledger from public.inventory_ledger;select count(*) into v_cost from public.product_costs;select count(*) into v_alpha from public.alpha_purchasing_import_payment_evidence;
  select to_jsonb(i) into v_invoice_state from public.supplier_invoices i where id=v_invoice;select to_jsonb(ap) into v_payable_state from public.accounts_payable ap where id=v_payable;select jsonb_build_object('status',status,'total_amount',total_amount,'reference',reference) into v_payment_state from public.supplier_payments where id=v_payment;

  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',v_actor::text,true);
  v_result:=public.register_supplier_payment_document(v_company,v_payment,'bank_receipt','banco.pdf',v_company||'/'||repeat('b',64)||'.pdf','application/pdf',2048,repeat('b',64),'{}');
  if v_result->>'status'<>'not_applicable' then raise exception 'No se adjuntó el comprobante bancario.';end if;
  v_result:=public.register_supplier_payment_document(v_company,v_payment,'bank_receipt','banco.pdf',v_company||'/'||repeat('b',64)||'.pdf','application/pdf',2048,repeat('b',64),'{}');
  if coalesce((v_result->>'idempotent')::boolean,false)=false or (select count(*) from public.supplier_payment_documents where company_id=v_company and sha256=repeat('b',64))<>1 then raise exception 'Se duplicó el comprobante bancario.';end if;
  begin perform public.register_supplier_payment_document(v_company,v_payment,'bank_receipt','mal.exe','x','application/octet-stream',10,repeat('c',64),'{}');exception when others then v_forbidden:=position('pdf, jpeg o png' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Se aceptó MIME bancario no permitido.';end if;v_forbidden:=false;

  v_xml:=format('<cfdi:Comprobante xmlns:cfdi="http://www.sat.gob.mx/cfd/4" xmlns:pago20="http://www.sat.gob.mx/Pagos20" xmlns:tfd="http://www.sat.gob.mx/TimbreFiscalDigital" Version="4.0" Fecha="%sT12:00:00" Moneda="XXX" Total="0" TipoDeComprobante="P"><cfdi:Emisor Rfc="AAA010101AAA"/><cfdi:Receptor Rfc="BBB010101BBB"/><cfdi:Complemento><pago20:Pagos Version="2.0"><pago20:Pago FechaPago="%sT09:30:00" FormaDePagoP="03" MonedaP="MXN" TipoCambioP="1" Monto="40"><pago20:DoctoRelacionado IdDocumento="11111111-1111-4111-8111-111111111111" MonedaDR="MXN" EquivalenciaDR="1" NumParcialidad="1" ImpSaldoAnt="100" ImpPagado="40" ImpSaldoInsoluto="60"/></pago20:Pago></pago20:Pagos><tfd:TimbreFiscalDigital UUID="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"/></cfdi:Complemento></cfdi:Comprobante>',current_date,current_date);
  v_hash:=encode(digest(convert_to(v_xml,'UTF8'),'sha256'),'hex');
  v_result:=public.register_supplier_payment_rep_xml(v_company,v_payment,'rep.xml',v_company||'/'||v_hash||'.xml','application/xml',octet_length(convert_to(v_xml,'UTF8')),v_hash,encode(convert_to(v_xml,'UTF8'),'base64'));v_document:=(v_result->>'id')::uuid;
  if v_result->>'status'<>'verified_local' or (select rep_status from public.supplier_payments where id=v_payment)<>'received' then raise exception 'REP válido no coincidió: %',v_result;end if;
  v_result:=public.register_supplier_payment_rep_xml(v_company,v_payment,'rep.xml',v_company||'/'||v_hash||'.xml','application/xml',octet_length(convert_to(v_xml,'UTF8')),v_hash,encode(convert_to(v_xml,'UTF8'),'base64'));
  if coalesce((v_result->>'idempotent')::boolean,false)=false then raise exception 'REP idéntico no fue idempotente.';end if;
  v_xml_duplicate:=replace(v_xml,'</cfdi:Comprobante>','  </cfdi:Comprobante>');v_duplicate_hash:=encode(digest(convert_to(v_xml_duplicate,'UTF8'),'sha256'),'hex');
  begin perform public.register_supplier_payment_rep_xml(v_company,v_payment,'rep-alterado.xml',v_company||'/'||v_duplicate_hash||'.xml','application/xml',octet_length(convert_to(v_xml_duplicate,'UTF8')),v_duplicate_hash,encode(convert_to(v_xml_duplicate,'UTF8'),'base64'));exception when others then v_forbidden:=position('uuid fiscal' in lower(sqlerrm))>0 or position('registrado' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Se aceptó UUID REP duplicado con otro archivo.';end if;v_forbidden:=false;
  begin update public.supplier_payment_documents set original_file_name='alterado.xml' where id=v_document;exception when others then v_forbidden:=position('inmutables' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Se modificó evidencia confirmada.';end if;v_forbidden:=false;
  begin delete from public.supplier_payment_documents where id=v_document;exception when others then v_forbidden:=position('inmutables' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Se eliminó evidencia confirmada.';end if;v_forbidden:=false;

  v_result:=public.record_supplier_payment_rep_sat_verification(v_company,v_document,'cancelled',clock_timestamp(),jsonb_build_object('source','SAT','reference','consulta cancelado'));
  if v_result->>'rep_status'<>'differences' or (select status from public.supplier_payments where id=v_payment)<>'confirmed' or (select outstanding_amount from public.accounts_payable where id=v_payable)<>60 then raise exception 'REP cancelado revirtió o alteró el pago/CxP.';end if;

  v_xml_discordant:=replace(replace(v_xml,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),'Monto="40"','Monto="99"');v_discordant_hash:=encode(digest(convert_to(v_xml_discordant,'UTF8'),'sha256'),'hex');
  v_result:=public.register_supplier_payment_rep_xml(v_company,v_payment,'rep-discordante.xml',v_company||'/'||v_discordant_hash||'.xml','text/xml',octet_length(convert_to(v_xml_discordant,'UTF8')),v_discordant_hash,encode(convert_to(v_xml_discordant,'UTF8'),'base64'));
  if v_result->>'status'<>'mismatch' or jsonb_array_length(v_result->'issues')=0 or (select rep_status from public.supplier_payments where id=v_payment)<>'differences' then raise exception 'REP discordante no conservó diferencias: %',v_result;end if;

  perform set_config('request.jwt.claim.sub',v_outsider::text,true);
  begin perform public.get_supplier_payment_detail(v_company,v_payment);exception when others then v_forbidden:=position('no autorizado' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Empresa ajena consultó comprobantes/REP.';end if;v_forbidden:=false;
  begin perform public.register_supplier_payment_document(v_company,v_payment,'bank_receipt','ajeno.pdf','ajeno','application/pdf',10,repeat('f',64),'{}');exception when others then v_forbidden:=position('no autorizado' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Empresa ajena adjuntó evidencia.';end if;

  perform set_config('request.jwt.claim.sub',v_actor::text,true);
  if (select to_jsonb(i) from public.supplier_invoices i where id=v_invoice)<>v_invoice_state then raise exception 'M3E3 modificó la factura.';end if;
  if (select to_jsonb(ap) from public.accounts_payable ap where id=v_payable)<>v_payable_state then raise exception 'M3E3 modificó la CxP.';end if;
  if (select jsonb_build_object('status',status,'total_amount',total_amount,'reference',reference) from public.supplier_payments where id=v_payment)<>v_payment_state then raise exception 'M3E3 modificó la realidad del pago.';end if;
  if (select count(*) from public.inventory_balances)<>v_inventory or (select count(*) from public.inventory_ledger)<>v_ledger or (select count(*) from public.product_costs)<>v_cost then raise exception 'M3E3 modificó inventario o costo.';end if;
  if (select count(*) from public.alpha_purchasing_import_payment_evidence)<>v_alpha then raise exception 'M3E3 importó aplicaciones históricas Alpha.';end if;
  raise notice 'M3E3: privado, SHA-256, MIME/tamaño, duplicados, RLS, PUE/PPD, REP válido/duplicado/cancelado/discordante, SAT separado, inmutabilidad y no afectación aprobados.';
end;
$test$;

rollback;
