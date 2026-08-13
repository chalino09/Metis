-- A persistent two-file package for historical sales evidence. nvtadesg and
-- cob_cte may arrive in either order. Reconciliation never creates sales,
-- payments, cash movements or inventory movements.

create or replace function public.begin_alpha_sales_evidence_file(
  p_company_id uuid,
  p_source text,
  p_source_kind text,
  p_file_name text,
  p_file_type text,
  p_file_sha256 text,
  p_cutoff_date date
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_batch_id uuid;
  v_duplicate_batch_id uuid;
  v_has_sales boolean;
  v_has_collections boolean;
begin
  if auth.uid() is null or not public.can_import_commercial(p_company_id,'sales') then
    raise exception 'No autorizado para preparar evidencia histórica de ventas.';
  end if;
  if p_source not in ('manual_upload','local_development') then raise exception 'Origen de importación no permitido.'; end if;
  if p_source_kind not in ('sales','collections') then raise exception 'Tipo de evidencia no permitido.'; end if;
  if p_cutoff_date is null then raise exception 'El archivo no contiene una fecha de corte válida.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text || ':sales-evidence:' || p_cutoff_date::text,0));

  select b.id into v_duplicate_batch_id
  from public.import_batches b join public.import_files f on f.import_batch_id=b.id
  where b.company_id=p_company_id and b.import_type='sales' and f.file_sha256=p_file_sha256
  order by b.started_at desc limit 1;
  if v_duplicate_batch_id is not null then
    return jsonb_build_object('status','duplicate','batch_id',v_duplicate_batch_id,'message','Este archivo ya forma parte de un paquete histórico de ventas.');
  end if;

  select b.id into v_batch_id
  from public.import_batches b
  where b.company_id=p_company_id and b.import_type='sales' and b.snapshot_date=p_cutoff_date
    and b.status in ('processing','staged','validation_failed')
    and not exists (
      select 1 from public.import_files f where f.import_batch_id=b.id and
        case when p_source_kind='sales' then f.original_name ~* '^nvtadesg_' else f.original_name ~* '^cob_cte_' end
    )
  order by b.started_at desc limit 1 for update;

  if v_batch_id is null then
    insert into public.import_batches(company_id,import_type,source,file_sha256,status,records_received,imported_by,snapshot_date,last_activity_at)
    values(p_company_id,'sales',p_source,p_file_sha256,'processing',0,auth.uid(),p_cutoff_date,now()) returning id into v_batch_id;
  else
    update public.import_batches set status='processing',last_activity_at=now(),completed_at=null,closed_at=null where id=v_batch_id;
  end if;

  insert into public.import_files(import_batch_id,original_name,file_type,file_sha256,row_count)
  values(v_batch_id,p_file_name,p_file_type,p_file_sha256,0);
  select exists(select 1 from public.import_files where import_batch_id=v_batch_id and original_name ~* '^nvtadesg_'),
         exists(select 1 from public.import_files where import_batch_id=v_batch_id and original_name ~* '^cob_cte_')
    into v_has_sales,v_has_collections;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'sales_evidence.file_added','import_batch',v_batch_id,
    jsonb_build_object('source_kind',p_source_kind,'original_name',p_file_name,'cutoff_date',p_cutoff_date,'has_sales',v_has_sales,'has_collections',v_has_collections));
  return jsonb_build_object('status','processing','batch_id',v_batch_id,'has_sales',v_has_sales,'has_collections',v_has_collections);
end $$;

