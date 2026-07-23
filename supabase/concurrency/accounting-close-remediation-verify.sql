do $verify$
begin
  if to_regclass('public.accounting_close_runs') is not null
     or to_regclass('public.accounting_close_checks') is not null then
    raise exception 'Premature close tables remain after remediation.';
  end if;

  if to_regprocedure('public.prepare_accounting_close(uuid,uuid)') is not null
     or to_regprocedure('public.approve_accounting_close(uuid,text)') is not null
     or to_regprocedure('public.canonical_accounting_close_auxiliaries(uuid,date)') is not null then
    raise exception 'Premature close functions remain after remediation.';
  end if;

  if (
    select count(*)
    from public.audit_log
    where action = 'accounting.premature_close_preview_archived'
      and metadata -> 'run' ->> 'status' = 'preview'
      and jsonb_array_length(metadata -> 'checks') = 1
  ) <> 1 then
    raise exception 'The preview and its checks were not archived exactly once.';
  end if;
end
$verify$;

rollback;
