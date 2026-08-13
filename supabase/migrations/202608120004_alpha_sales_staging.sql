-- Alpha nvtadesg is accepted as auditable evidence in the existing migration
-- center. This migration intentionally adds no sales-domain tables and no
-- promotion path: the report lacks payment/cash-register provenance.

alter table public.import_batches drop constraint if exists import_batches_import_type_check;
alter table public.import_batches add constraint import_batches_import_type_check
  check (import_type in ('products','inventory','prices','costs','collaborators','sales','unsupported'));

alter table public.import_staging_rows drop constraint if exists import_staging_rows_detected_type_check;
alter table public.import_staging_rows add constraint import_staging_rows_detected_type_check
  check (detected_type in ('products','inventory','prices','costs','collaborators','sales'));

create or replace function public.begin_alpha_sales_staging(
  p_company_id uuid, p_source text, p_file_name text, p_file_type text, p_file_sha256 text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_existing public.import_batches%rowtype; v_batch_id uuid;
begin
  if auth.uid() is null or not public.can_import_commercial(p_company_id, 'sales') then raise exception 'No autorizado para preparar ventas históricas.'; end if;
  if p_source not in ('manual_upload','local_development') then raise exception 'Origen de importación no permitido.'; end if;
  select * into v_existing from public.import_batches
  where company_id=p_company_id and import_type='sales' and file_sha256=p_file_sha256
  order by started_at desc limit 1;
  if found then
    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
    values(p_company_id,auth.uid(),'import.duplicate_detected','import_batch',v_existing.id,jsonb_build_object('original_name',p_file_name,'file_sha256',p_file_sha256,'import_type','sales','existing_status',v_existing.status));
    return jsonb_build_object('status','duplicate','batch_id',v_existing.id,'message','Este archivo de ventas ya tiene un staging registrado; descártalo o revísalo antes de volver a cargarlo.');
  end if;
  insert into public.import_batches(company_id,import_type,source,file_sha256,status,records_received,imported_by,last_activity_at)
  values(p_company_id,'sales',p_source,p_file_sha256,'processing',0,auth.uid(),now()) returning id into v_batch_id;
  insert into public.import_files(import_batch_id,original_name,file_type,file_sha256,row_count)
  values(v_batch_id,p_file_name,p_file_type,p_file_sha256,0);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'sales_evidence.staging_started','import_batch',v_batch_id,jsonb_build_object('original_name',p_file_name,'file_sha256',p_file_sha256));
  return jsonb_build_object('status','processing','batch_id',v_batch_id);
end $$;

create or replace function public.stage_alpha_sales_staging_rows(p_batch_id uuid, p_rows jsonb, p_errors jsonb default '[]'::jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare v_batch public.import_batches%rowtype; v_received integer;
begin
  select * into v_batch from public.import_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.can_import_commercial(v_batch.company_id,'sales') then raise exception 'No autorizado.'; end if;
  if v_batch.import_type<>'sales' or v_batch.status<>'processing' then raise exception 'El lote de ventas no está disponible para carga.'; end if;
  if exists(select 1 from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) item where item->>'detected_type'<>'sales') then raise exception 'El lote solo acepta partidas de ventas.'; end if;
  insert into public.import_staging_rows(import_batch_id,row_number,source_file,detected_type,raw_data,normalized_data,validation_status)
  select p_batch_id,(item->>'row_number')::int,item->>'source_file','sales',coalesce(item->'raw_data','{}'),coalesce(item->'normalized_data','{}'),coalesce(item->>'validation_status','valid')
  from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) item;
  insert into public.import_staging_errors(import_batch_id,severity,error_code,message,row_number,alpha_sku,location_code,context_key)
  select p_batch_id,item->>'severity',item->>'error_code',item->>'message',nullif(item->>'row_number','')::int,nullif(item->>'alpha_sku',''),nullif(item->>'location_code',''),nullif(item->>'context_key','')
  from jsonb_array_elements(coalesce(p_errors,'[]'::jsonb)) item;
  update public.import_staging_errors e set staging_row_id=r.id
  from public.import_staging_rows r
  where e.import_batch_id=p_batch_id and e.staging_row_id is null and r.import_batch_id=p_batch_id and e.row_number=r.row_number;
  select count(*) into v_received from public.import_staging_rows where import_batch_id=p_batch_id;
  update public.import_batches set records_received=v_received,last_activity_at=now() where id=p_batch_id;
  update public.import_files set row_count=v_received where import_batch_id=p_batch_id;
