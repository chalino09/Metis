begin;

do $historical_sales_promotion$
declare
  v_company uuid := '8a120010-0000-4000-8000-000000000001';
  v_user uuid := '8a120010-0000-4000-8000-000000000010';
  v_location uuid;
  v_product uuid;
  v_batch uuid;
  v_result jsonb;
  v_sale_id uuid;
begin
  insert into public.companies(id,legal_name,display_name,base_currency_code)
  values(v_company,'Ventas históricas QA','Ventas históricas QA','MXN');
  insert into auth.users(id,aud,role,email,encrypted_password)
  values(v_user,'authenticated','authenticated','historical-sales@example.com','');
  insert into public.user_roles(user_id,role_id,company_id)
  select v_user,id,v_company from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_user::text,true);

  insert into public.locations(company_id,external_code,name,location_type)
  values(v_company,'QA','Sucursal QA','sucursal') returning id into v_location;
  insert into public.products(company_id,alpha_sku,name,unit)
  values(v_company,'SKU-010','Producto histórico QA','PZA') returning id into v_product;

  v_result:=public.begin_alpha_sales_evidence_file(v_company,'manual_upload','sales','nvtadesg_20260708_QA.xls','xls',repeat('a',64),date '2026-07-08');
  v_batch:=(v_result->>'batch_id')::uuid;
  perform public.stage_alpha_sales_staging_rows(v_batch,jsonb_build_array(
    jsonb_build_object('row_number',10,'source_file','nvtadesg_20260708_QA.xls','detected_type','sales','raw_data','{}'::jsonb,'validation_status','valid','normalized_data',jsonb_build_object(
      'evidenceKind','sale_line','saleDate','2026-07-01','sourceFolio','F-010','sourceInvoice','1010','sourceStatus','Pagada',
      'locationCode','QA','warehouseName','QA','canonicalLocationId',v_location,'canonicalLocationCode','QA',
      'customerExternalCode','00999','customerName','Cliente histórico QA','alphaSku','SKU-010','description','Producto histórico QA',
      'unit','PZA','quantity',1,'unitPrice',100,'discountAmount',16,'lineAmount',116,'lineTotal',116
    ))
  ),'[]'::jsonb);
  perform public.finish_alpha_sales_evidence_file(v_batch,'[]'::jsonb);

  v_result:=public.begin_alpha_sales_evidence_file(v_company,'manual_upload','collections','cob_cte_20260708_QA.xls','xls',repeat('b',64),date '2026-07-08');
  perform public.stage_alpha_sales_staging_rows(v_batch,jsonb_build_array(
    jsonb_build_object('row_number',1000001,'source_file','cob_cte_20260708_QA.xls','detected_type','sales','raw_data','{}'::jsonb,'validation_status','valid','normalized_data',jsonb_build_object(
      'evidenceKind','collection','customerExternalCode','00999','reference','C1 1010','amount',116
    ))
  ),'[]'::jsonb);
  perform public.finish_alpha_sales_evidence_file(v_batch,'[]'::jsonb);

  v_result:=public.preview_alpha_historical_sales_promotion(v_batch);
  if not (v_result->>'can_promote')::boolean or (v_result->>'eligible_documents')::integer<>1
    or (v_result->>'taxable_amount')::numeric<>100 or (v_result->>'tax_amount')::numeric<>16
    or (v_result->>'total_amount')::numeric<>116 then
    raise exception 'Preview histórico inesperado: %',v_result;
  end if;

  v_result:=public.promote_alpha_historical_sales(v_batch,'Validación transaccional del historial conciliado.');
  if v_result->>'status'<>'completed' or (v_result->>'sales_imported')::integer<>1
    or (v_result->>'items_imported')::integer<>1 or (v_result->>'tickets_imported')::integer<>1 then
    raise exception 'Promoción histórica inesperada: %',v_result;
  end if;
  select id into v_sale_id from public.sales where source_import_batch_id=v_batch;
  if not found then raise exception 'No se creó la venta canónica.'; end if;
  if exists(select 1 from public.sale_payments where sale_id=v_sale_id)
    or exists(select 1 from public.customer_receivables where sale_id=v_sale_id)
    or exists(select 1 from public.inventory_ledger ledger join public.sale_items item on item.id=ledger.sale_item_id where item.sale_id=v_sale_id)
    or exists(select 1 from public.ticket_print_outbox outbox join public.canonical_tickets ticket on ticket.id=outbox.canonical_ticket_id where ticket.sale_id=v_sale_id) then
    raise exception 'La promoción histórica creó efectos operativos.';
  end if;
  if (select source_kind from public.sales where id=v_sale_id)<>'alpha_historical'
    or (select subtotal_amount from public.sales where id=v_sale_id)<>100
    or (select tax_amount from public.sales where id=v_sale_id)<>16
    or (select total_amount from public.sales where id=v_sale_id)<>116 then
    raise exception 'La venta no conservó origen o importes.';
  end if;
  if not exists(select 1 from public.canonical_tickets where sale_id=v_sale_id)
    or not exists(select 1 from public.audit_log where entity_id=v_batch and action='sales_history.promoted') then
    raise exception 'Faltó ticket o auditoría.';
  end if;

  begin
    insert into public.sale_cancellations(company_id,sale_id,reason,client_request_id)
    values(v_company,v_sale_id,'No debe permitirse',gen_random_uuid());
    raise exception 'La cancelación histórica no fue bloqueada.';
  exception when others then
    if sqlerrm='La cancelación histórica no fue bloqueada.' or sqlerrm not like 'Las ventas históricas importadas son de solo consulta%' then raise; end if;
  end;
  begin
    insert into public.sale_returns(company_id,sale_id,location_id,currency_code,reason,financial_adjustment_kind,external_reference,client_request_id)
    values(v_company,v_sale_id,v_location,'MXN','No debe permitirse','external_refund','QA',gen_random_uuid());
    raise exception 'La devolución histórica no fue bloqueada.';
  exception when others then
    if sqlerrm='La devolución histórica no fue bloqueada.' or sqlerrm not like 'Las ventas históricas importadas son de solo consulta%' then raise; end if;
  end;

  v_result:=public.promote_alpha_historical_sales(v_batch,'Reintento idempotente.');
  if not (v_result->>'idempotent')::boolean or (select count(*) from public.sales where source_import_batch_id=v_batch)<>1 then
    raise exception 'El reintento duplicó la venta: %',v_result;
  end if;
  raise notice 'Ventas históricas: venta, partida y ticket creados; 0 efectos operativos; reintento idempotente.';
end;
$historical_sales_promotion$;

rollback;
