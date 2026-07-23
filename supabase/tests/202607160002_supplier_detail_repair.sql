begin;

do $test$
declare
  v_actor uuid;
  v_company uuid:='34000000-0000-4000-8000-000000000001';
  v_batch uuid;
  v_ids uuid[]:='{}';
  v_id uuid;
  v_result jsonb;
begin
  select ur.user_id into v_actor from public.user_roles ur join public.roles r on r.id=ur.role_id where r.code='super_admin' limit 1;
  if v_actor is null then raise exception 'La prueba requiere Super Admin.'; end if;
  insert into public.companies(id,legal_name,display_name) values(v_company,'Reparación proveedores','Reparación proveedores');
  insert into public.user_roles(user_id,role_id,company_id) select v_actor,id,v_company from public.roles where code='super_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',v_actor::text,true);
  for i in 1..4 loop
    insert into public.suppliers(company_id,code,display_name) values(v_company,'SUP-'||i,'Proveedor '||i) returning id into v_id;
    v_ids:=array_append(v_ids,v_id);
  end loop;
  insert into public.alpha_purchasing_import_batches(company_id,cutoff_date,content_sha256,status,records_received,imported_by,summary,completed_at,supplier_promotion_completed_at,supplier_promotion_summary)
  values(v_company,'2026-07-08','repair-details-test','staged',4,v_actor,'{"suppliers":4,"error_count":0}',now(),now(),'{"source_suppliers":4,"promoted":4,"pending_exceptions":0}') returning id into v_batch;
  for i in 1..4 loop
    insert into public.alpha_purchasing_import_suppliers(batch_id,external_code,display_name,source_row_number,source_row_hash,promoted_supplier_id)
    values(v_batch,i::text,'Proveedor '||i,i,'old-'||i,v_ids[i]);
    insert into public.supplier_external_references(company_id,supplier_id,source_system,external_code,source_row_hash)
    values(v_company,v_ids[i],'alpha',i::text,'old-'||i);
  end loop;
  v_result:=public.repair_alpha_supplier_details(v_company,'2026-07-08','[
    {"external_code":"1","display_name":"Proveedor 1","supplier_type":"NAL","tax_id":"AAA010101AAA","phone":"5550000001","source_row_hash":"new-1"},
    {"external_code":"2","display_name":"Proveedor 2","supplier_type":"NAL","tax_id":"XAXX010101000","phone":"5550000002","source_row_hash":"new-2"},
    {"external_code":"3","display_name":"Proveedor 3","supplier_type":"NAL","tax_id":"BBB010101BBB","source_row_hash":"new-3"},
    {"external_code":"4","display_name":"Proveedor 4","supplier_type":"NAL","tax_id":"BBB010101BBB","source_row_hash":"new-4"}
  ]'::jsonb);
  if v_result->>'status'<>'completed' or (v_result#>>'{summary,canonical_rfc_updated}')::int<>1 or (v_result#>>'{summary,duplicate_rfc_rows}')::int<>2 then raise exception 'Resumen de reparación incorrecto: %',v_result;end if;
  if (select tax_id from public.suppliers where id=v_ids[1])<>'AAA010101AAA' then raise exception 'No se recuperó el RFC canónico seguro.';end if;
  if exists(select 1 from public.suppliers where id in(v_ids[2],v_ids[3],v_ids[4]) and tax_id is not null) then raise exception 'Se aplicó un RFC genérico o duplicado.';end if;
  if (select phone from public.suppliers where id=v_ids[2])<>'5550000002' then raise exception 'No se reparó el contacto no fiscal.';end if;
  if (select phone_e164 from public.suppliers where id=v_ids[2])<>'+525550000002' or (select phone_extension from public.suppliers where id=v_ids[2]) is not null then raise exception 'No se normalizó el teléfono reparado.';end if;
  if (select metadata->>'source_tax_id' from public.supplier_external_references where supplier_id=v_ids[2])<>'XAXX010101000' then raise exception 'No se conservó el RFC fuente como evidencia.';end if;
  if not exists(select 1 from public.audit_log where company_id=v_company and action='alpha_suppliers.details_repaired' and entity_id=v_batch) then raise exception 'Falta auditoría de reparación.';end if;
  raise notice 'Módulo 3A: reparación de RFC/contacto aprobada sin reimportar el lote.';
end;
$test$;

rollback;