end $$;

create or replace function public.finish_alpha_sales_staging(p_batch_id uuid, p_file_errors jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.import_batches%rowtype;
begin
  select * into v_batch from public.import_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.can_import_commercial(v_batch.company_id,'sales') then raise exception 'No autorizado.'; end if;
  if v_batch.import_type<>'sales' then raise exception 'Tipo de lote inválido.'; end if;
  if v_batch.status<>'processing' then return jsonb_build_object('status',v_batch.status,'batch_id',v_batch.id); end if;
  insert into public.import_staging_errors(import_batch_id,severity,error_code,message,row_number,alpha_sku,location_code,context_key)
  select p_batch_id,item->>'severity',item->>'error_code',item->>'message',nullif(item->>'row_number','')::int,nullif(item->>'alpha_sku',''),nullif(item->>'location_code',''),nullif(item->>'context_key','')
  from jsonb_array_elements(coalesce(p_file_errors,'[]'::jsonb)) item;
  update public.import_batches set status='staged',last_activity_at=now(),notes='Evidencia de nvtadesg preparada; promoción histórica no habilitada.' where id=p_batch_id;
  perform public.refresh_import_staging_batch(p_batch_id,false);
  select * into v_batch from public.import_batches where id=p_batch_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_batch.company_id,auth.uid(),'sales_evidence.staged','import_batch',p_batch_id,jsonb_build_object('records_received',v_batch.records_received,'valid_rows',v_batch.valid_rows,'warning_rows',v_batch.warning_rows,'error_rows',v_batch.error_rows,'promotion_enabled',false));
  return jsonb_build_object('status',v_batch.status,'batch_id',v_batch.id,'records_received',v_batch.records_received,'valid_rows',v_batch.valid_rows,'warning_rows',v_batch.warning_rows,'error_rows',v_batch.error_rows,'blocking_errors',v_batch.blocking_error_count,'pending_warnings',v_batch.pending_warning_count,'message','Las ventas quedaron como evidencia en staging; su promoción no está habilitada.');
end $$;

create or replace function public.fail_alpha_sales_staging(p_batch_id uuid, p_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare v_company uuid;
begin
  select company_id into v_company from public.import_batches where id=p_batch_id and import_type='sales' and status='processing' for update;
  if v_company is null or auth.uid() is null or not public.can_import_commercial(v_company,'sales') then raise exception 'No autorizado.'; end if;
  update public.import_batches set status='failed',notes=left(coalesce(p_reason,'No se pudo preparar el staging.'),1000),completed_at=now(),closed_at=now(),last_activity_at=now() where id=p_batch_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_company,auth.uid(),'sales_evidence.staging_failed','import_batch',p_batch_id,jsonb_build_object('reason',left(coalesce(p_reason,''),1000)));
end $$;

revoke all on function public.begin_alpha_sales_staging(uuid,text,text,text,text) from public;
revoke all on function public.stage_alpha_sales_staging_rows(uuid,jsonb,jsonb) from public;
revoke all on function public.finish_alpha_sales_staging(uuid,jsonb) from public;
revoke all on function public.fail_alpha_sales_staging(uuid,text) from public;
grant execute on function public.begin_alpha_sales_staging(uuid,text,text,text,text) to authenticated;
grant execute on function public.stage_alpha_sales_staging_rows(uuid,jsonb,jsonb) to authenticated;
grant execute on function public.finish_alpha_sales_staging(uuid,jsonb) to authenticated;
grant execute on function public.fail_alpha_sales_staging(uuid,text) to authenticated;
