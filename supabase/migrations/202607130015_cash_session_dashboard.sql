create or replace function public.get_cash_session_dashboard(p_cash_session_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_session public.cash_sessions%rowtype;
begin
  select * into v_session from public.cash_sessions where id = p_cash_session_id;
  if not found then raise exception 'Sesión de caja no encontrada.'; end if;
  if not public.can_access_location(v_session.location_id)
    or (v_session.opened_by <> auth.uid() and not public.has_company_permission(v_session.company_id, 'view_cash_reports'))
  then raise exception 'No autorizado para consultar la sesión de caja.'; end if;

  return (
    select jsonb_build_object(
      'cash_session_id', v_session.id,
      'status', v_session.status,
      'opened_at', v_session.opened_at,
      'register_name', r.display_name,
      'register_code', r.code,
      'location_name', l.name,
      'location_code', l.external_code,
      'currency_code', r.currency_code,
      'cashier_name', coalesce(p.full_name, 'Usuario'),
      'opening_amount', v_session.opening_amount,
      'expected_cash', coalesce((select round(sum(m.amount), 2) from public.cash_movements m where m.cash_session_id = v_session.id), 0),
      'cash_sales', coalesce((select round(sum(m.amount), 2) from public.cash_movements m where m.cash_session_id = v_session.id and m.movement_type = 'cash_sale'), 0),
      'receivable_payments', coalesce((select round(sum(m.amount), 2) from public.cash_movements m where m.cash_session_id = v_session.id and m.movement_type = 'receivable_payment'), 0),
      'paid_in', coalesce((select round(sum(m.amount), 2) from public.cash_movements m where m.cash_session_id = v_session.id and m.movement_type = 'paid_in'), 0),
      'paid_out', abs(coalesce((select round(sum(m.amount), 2) from public.cash_movements m where m.cash_session_id = v_session.id and m.movement_type = 'paid_out'), 0))
    )
    from public.cash_registers r
    join public.locations l on l.id = v_session.location_id
    left join public.profiles p on p.id = v_session.opened_by
    where r.id = v_session.cash_register_id
  );
end $$;

create or replace function public.list_cash_session_movements_page(
  p_cash_session_id uuid,
  p_page integer default 1,
  p_page_size integer default 50
)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_session public.cash_sessions%rowtype;
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := least(greatest(coalesce(p_page_size, 50), 1), 100);
  v_total bigint;
begin
  select * into v_session from public.cash_sessions where id = p_cash_session_id;
  if not found then raise exception 'Sesión de caja no encontrada.'; end if;
  if not public.can_access_location(v_session.location_id)
    or (v_session.opened_by <> auth.uid() and not public.has_company_permission(v_session.company_id, 'view_cash_reports'))
  then raise exception 'No autorizado para consultar movimientos de caja.'; end if;

  select count(*) into v_total from public.cash_movements where cash_session_id = p_cash_session_id;
  return jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', page.id,
        'movement_type', page.movement_type,
        'amount', page.amount,
        'reason', page.reason,
        'occurred_at', page.occurred_at
      ) order by page.occurred_at desc)
      from (
        select m.id, m.movement_type, m.amount, m.reason, m.occurred_at
        from public.cash_movements m
        where m.cash_session_id = p_cash_session_id
        order by m.occurred_at desc
        limit v_page_size offset ((v_page - 1) * v_page_size)
      ) page
    ), '[]'::jsonb),
    'total', v_total,
    'page', v_page,
    'page_size', v_page_size
  );
end $$;

grant execute on function public.get_cash_session_dashboard(uuid) to authenticated;
grant execute on function public.list_cash_session_movements_page(uuid, integer, integer) to authenticated;
