-- Allow a location-scoped cash supervisor to load the cash desk read context
-- without granting POS sales or cash-session operation capabilities.
create or replace function public.get_pos_context(p_company_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not (
    public.has_company_permission(p_company_id, 'use_pos')
    or public.has_company_permission(p_company_id, 'view_cash_reports')
  ) then
    raise exception 'No autorizado.';
  end if;

  return jsonb_build_object(
    'locations', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'code', l.external_code) order by l.name)
      from public.locations l
      where l.company_id = p_company_id
        and l.is_active
        and public.can_access_location(l.id)
    ), '[]'::jsonb),
    'registers', coalesce((
      select jsonb_agg(jsonb_build_object('id', r.id, 'location_id', r.location_id, 'name', r.display_name, 'code', r.code, 'currency_code', r.currency_code) order by r.display_name)
      from public.cash_registers r
      where r.company_id = p_company_id
        and r.is_active
        and public.can_access_location(r.location_id)
    ), '[]'::jsonb),
    'payment_methods', coalesce((
      select jsonb_agg(jsonb_build_object('id', m.id, 'code', m.code, 'name', m.display_name, 'settlement_kind', m.settlement_kind) order by m.display_name)
      from public.payment_methods m
      where m.company_id = p_company_id and m.is_active
    ), '[]'::jsonb),
    'own_open_session', (
      select jsonb_build_object('id', s.id, 'cash_register_id', s.cash_register_id, 'location_id', s.location_id, 'status', s.status, 'opening_amount', s.opening_amount)
      from public.cash_sessions s
      where s.company_id = p_company_id
        and s.opened_by = auth.uid()
        and s.status in ('open', 'pending_variance_approval')
      order by s.opened_at desc
      limit 1
    )
  );
end $$;

revoke all on function public.get_pos_context(uuid) from public, anon;
grant execute on function public.get_pos_context(uuid) to authenticated;
