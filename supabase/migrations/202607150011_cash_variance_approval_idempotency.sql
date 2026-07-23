-- Satrapy · Module 2 UAT remediation: idempotent cash variance approval and
-- a branch-scoped supervisor role. Existing cash sessions remain unchanged.

alter table public.roles drop constraint if exists roles_code_check;
alter table public.roles add constraint roles_code_check check (code in (
  'super_admin', 'direccion_admin', 'supervisor_sucursal', 'sucursal',
  'ingeniero_campo', 'almacen', 'punto_venta'
));

insert into public.roles(code, display_name, description)
values (
  'supervisor_sucursal',
  'Supervisor de Sucursal',
  'Aprueba diferencias de caja únicamente en ubicaciones asignadas.'
)
on conflict(code) do update
set display_name = excluded.display_name,
    description = excluded.description;

insert into public.role_permissions(role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p on p.code in (
  'approve_cash_variance',
  'view_cash_reports'
)
where r.code = 'supervisor_sucursal'
on conflict do nothing;

alter table public.cash_sessions
  add column if not exists variance_approval_request_id uuid;

create unique index if not exists cash_sessions_variance_approval_request_uidx
  on public.cash_sessions(variance_approval_request_id)
  where variance_approval_request_id is not null;

drop function if exists public.approve_cash_variance(uuid, text);

create or replace function public.approve_cash_variance(
  p_cash_session_id uuid,
  p_approval_reason text default null,
  p_client_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.cash_sessions%rowtype;
  v_request_id uuid := coalesce(p_client_request_id, gen_random_uuid());
begin
  select *
  into v_session
  from public.cash_sessions
  where id = p_cash_session_id
  for update;

  if not found then
    raise exception 'No hay una diferencia de caja pendiente.';
  end if;

  if auth.uid() is null
    or auth.uid() = v_session.close_requested_by
    or auth.uid() = v_session.opened_by
    or not public.has_company_permission(v_session.company_id, 'approve_cash_variance') then
    raise exception 'Se requiere un aprobador autorizado distinto al responsable del cierre.';
  end if;

  perform public.assert_pos_access(
    v_session.company_id,
    v_session.location_id,
    'approve_cash_variance'
  );

  if v_session.status = 'closed'
    and v_session.variance_approval_request_id = v_request_id
    and v_session.variance_approved_by = auth.uid() then
    return jsonb_build_object(
      'cash_session_id', v_session.id,
      'status', 'closed',
      'variance_amount', v_session.variance_amount,
      'idempotent', true
    );
  end if;

  if v_session.status <> 'pending_variance_approval' then
    raise exception 'No hay una diferencia de caja pendiente.';
  end if;

  if exists (
    select 1
    from public.cash_sessions existing
    where existing.variance_approval_request_id = v_request_id
      and existing.id <> v_session.id
  ) then
    raise exception 'La clave de idempotencia ya pertenece a otra aprobación de caja.';
  end if;

  update public.cash_sessions
  set status = 'closed',
      closed_at = now(),
      variance_approved_by = auth.uid(),
      variance_approved_at = now(),
      variance_approval_request_id = v_request_id,
      variance_reason = coalesce(variance_reason, nullif(trim(p_approval_reason), ''))
  where id = v_session.id;

  perform public.write_sales_audit(
    v_session.company_id,
    'cash_session.variance_approved',
    'cash_sessions',
    v_session.id,
    jsonb_build_object(
      'variance_amount', v_session.variance_amount,
      'client_request_id', v_request_id
    )
  );

  return jsonb_build_object(
    'cash_session_id', v_session.id,
    'status', 'closed',
    'variance_amount', v_session.variance_amount,
    'idempotent', false
  );
end;
$$;

revoke all on function public.approve_cash_variance(uuid, text, uuid) from public, anon;
grant execute on function public.approve_cash_variance(uuid, text, uuid) to authenticated;

