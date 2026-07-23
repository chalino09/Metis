-- Scale-safe staging history. Operational entity searches already expose
-- pagination; staging was the remaining silent top-20 list.

create or replace function public.list_import_staging_batches_page(
  p_company_id uuid,
  p_page integer default 1,
  p_page_size integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 20), 1), 100);
  v_total bigint;
  v_items jsonb;
begin
  if auth.uid() is null or not (
    public.has_company_permission(p_company_id, 'import_data')
    or public.has_company_permission(p_company_id, 'import_prices')
    or public.has_company_permission(p_company_id, 'import_costs')
  ) then
    raise exception 'No autorizado para consultar staging.';
  end if;

  select count(*)
  into v_total
  from public.import_batches batch
  where batch.company_id = p_company_id
    and batch.status in ('staged', 'validation_failed', 'failed');

  select coalesce(jsonb_agg(to_jsonb(item) order by item.started_at desc, item.id desc), '[]'::jsonb)
  into v_items
  from (
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
      batch.started_at,
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
    order by batch.started_at desc, batch.id desc
    limit v_size offset (v_page - 1) * v_size
  ) item;

  return jsonb_build_object(
    'items', v_items,
    'pagination', jsonb_build_object(
      'page', v_page,
      'page_size', v_size,
      'total', v_total
    )
  );
end;
$$;

revoke all on function public.list_import_staging_batches_page(uuid, integer, integer) from public;
grant execute on function public.list_import_staging_batches_page(uuid, integer, integer) to authenticated;