create or replace function public.reconcile_alpha_sales_evidence(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_batch public.import_batches%rowtype;
  v_has_sales boolean;
  v_has_collections boolean;
  v_sales integer:=0;
  v_collections integer:=0;
  v_exact integer:=0;
  v_amount_mismatch integer:=0;
  v_sales_without_collection integer:=0;
  v_collections_without_sale integer:=0;
begin
  select * into v_batch from public.import_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.can_import_commercial(v_batch.company_id,'sales') then raise exception 'No autorizado.'; end if;
  if v_batch.import_type<>'sales' then raise exception 'Tipo de lote inválido.'; end if;
  select exists(select 1 from public.import_files where import_batch_id=p_batch_id and original_name ~* '^nvtadesg_'),
         exists(select 1 from public.import_files where import_batch_id=p_batch_id and original_name ~* '^cob_cte_')
    into v_has_sales,v_has_collections;

  delete from public.import_staging_errors where import_batch_id=p_batch_id
    and error_code in ('VENTA_SIN_COBRANZA','COBRANZA_SIN_VENTA','IMPORTE_COBRANZA_NO_CUADRA');

  if v_has_sales and v_has_collections then
    with sales as (
      select regexp_replace(coalesce(normalized_data->>'customerExternalCode',''),'^0+','','g') customer_code,
        normalized_data->>'sourceInvoice' invoice,round(sum(coalesce((normalized_data->>'lineTotal')::numeric,0)),2) amount
      from public.import_staging_rows where import_batch_id=p_batch_id and normalized_data->>'evidenceKind'='sale_line'
        and nullif(normalized_data->>'sourceInvoice','') is not null
      group by 1,2
    ), collections as (
      select regexp_replace(coalesce(normalized_data->>'customerExternalCode',''),'^0+','','g') customer_code,
        case when upper(trim(coalesce(normalized_data->>'reference',''))) ~ '^C1[[:space:]]*[0-9]+$'
          then regexp_replace(upper(trim(normalized_data->>'reference')),'^C1[[:space:]]*','','g') end invoice,
        round(sum(coalesce((normalized_data->>'amount')::numeric,0)),2) amount
      from public.import_staging_rows where import_batch_id=p_batch_id and normalized_data->>'evidenceKind'='collection'
      group by 1,2
    ), matched as (
      select s.customer_code,s.invoice,s.amount sale_amount,c.amount collection_amount
      from sales s join collections c using(customer_code,invoice)
    )
    select (select count(*) from sales),(select count(*) from collections where invoice is not null),
      count(*) filter(where abs(sale_amount-collection_amount)<=0.01),
      count(*) filter(where abs(sale_amount-collection_amount)>0.01),
      (select count(*) from sales s where not exists(select 1 from collections c where c.customer_code=s.customer_code and c.invoice=s.invoice)),
      (select count(*) from collections c where c.invoice is not null and not exists(select 1 from sales s where s.customer_code=c.customer_code and s.invoice=c.invoice))
    into v_sales,v_collections,v_exact,v_amount_mismatch,v_sales_without_collection,v_collections_without_sale from matched;

    if v_amount_mismatch>0 then
      insert into public.import_staging_errors(import_batch_id,severity,error_code,message)
      values(p_batch_id,'warning','IMPORTE_COBRANZA_NO_CUADRA',format('%s facturas tienen un importe distinto entre venta y cobranza.',v_amount_mismatch));
    end if;
    if v_sales_without_collection>0 then
      insert into public.import_staging_errors(import_batch_id,severity,error_code,message)
      values(p_batch_id,'warning','VENTA_SIN_COBRANZA',format('%s facturas de venta no tienen cobranza compatible.',v_sales_without_collection));
    end if;
    if v_collections_without_sale>0 then
      insert into public.import_staging_errors(import_batch_id,severity,error_code,message)
      values(p_batch_id,'warning','COBRANZA_SIN_VENTA',format('%s referencias de cobranza no tienen una venta compatible.',v_collections_without_sale));
    end if;
  end if;

  update public.import_batches set status='staged',notes=case
    when not v_has_sales then 'Paquete 1/2: falta nvtadesg.'
    when not v_has_collections then 'Paquete 1/2: falta cob_cte.'
    else 'Paquete 2/2 conciliado como evidencia; promoción operativa no habilitada.' end,last_activity_at=now()
  where id=p_batch_id;
  perform public.refresh_import_staging_batch(p_batch_id,false);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_batch.company_id,auth.uid(),'sales_evidence.reconciled','import_batch',p_batch_id,
    jsonb_build_object('complete',v_has_sales and v_has_collections,'sales',v_sales,'collections',v_collections,'exact_matches',v_exact,
      'amount_mismatches',v_amount_mismatch,'sales_without_collection',v_sales_without_collection,'collections_without_sale',v_collections_without_sale,'promotion_enabled',false));
  return jsonb_build_object('status',(select status from public.import_batches where id=p_batch_id),'batch_id',p_batch_id,
    'has_sales',v_has_sales,'has_collections',v_has_collections,'complete',v_has_sales and v_has_collections,
    'sales',v_sales,'collections',v_collections,'exact_matches',v_exact,'amount_mismatches',v_amount_mismatch,
    'sales_without_collection',v_sales_without_collection,'collections_without_sale',v_collections_without_sale,
    'message',case when not v_has_sales then 'Archivo guardado · falta nvtadesg para completar el paquete 1/2.'
      when not v_has_collections then 'Archivo guardado · falta cob_cte para completar el paquete 1/2.'
      else format('Paquete 2/2 conciliado: %s coincidencias exactas; %s diferencias de importe.',v_exact,v_amount_mismatch) end);
end $$;

