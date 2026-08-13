begin;

do $sales_evidence_package$
declare
  v_company uuid := '8a120005-0000-4000-8000-000000000001';
  v_user uuid := '8a120005-0000-4000-8000-000000000010';
  v_batch uuid;
  v_result jsonb;
  v_sales_before bigint;
begin
  insert into public.companies(id,legal_name,display_name)
  values(v_company,'Evidencia ventas QA','Evidencia ventas QA');
  insert into auth.users(id,aud,role,email,encrypted_password)
  values(v_user,'authenticated','authenticated','sales-evidence@example.com','');
  insert into public.user_roles(user_id,role_id,company_id)
  select v_user,id,v_company from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_user::text,true);
  select count(*) into v_sales_before from public.sales where company_id=v_company;

  v_result:=public.begin_alpha_sales_evidence_file(v_company,'manual_upload','sales','nvtadesg_20260708_QA.xls','xls',repeat('a',64),date '2026-07-08');
  v_batch:=(v_result->>'batch_id')::uuid;
  perform public.stage_alpha_sales_staging_rows(v_batch,jsonb_build_array(
    jsonb_build_object('row_number',10,'source_file','nvtadesg_20260708_QA.xls','detected_type','sales','raw_data','{}'::jsonb,'validation_status','valid','normalized_data',jsonb_build_object('evidenceKind','sale_line','customerExternalCode','00002','sourceInvoice','234','lineTotal',60)),
    jsonb_build_object('row_number',11,'source_file','nvtadesg_20260708_QA.xls','detected_type','sales','raw_data','{}'::jsonb,'validation_status','valid','normalized_data',jsonb_build_object('evidenceKind','sale_line','customerExternalCode','2','sourceInvoice','234','lineTotal',40))
  ),'[]'::jsonb);
  v_result:=public.finish_alpha_sales_evidence_file(v_batch,'[]'::jsonb);
  if (v_result->>'complete')::boolean or v_result->>'message' not like '%1/2%' then raise exception 'El primer archivo no quedó como paquete 1/2: %',v_result; end if;

  v_result:=public.begin_alpha_sales_evidence_file(v_company,'manual_upload','collections','cob_cte_20260708_QA.xlsx','xlsx',repeat('b',64),date '2026-07-08');
  if (v_result->>'batch_id')::uuid<>v_batch then raise exception 'cob_cte no se anexó al paquete existente.'; end if;
  perform public.stage_alpha_sales_staging_rows(v_batch,jsonb_build_array(
    jsonb_build_object('row_number',1000001,'source_file','cob_cte_20260708_QA.xlsx','detected_type','sales','raw_data','{}'::jsonb,'validation_status','valid','normalized_data',jsonb_build_object('evidenceKind','collection','customerExternalCode','00002','reference','C1 234','amount',100))
  ),'[]'::jsonb);
  v_result:=public.finish_alpha_sales_evidence_file(v_batch,'[]'::jsonb);
  if not (v_result->>'complete')::boolean or (v_result->>'exact_matches')::integer<>1 then raise exception 'La conciliación 2/2 no cuadró: %',v_result; end if;
  if exists(select 1 from public.import_files where import_batch_id=v_batch and ((original_name like 'nvtadesg%' and row_count<>2) or (original_name like 'cob_cte%' and row_count<>1))) then raise exception 'Los conteos por archivo se mezclaron.'; end if;
  if (select count(*) from public.sales where company_id=v_company)<>v_sales_before then raise exception 'La evidencia creó ventas operativas.'; end if;
  raise notice 'Paquete ventas/cobranza: 1/2 persistente, 2/2 conciliado y sin promoción operativa.';
end;
$sales_evidence_package$;

rollback;
