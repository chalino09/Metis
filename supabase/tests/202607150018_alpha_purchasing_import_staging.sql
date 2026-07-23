-- Alpha purchasing staging: atomic package, idempotency, RLS and evidence-only contract.
begin;

do $test$
declare
  v_actor uuid;
  v_company uuid:='31000000-0000-4000-8000-000000000001';
  v_other uuid:='31000000-0000-4000-8000-000000000002';
  v_batch uuid;
  v_result jsonb;
  v_forbidden boolean:=false;
begin
  if to_regprocedure('public.begin_alpha_purchasing_import(uuid,date,text,jsonb)') is null
    or to_regprocedure('public.stage_alpha_purchasing_import_rows(uuid,text,jsonb)') is null
    or to_regprocedure('public.finish_alpha_purchasing_import(uuid,jsonb,jsonb)') is null
    or to_regprocedure('public.list_alpha_purchasing_import_batches(uuid,integer,integer)') is null then
    raise exception 'Faltan RPC de staging de Compras/CxP.';
  end if;

  select ur.user_id into v_actor from public.user_roles ur join public.roles r on r.id=ur.role_id where r.code='super_admin' limit 1;
  if v_actor is null then raise exception 'La prueba requiere Super Admin.'; end if;
  insert into public.companies(id,legal_name,display_name) values(v_company,'Compras staging','Compras staging'),(v_other,'Otra empresa','Otra empresa');
  insert into public.user_roles(user_id,role_id,company_id) select v_actor,id,v_company from public.roles where code='super_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_actor::text,true);

  v_result:=public.begin_alpha_purchasing_import(v_company,'2026-07-08','purchasing-hash',jsonb_build_array(
    jsonb_build_object('report_type','suppliers','original_name','cata_prv.xls','file_sha256','s','snapshot_date','2026-07-08','row_count',1),
    jsonb_build_object('report_type','purchase_orders','original_name','rpcon2.xls','file_sha256','o','snapshot_date','2026-07-08','row_count',2),
    jsonb_build_object('report_type','payable_documents','original_name','lfchvenc.xls','file_sha256','d','snapshot_date','2026-07-08','row_count',1),
    jsonb_build_object('report_type','supplier_payments','original_name','pag_det.xls','file_sha256','p','snapshot_date','2026-07-08','row_count',1)
  ));
  v_batch:=(v_result->>'batch_id')::uuid;
  if v_result->>'status'<>'loading' or v_batch is null then raise exception 'No inició el lote.'; end if;

  perform public.stage_alpha_purchasing_import_rows(v_batch,'suppliers','[{"external_code":"1","display_name":"Proveedor","counterparty_kind":"Proveedor","supplier_type":"NAL","tax_id":"AAA010101AAA","source_row_number":5,"source_row_hash":"supplier-1"}]'::jsonb);
  perform public.stage_alpha_purchasing_import_rows(v_batch,'purchase_orders','[{"source_order_key":"CUA|10","order_number":"10","branch_code":"CUA","supplier_external_code":"1","supplier_name":"Proveedor","warehouse_name":"GENERAL","ordered_date":"2026-07-01","currency_code":"MXN","source_currency":"PESOS","source_status":"Por Surtir","source_approval_status":"Aceptada","exchange_rate":1,"discount_percent":0,"source_row_number":7,"source_row_hash":"order-1"}]'::jsonb);
  perform public.stage_alpha_purchasing_import_rows(v_batch,'purchase_order_lines','[{"source_order_key":"CUA|10","line_number":1,"alpha_sku":"SKU-1","description":"Producto","unit":"PZA","quantity":2,"unit_cost_mxn":50,"source_row_number":8,"source_row_hash":"line-1"}]'::jsonb);
  perform public.stage_alpha_purchasing_import_rows(v_batch,'payable_documents','[{"source_document_key":"1|FAC-1|2026-07-01","folio":"FAC-1","supplier_external_code":"1","supplier_name":"Proveedor","issued_date":"2026-07-01","due_date":"2026-07-31","source_concept":"Factura","outstanding_amount":100,"currency_code":"MXN","source_currency":"PESOS","source_row_number":7,"source_row_hash":"doc-1"}]'::jsonb);
  perform public.stage_alpha_purchasing_import_rows(v_batch,'supplier_payments','[{"source_payment_key":"payment-1","application_folio":"5","branch_code":"CUA","payment_date":"2026-07-03","document_type":"F","document_folio":"FAC-1","supplier_name":"Proveedor","matched_supplier_external_code":"1","amount_mxn":40,"payment_method":"Efectivo","source_currency":"P","source_row_number":7,"source_row_hash":"payment-1"}]'::jsonb);

  v_result:=public.finish_alpha_purchasing_import(v_batch,
    '{"suppliers":1,"purchase_orders":1,"purchase_order_lines":1,"payable_documents":1,"payable_outstanding_total":100,"supplier_payments":1,"supplier_payment_total":40,"receipt_source_available":false}'::jsonb,
    '[{"severity":"warning","difference_code":"RECEIPT_SOURCE_NOT_AVAILABLE","message":"No hay recepción vinculable.","evidence":{"operational_effect":"none"}}]'::jsonb);
  if v_result->>'status'<>'staged' or (v_result->>'warnings')::integer<>1 then raise exception 'El lote no quedó preparado con su alerta.'; end if;
  if (select count(*) from public.alpha_purchasing_import_files where batch_id=v_batch)<>4
    or (select count(*) from public.alpha_purchasing_import_suppliers where batch_id=v_batch)<>1
    or (select count(*) from public.alpha_purchasing_import_orders where batch_id=v_batch)<>1
    or (select count(*) from public.alpha_purchasing_import_order_lines where batch_id=v_batch)<>1
    or (select count(*) from public.alpha_purchasing_import_payable_documents where batch_id=v_batch)<>1
    or (select count(*) from public.alpha_purchasing_import_payment_evidence where batch_id=v_batch)<>1 then
    raise exception 'El staging no conservó exactamente una copia de cada evidencia.';
  end if;
  if coalesce((select (summary->>'operational_import_ready')::boolean from public.alpha_purchasing_import_batches where id=v_batch),true) then
    raise exception 'El staging se marcó incorrectamente como importación operativa lista.';
  end if;

  v_result:=public.begin_alpha_purchasing_import(v_company,'2026-07-08','purchasing-hash','[{"report_type":"suppliers","original_name":"cata_prv.xls","file_sha256":"s","snapshot_date":"2026-07-08","row_count":1}]'::jsonb);
  if v_result->>'status'<>'duplicate' or (v_result->>'batch_id')::uuid<>v_batch then raise exception 'El reintento duplicó el paquete.'; end if;
  v_result:=public.list_alpha_purchasing_import_batches(v_company,1,20);
  if (v_result#>>'{pagination,total}')::integer<>1 or jsonb_array_length(v_result->'items')<>1 then raise exception 'El listado paginado no devolvió el lote.'; end if;

  perform set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000099',true);
  begin
    perform public.list_alpha_purchasing_import_batches(v_company,1,20);
  exception when others then v_forbidden:=position('No autorizado' in sqlerrm)>0;
  end;
  if not v_forbidden then raise exception 'RLS/RBAC permitió consultar el paquete sin membresía.'; end if;
end;
$test$;

rollback;
