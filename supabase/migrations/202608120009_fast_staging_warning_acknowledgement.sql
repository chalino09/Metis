-- Acknowledging a warning changes issue state, not staged row validity.
-- Keep the operation proportional to the number of issues instead of
-- revalidating every row in large historical evidence batches.

create or replace function public.refresh_import_staging_issue_summary(
  p_import_batch_id uuid,
  p_touch boolean default true
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_blocking integer;
  v_pending_warnings integer;
  v_summary jsonb;
begin
  select
    count(*) filter (where severity = 'error' and resolved_at is null),
    count(*) filter (where severity = 'warning' and acknowledged_at is null)
  into v_blocking, v_pending_warnings
  from public.import_staging_errors
  where import_batch_id = p_import_batch_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'error_code', summary.error_code,
    'severity', summary.severity,
    'total', summary.total_count,
    'pending', summary.pending_count
  ) order by summary.severity, summary.error_code), '[]'::jsonb)
  into v_summary
  from (
    select error_code, min(severity) as severity, count(*) as total_count,
      count(*) filter (where
        (severity = 'error' and resolved_at is null)
        or (severity = 'warning' and acknowledged_at is null)
      ) as pending_count
    from public.import_staging_errors
    where import_batch_id = p_import_batch_id
    group by error_code, severity
  ) summary;

  update public.import_batches
  set blocking_error_count = coalesce(v_blocking, 0),
      pending_warning_count = coalesce(v_pending_warnings, 0),
      error_summary = coalesce(v_summary, '[]'::jsonb),
      last_activity_at = case when p_touch then now() else last_activity_at end,
      status = case
        when status in ('staged', 'validation_failed') and coalesce(v_blocking, 0) > 0 then 'validation_failed'
        when status in ('staged', 'validation_failed') then 'staged'
        else status
      end
  where id = p_import_batch_id;
end;
$$;

create or replace function public.acknowledge_staged_warnings(
  p_import_batch_id uuid,
  p_error_code text,
  p_note text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch public.import_batches%rowtype;
  v_count integer;
begin
  if nullif(trim(p_note), '') is null then
    raise exception 'Indica una nota de reconocimiento.';
  end if;

  select * into v_batch
  from public.import_batches
  where id = p_import_batch_id
  for update;

  if not found then raise exception 'Lote no encontrado.'; end if;
  if auth.uid() is null or not public.has_company_permission(v_batch.company_id, 'import_data') then
    raise exception 'No autorizado.';
  end if;
  if v_batch.status not in ('staged', 'validation_failed') then
    raise exception 'El lote ya no admite cambios.';
  end if;

  update public.import_staging_errors
  set acknowledged_by = auth.uid(),
      acknowledged_at = now(),
      acknowledgement_note = trim(p_note)
  where import_batch_id = p_import_batch_id
    and severity = 'warning'
    and error_code = p_error_code
    and acknowledged_at is null;

  get diagnostics v_count = row_count;
  if v_count = 0 then raise exception 'No hay warnings pendientes de ese tipo.'; end if;

  perform public.refresh_import_staging_issue_summary(p_import_batch_id, true);

  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values (
    v_batch.company_id,
    auth.uid(),
    'import.warnings_acknowledged',
    'import_batch',
    p_import_batch_id,
    jsonb_build_object('error_code', p_error_code, 'count', v_count, 'note', trim(p_note))
  );

  return jsonb_build_object('status', 'acknowledged', 'count', v_count);
end;
$$;

revoke all on function public.refresh_import_staging_issue_summary(uuid, boolean) from public, anon, authenticated;
revoke all on function public.acknowledge_staged_warnings(uuid, text, text) from public, anon;
grant execute on function public.acknowledge_staged_warnings(uuid, text, text) to authenticated;
