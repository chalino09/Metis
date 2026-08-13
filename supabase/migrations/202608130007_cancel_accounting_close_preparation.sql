-- Permite abandonar una preparación de cierre sin borrar su evidencia auditada.

alter table public.accounting_close_runs
  drop constraint if exists accounting_close_runs_status_check;

alter table public.accounting_close_runs
  add column if not exists cancellation_reason text,
  add column if not exists cancellation_request_id uuid unique,
  add column if not exists cancelled_by uuid references auth.users(id) on delete restrict,
  add column if not exists cancelled_at timestamptz,
  add constraint accounting_close_runs_status_check
    check(status in ('prepared','approved','closed','reopened','cancelled')),
  add constraint accounting_close_runs_cancelled_check
    check((status='cancelled')=(cancelled_at is not null));

create or replace function public.cancel_accounting_close_preparation(
  p_close_run_id uuid,
  p_reason text,
  p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_run public.accounting_close_runs%rowtype;
begin
  select * into v_run from public.accounting_close_runs where id=p_close_run_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_run.company_id,'prepare_accounting_close') then
    raise exception 'Preparación de cierre no disponible.';
  end if;
  if v_run.cancellation_request_id=p_client_request_id then
    return to_jsonb(v_run)||jsonb_build_object('idempotent',true);
  end if;
  if v_run.status<>'prepared' or nullif(trim(coalesce(p_reason,'')),'') is null or p_client_request_id is null then
    raise exception 'Solo puedes cancelar una preparación pendiente e indicar el motivo.';
  end if;
  update public.accounting_close_runs
  set status='cancelled',cancellation_reason=trim(p_reason),cancellation_request_id=p_client_request_id,
      cancelled_by=auth.uid(),cancelled_at=now()
  where id=v_run.id returning * into v_run;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_run.company_id,auth.uid(),'accounting.close_preparation_cancelled','accounting_close_run',v_run.id,
    jsonb_build_object('reason',trim(p_reason),'period_id',v_run.period_id,'snapshot_sha256',v_run.snapshot_sha256));
  return to_jsonb(v_run)||jsonb_build_object('idempotent',false);
end $$;

revoke all on function public.cancel_accounting_close_preparation(uuid,text,uuid) from public,anon;
grant execute on function public.cancel_accounting_close_preparation(uuid,text,uuid) to authenticated;
