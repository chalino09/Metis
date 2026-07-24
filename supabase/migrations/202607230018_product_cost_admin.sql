-- Fase 2 · costo vigente puntual para desbloquear operaciones valuadas.
-- Reutiliza product_costs y la matriz contable aprobada; las cargas masivas
-- continúan entrando por la importación de costos.

update public.permissions
set description = 'Consultar y administrar costos de producto, incluida la importación masiva.'
where code = 'import_costs';

create or replace function public.get_product_cost_admin_context(
  p_company_id uuid,
  p_product_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_product public.products%rowtype;
  v_rule_set public.accounting_event_rule_sets%rowtype;
  v_currency text;
  v_cost public.product_costs%rowtype;
begin
  if auth.uid() is null
    or not public.has_company_permission(p_company_id, 'view_costs')
  then
    raise exception 'No autorizado para consultar costos.';
  end if;

  select *
  into v_product
  from public.products
  where id = p_product_id
    and company_id = p_company_id;

  if not found then
    raise exception 'Producto no disponible.';
  end if;

  select *
  into v_rule_set
  from public.accounting_event_rule_sets
  where company_id = p_company_id
    and status = 'approved';

  if found then
    select base_currency
    into v_currency
    from public.accounting_config_versions
    where id = v_rule_set.accounting_config_version_id;

    select *
    into v_cost
    from public.product_costs
    where company_id = p_company_id
      and product_id = p_product_id
      and cost_type = v_rule_set.cost_method
      and currency_code = v_currency
      and valid_from <= now()
      and (valid_to is null or valid_to > now())
    order by valid_from desc
    limit 1;
  end if;

  return jsonb_build_object(
    'product', jsonb_build_object('id', v_product.id, 'name', v_product.name),
    'cost_method', v_rule_set.cost_method,
    'currency_code', v_currency,
    'matrix_ready', v_rule_set.id is not null,
    'current_cost', case
      when v_cost.id is null then null
      else jsonb_build_object(
        'id', v_cost.id,
        'amount', v_cost.amount,
        'valid_from', v_cost.valid_from
      )
    end
  );
end $$;

create or replace function public.set_product_current_cost(
  p_company_id uuid,
  p_product_id uuid,
  p_amount numeric,
  p_reason text,
  p_expected_cost_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_product public.products%rowtype;
  v_rule_set public.accounting_event_rule_sets%rowtype;
  v_currency text;
  v_current public.product_costs%rowtype;
  v_created public.product_costs%rowtype;
  v_effective timestamptz := clock_timestamp();
begin
  if auth.uid() is null
    or not public.has_company_permission(p_company_id, 'import_costs')
  then
    raise exception 'No autorizado para administrar costos.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'El costo vigente debe ser mayor que cero.';
  end if;

  if nullif(trim(coalesce(p_reason, '')), '') is null then
    raise exception 'El motivo del cambio es obligatorio.';
  end if;

  select *
  into v_product
  from public.products
  where id = p_product_id
    and company_id = p_company_id;

  if not found then
    raise exception 'Producto no disponible.';
  end if;

  select *
  into v_rule_set
  from public.accounting_event_rule_sets
  where company_id = p_company_id
    and status = 'approved';

  if not found then
    raise exception 'Primero aprueba la matriz contable para definir el método de costo.';
  end if;

  select base_currency
  into v_currency
  from public.accounting_config_versions
  where id = v_rule_set.accounting_config_version_id
    and status = 'approved';

  if v_currency is null then
    raise exception 'La configuración contable aprobada no está disponible.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text || ':' || p_product_id::text, 0));

  if exists (
    select 1
    from public.product_costs
    where company_id = p_company_id
      and product_id = p_product_id
      and cost_type = v_rule_set.cost_method
      and currency_code = v_currency
      and valid_from > v_effective
  ) then
    raise exception 'Existe un costo futuro programado; revísalo antes de capturar otro.';
  end if;

  select *
  into v_current
  from public.product_costs
  where company_id = p_company_id
    and product_id = p_product_id
    and cost_type = v_rule_set.cost_method
    and currency_code = v_currency
    and valid_from <= v_effective
    and (valid_to is null or valid_to > v_effective)
  order by valid_from desc
  limit 1
  for update;

  if v_current.id is distinct from p_expected_cost_id then
    raise exception 'El costo cambió mientras editabas. Actualiza el producto e intenta nuevamente.';
  end if;

  if v_current.id is not null and v_current.amount = p_amount then
    return public.get_product_cost_admin_context(p_company_id, p_product_id)
      || jsonb_build_object('idempotent', true);
  end if;

  if v_current.id is not null then
    v_effective := greatest(v_effective, v_current.valid_from + interval '1 microsecond');
    update public.product_costs
    set valid_to = v_effective
    where id = v_current.id;
  end if;

  insert into public.product_costs(
    company_id,
    product_id,
    cost_type,
    amount,
    currency_code,
    valid_from,
    source_file_name,
    created_by
  )
  values(
    p_company_id,
    p_product_id,
    v_rule_set.cost_method,
    p_amount,
    v_currency,
    v_effective,
    'manual:product_catalog',
    auth.uid()
  )
  returning * into v_created;

  perform public.write_sales_audit(
    p_company_id,
    'product.cost_set',
    'product_costs',
    v_created.id,
    jsonb_build_object(
      'product_id', p_product_id,
      'cost_method', v_rule_set.cost_method,
      'currency_code', v_currency,
      'previous_amount', v_current.amount,
      'amount', v_created.amount,
      'reason', trim(p_reason)
    )
  );

  return public.get_product_cost_admin_context(p_company_id, p_product_id)
    || jsonb_build_object('idempotent', false);
end $$;

revoke all on function public.get_product_cost_admin_context(uuid, uuid) from public;
revoke all on function public.set_product_current_cost(uuid, uuid, numeric, text, uuid) from public;
grant execute on function public.get_product_cost_admin_context(uuid, uuid) to authenticated;
grant execute on function public.set_product_current_cost(uuid, uuid, numeric, text, uuid) to authenticated;
