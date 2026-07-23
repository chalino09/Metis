-- M4D1 remediation: remove premature enterprise-close objects without
-- rewriting migration history or discarding evidence.

do $m4d1_remediation$
declare
  v_runs_exists boolean := to_regclass('public.accounting_close_runs') is not null;
  v_checks_exists boolean := to_regclass('public.accounting_close_checks') is not null;
  v_has_non_preview boolean := false;
begin
  if v_runs_exists <> v_checks_exists then
    raise exception
      'M4D1 remediation stopped: the premature close schema is incomplete.';
  end if;

  if v_runs_exists then
    execute 'lock table public.accounting_close_runs in access exclusive mode';
    execute 'lock table public.accounting_close_checks in access exclusive mode';

    execute $sql$
      select exists (
        select 1
        from public.accounting_close_runs
        where status is distinct from 'preview'
      )
    $sql$ into v_has_non_preview;

    if v_has_non_preview then
      raise exception
        'M4D1 remediation stopped: a close run is no longer a disposable preview.';
    end if;

    execute $sql$
      insert into public.audit_log (
        company_id,
        actor_id,
        action,
        entity_type,
        entity_id,
        metadata
      )
      select
        run.company_id,
        null,
        'accounting.premature_close_preview_archived',
        'accounting_close_run',
        run.id,
        jsonb_build_object(
          'reason', 'M4D1 scope remediation before enterprise close',
          'source_migration', '202607230001_m4d1_remove_premature_close',
          'run', to_jsonb(run),
          'checks', coalesce(
            (
              select jsonb_agg(to_jsonb(check_row) order by check_row.created_at, check_row.id)
              from public.accounting_close_checks check_row
              where check_row.close_run_id = run.id
            ),
            '[]'::jsonb
          )
        )
      from public.accounting_close_runs run
    $sql$;
  end if;
end
$m4d1_remediation$;

drop function if exists public.prepare_accounting_close(uuid, uuid);
drop function if exists public.approve_accounting_close(uuid, text);
drop function if exists public.canonical_accounting_close_auxiliaries(uuid, date);

drop table if exists public.accounting_close_checks;
drop table if exists public.accounting_close_runs;

notify pgrst, 'reload schema';
