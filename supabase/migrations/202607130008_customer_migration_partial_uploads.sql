-- Allow each Clientes/CxC workbook to enter persistent staging independently.
-- Reconciliation still requires the complete, matching source set.

alter function public.stage_alpha_customer_migration_rows(uuid,text,jsonb)
  set search_path = public, extensions;

alter function public.promote_alpha_customer_migration(uuid)
  set search_path = public, extensions;

create or replace function public.begin_alpha_customer_migration(
  p_company_id uuid, p_cutoff_date date, p_content_sha256 text, p_files jsonb
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_batch_id uuid;
  v_existing_status text;
  v_previous_summary jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'import_data') then
    raise exception 'No autorizado para preparar migraciones de clientes.';
  end if;
  if p_cutoff_date is null or nullif(trim(coalesce(p_content_sha256, '')), '') is null then
    raise exception 'La fecha de corte y la huella de contenido son obligatorias.';
  end if;
  if jsonb_array_length(coalesce(p_files, '[]'::jsonb)) = 0 then
    raise exception 'La carga no contiene archivos de Clientes/CxC.';
  end if;
  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_files, '[]'::jsonb)) f(report_type text, snapshot_date date)
    where f.snapshot_date is distinct from p_cutoff_date
  ) then
    raise exception 'Los archivos seleccionados no comparten la misma fecha de corte.';
  end if;

  select id, status, summary into v_batch_id, v_existing_status, v_previous_summary
  from public.alpha_customer_migration_batches
  where company_id = p_company_id and content_sha256 = p_content_sha256
  limit 1 for update;

  if v_batch_id is not null and v_existing_status <> 'failed' then
    return jsonb_build_object('status','duplicate','batch_id',v_batch_id);
  end if;

  if v_batch_id is null then
    insert into public.alpha_customer_migration_batches(company_id, cutoff_date, content_sha256, imported_by)
    values(p_company_id,p_cutoff_date,p_content_sha256,auth.uid())
    returning id into v_batch_id;
  else
    delete from public.alpha_customer_migration_differences where batch_id=v_batch_id;
    delete from public.alpha_customer_migration_documents where batch_id=v_batch_id;
    delete from public.alpha_customer_migration_collections where batch_id=v_batch_id;
    delete from public.alpha_customer_migration_customers where batch_id=v_batch_id;
    delete from public.alpha_customer_migration_files where batch_id=v_batch_id;
    update public.alpha_customer_migration_batches
      set cutoff_date=p_cutoff_date, status='loading', records_received=0, records_promoted=0,
          completed_at=null, summary=jsonb_build_object('previous_failure',coalesce(v_previous_summary,'{}'::jsonb))
      where id=v_batch_id;
    perform public.write_sales_audit(p_company_id,'alpha_customer_migration.retry_started','alpha_customer_migration_batches',v_batch_id,jsonb_build_object('previous_summary',coalesce(v_previous_summary,'{}'::jsonb)));
  end if;

  insert into public.alpha_customer_migration_files(batch_id, report_type, original_name, file_sha256, logical_sha256, snapshot_date, duplicate_group, row_count)
  select v_batch_id, f.report_type, f.original_name, f.file_sha256, nullif(f.logical_sha256,''), f.snapshot_date, nullif(f.duplicate_group,''), coalesce(f.row_count,0)
  from jsonb_to_recordset(coalesce(p_files,'[]'::jsonb)) f(report_type text, original_name text, file_sha256 text, logical_sha256 text, snapshot_date date, duplicate_group text, row_count integer);
  return jsonb_build_object('status',case when v_existing_status='failed' then 'retry' else 'loading' end,'batch_id',v_batch_id);
end $$;

create or replace function public.finish_alpha_customer_migration_staging(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_batch public.alpha_customer_migration_batches%rowtype;
  v_files integer;
begin
  select * into v_batch from public.alpha_customer_migration_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_data') then
    raise exception 'No autorizado para completar el staging de clientes.';
  end if;
  if v_batch.status <> 'loading' then raise exception 'El lote ya no está cargando.'; end if;
  select count(*) into v_files from public.alpha_customer_migration_files where batch_id=p_batch_id;
  update public.alpha_customer_migration_batches
    set status='staged', summary=summary || jsonb_build_object('files_staged',v_files,'partial',true)
    where id=p_batch_id;
  perform public.write_sales_audit(v_batch.company_id,'alpha_customer_migration.partial_staged','alpha_customer_migration_batches',p_batch_id,jsonb_build_object('files_staged',v_files,'records_received',v_batch.records_received));
  return jsonb_build_object('batch_id',p_batch_id,'status','staged','files_staged',v_files,'records_received',v_batch.records_received);
end $$;

revoke all on function public.finish_alpha_customer_migration_staging(uuid) from public;
grant execute on function public.finish_alpha_customer_migration_staging(uuid) to authenticated;