create or replace function public.finish_alpha_sales_evidence_file(p_batch_id uuid,p_file_errors jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.import_batches%rowtype; v_received integer;
begin
  select * into v_batch from public.import_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.can_import_commercial(v_batch.company_id,'sales') then raise exception 'No autorizado.'; end if;
  if v_batch.import_type<>'sales' or v_batch.status<>'processing' then raise exception 'El lote no está cargando evidencia.'; end if;
  insert into public.import_staging_errors(import_batch_id,severity,error_code,message,row_number,alpha_sku,location_code,context_key)
  select p_batch_id,item->>'severity',item->>'error_code',item->>'message',nullif(item->>'row_number','')::int,nullif(item->>'alpha_sku',''),nullif(item->>'location_code',''),nullif(item->>'context_key','')
  from jsonb_array_elements(coalesce(p_file_errors,'[]'::jsonb)) item;
  select count(*) into v_received from public.import_staging_rows where import_batch_id=p_batch_id;
  update public.import_batches set records_received=v_received where id=p_batch_id;
  update public.import_files f set row_count=(
    select count(*) from public.import_staging_rows r
    where r.import_batch_id=p_batch_id and r.source_file=f.original_name
  ) where f.import_batch_id=p_batch_id;
  return public.reconcile_alpha_sales_evidence(p_batch_id);
end $$;

create or replace function public.get_alpha_sales_evidence_status(p_import_batch_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_batch public.import_batches%rowtype; v_result jsonb;
begin
  select * into v_batch from public.import_batches where id=p_import_batch_id;
  if not found or auth.uid() is null or not (public.can_import_commercial(v_batch.company_id,'sales') or public.has_company_permission(v_batch.company_id,'view_import_audit')) then raise exception 'No autorizado.'; end if;
  if v_batch.import_type<>'sales' then raise exception 'Tipo de lote inválido.'; end if;
  with sales as (
    select regexp_replace(coalesce(normalized_data->>'customerExternalCode',''),'^0+','','g') customer_code,normalized_data->>'sourceInvoice' invoice,
      round(sum(coalesce((normalized_data->>'lineTotal')::numeric,0)),2) amount
    from public.import_staging_rows where import_batch_id=p_import_batch_id and normalized_data->>'evidenceKind'='sale_line' and nullif(normalized_data->>'sourceInvoice','') is not null group by 1,2
  ), collections as (
    select regexp_replace(coalesce(normalized_data->>'customerExternalCode',''),'^0+','','g') customer_code,
      case when upper(trim(coalesce(normalized_data->>'reference',''))) ~ '^C1[[:space:]]*[0-9]+$' then regexp_replace(upper(trim(normalized_data->>'reference')),'^C1[[:space:]]*','','g') end invoice,
      round(sum(coalesce((normalized_data->>'amount')::numeric,0)),2) amount
    from public.import_staging_rows where import_batch_id=p_import_batch_id and normalized_data->>'evidenceKind'='collection' group by 1,2
  ), matched as (select s.amount sale_amount,c.amount collection_amount from sales s join collections c using(customer_code,invoice))
  select jsonb_build_object(
    'has_sales',exists(select 1 from public.import_files where import_batch_id=p_import_batch_id and original_name ~* '^nvtadesg_'),
    'has_collections',exists(select 1 from public.import_files where import_batch_id=p_import_batch_id and original_name ~* '^cob_cte_'),
    'files',coalesce((select jsonb_agg(jsonb_build_object('name',original_name,'row_count',row_count) order by created_at) from public.import_files where import_batch_id=p_import_batch_id),'[]'::jsonb),
    'sales',(select count(*) from sales),'collections',(select count(*) from collections where invoice is not null),
    'exact_matches',(select count(*) from matched where abs(sale_amount-collection_amount)<=0.01),
    'amount_mismatches',(select count(*) from matched where abs(sale_amount-collection_amount)>0.01),
    'sales_without_collection',(select count(*) from sales s where not exists(select 1 from collections c where c.customer_code=s.customer_code and c.invoice=s.invoice)),
    'collections_without_sale',(select count(*) from collections c where c.invoice is not null and not exists(select 1 from sales s where s.customer_code=c.customer_code and s.invoice=c.invoice)),
    'promotion_enabled',false
  ) into v_result;
  return v_result || jsonb_build_object('complete',(v_result->>'has_sales')::boolean and (v_result->>'has_collections')::boolean);
end $$;

revoke all on function public.begin_alpha_sales_evidence_file(uuid,text,text,text,text,text,date) from public;
revoke all on function public.reconcile_alpha_sales_evidence(uuid) from public;
revoke all on function public.finish_alpha_sales_evidence_file(uuid,jsonb) from public;
revoke all on function public.get_alpha_sales_evidence_status(uuid) from public;
grant execute on function public.begin_alpha_sales_evidence_file(uuid,text,text,text,text,text,date) to authenticated;
grant execute on function public.reconcile_alpha_sales_evidence(uuid) to authenticated;
grant execute on function public.finish_alpha_sales_evidence_file(uuid,jsonb) to authenticated;
grant execute on function public.get_alpha_sales_evidence_status(uuid) to authenticated;
