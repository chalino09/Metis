-- Inicio compartido de ventas: códigos internos automáticos y carga transaccional
-- de las denominaciones MXN usadas por caja.

create or replace function public.configure_standard_cash_denominations(
  p_company_id uuid,
  p_currency_code text default 'MXN'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_currency text := upper(trim(coalesce(p_currency_code, '')));
  v_added integer := 0;
  v_reactivated integer := 0;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_payment_methods') then
    raise exception 'No autorizado para configurar denominaciones.';
  end if;
  if v_currency <> 'MXN' then
    raise exception 'La carga inicial disponible corresponde a MXN.';
  end if;

  with standard(value, display_name) as (
    values
      (0.50::numeric, '$0.50'),
      (1.00::numeric, '$1'),
      (2.00::numeric, '$2'),
      (5.00::numeric, '$5'),
      (10.00::numeric, '$10'),
      (20.00::numeric, '$20'),
      (50.00::numeric, '$50'),
      (100.00::numeric, '$100'),
      (200.00::numeric, '$200'),
      (500.00::numeric, '$500'),
      (1000.00::numeric, '$1,000')
  )
  select
    count(*) filter (where denomination.id is null),
    count(*) filter (where denomination.id is not null and not denomination.is_active)
  into v_added, v_reactivated
  from standard
  left join public.cash_denominations denomination
    on denomination.company_id = p_company_id
   and denomination.currency_code = v_currency
   and denomination.value = standard.value;

  insert into public.cash_denominations(company_id, currency_code, value, display_name, is_active)
  select p_company_id, v_currency, standard.value, standard.display_name, true
  from (values
    (0.50::numeric, '$0.50'), (1.00::numeric, '$1'), (2.00::numeric, '$2'),
    (5.00::numeric, '$5'), (10.00::numeric, '$10'), (20.00::numeric, '$20'),
    (50.00::numeric, '$50'), (100.00::numeric, '$100'), (200.00::numeric, '$200'),
    (500.00::numeric, '$500'), (1000.00::numeric, '$1,000')
  ) standard(value, display_name)
  on conflict (company_id, currency_code, value) do update
    set is_active = true, updated_at = now()
    where not cash_denominations.is_active;

  perform public.write_sales_audit(
    p_company_id,
    'cash_denominations.standard_configured',
    'cash_denominations',
    null,
    jsonb_build_object(
      'currency_code', v_currency,
      'added', v_added,
      'reactivated', v_reactivated,
      'values', jsonb_build_array(0.50,1,2,5,10,20,50,100,200,500,1000)
    )
  );

  return jsonb_build_object(
    'currency_code', v_currency,
    'added', v_added,
    'reactivated', v_reactivated,
    'total', 11
  );
end;
$$;

create or replace function public.prepare_pos_operation(
  p_company_id uuid,
  p_code text,
  p_name text,
  p_location_ids uuid[],
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
  v_result jsonb;
  v_assortment_id uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_assortments') then
    raise exception 'No autorizado para configurar productos por sucursal.';
  end if;

  v_code := coalesce(
    nullif(upper(trim(coalesce(p_code, ''))), ''),
    public.next_company_internal_code(p_company_id, 'SURTIDO', 'public.sales_assortments'::regclass, 'code')
  );

  v_result := public.prepare_pos_pilot(p_company_id, v_code, p_name, p_location_ids, p_at);
  v_assortment_id := (v_result ->> 'assortment_id')::uuid;

  update public.sales_assortments
  set status = 'active', valid_from = coalesce(valid_from, p_at), updated_at = now()
  where id = v_assortment_id and company_id = p_company_id;

  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values (
    p_company_id,
    auth.uid(),
    'sales_assortment.activated_on_create',
    'sales_assortments',
    v_assortment_id,
    jsonb_build_object('code', v_code, 'location_ids', to_jsonb(p_location_ids))
  );

  return v_result || jsonb_build_object('code', v_code, 'status', 'active');
end;
$$;

revoke all on function public.configure_standard_cash_denominations(uuid, text) from public, anon;
grant execute on function public.configure_standard_cash_denominations(uuid, text) to authenticated;

revoke all on function public.prepare_pos_operation(uuid, text, text, uuid[], timestamptz) from public, anon;
grant execute on function public.prepare_pos_operation(uuid, text, text, uuid[], timestamptz) to authenticated;
