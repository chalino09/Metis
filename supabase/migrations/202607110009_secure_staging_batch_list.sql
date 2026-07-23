-- The migration centre must be able to recover its own pending batches even
-- when an import is validation_failed.  Keep this access behind the existing
-- import permission rather than opening import_batches to operational roles.

create or replace function public.list_import_staging_batches(p_company_id uuid)
returns table (
  id uuid,
  import_type text,
  status text,
  source text,
  file_sha256 text,
  snapshot_date date,
  records_received integer,
  valid_rows integer,
  warning_rows integer,
  error_rows integer,
  blocking_error_count integer,
  pending_warning_count integer,
  staging_purged_at timestamptz,
  original_name text,
  file_type text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'import_data') then
    raise exception 'No autorizado para consultar staging.';
  end if;

  return query
  select
    batch.id,
    batch.import_type,
    batch.status,
    batch.source,
    batch.file_sha256,
    batch.snapshot_date,
    batch.records_received,
    batch.valid_rows,
    batch.warning_rows,
    batch.error_rows,
    batch.blocking_error_count,
    batch.pending_warning_count,
    batch.staging_purged_at,
    file_data.original_name,
    file_data.file_type
  from public.import_batches batch
  left join lateral (
    select file_row.original_name, file_row.file_type
    from public.import_files file_row
    where file_row.import_batch_id = batch.id
    order by file_row.created_at asc
    limit 1
  ) file_data on true
  where batch.company_id = p_company_id
    and batch.status in ('staged', 'validation_failed', 'failed')
  order by batch.started_at desc
  limit 20;
end;
$$;

revoke all on function public.list_import_staging_batches(uuid) from public;
grant execute on function public.list_import_staging_batches(uuid) to authenticated;
