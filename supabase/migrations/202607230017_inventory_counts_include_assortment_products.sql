-- Los conteos completos por sucursal incluyen tanto los saldos existentes
-- como los productos controlados por inventario que se ofrecen en sus
-- surtidos activos. Una partida esperada en cero no crea existencia: el saldo
-- sólo cambia después de capturar, revisar y aprobar el conteo.

begin;

create or replace function public.open_inventory_count(
  p_company_id uuid,
  p_location_id uuid,
  p_client_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request_id uuid := coalesce(p_client_request_id, gen_random_uuid());
  v_count_id uuid;
  v_lines integer;
  v_zero_expected_lines integer;
begin
  perform public.assert_inventory_count_access(p_company_id, p_location_id, 'operate_inventory');

  select id into v_count_id
  from public.inventory_counts
  where company_id = p_company_id and open_request_id = v_request_id;
  if found then
    return jsonb_build_object(
      'inventory_count_id', v_count_id,
      'status', (select status from public.inventory_counts where id = v_count_id),
      'idempotent', true
    );
  end if;

  if exists (
    select 1
    from public.inventory_counts
    where location_id = p_location_id
      and status in ('open', 'pending_approval')
  ) then
    raise exception 'La ubicación ya tiene un conteo activo.';
  end if;

  insert into public.inventory_counts(company_id, location_id, open_request_id, opened_by)
  values (p_company_id, p_location_id, v_request_id, auth.uid())
  returning id into v_count_id;

  with eligible_products as (
    select balance.product_id
    from public.inventory_balances balance
    where balance.company_id = p_company_id
      and balance.location_id = p_location_id

    union

    select item.product_id
    from public.location_sales_assortments assignment
    join public.sales_assortments assortment
      on assortment.id = assignment.assortment_id
     and assortment.company_id = p_company_id
     and assortment.status = 'active'
    join public.sales_assortment_items item
      on item.assortment_id = assortment.id
    join public.products product
      on product.id = item.product_id
     and product.company_id = p_company_id
     and product.is_active
     and product.is_inventory_tracked
    where assignment.location_id = p_location_id
      and assignment.valid_from <= now()
      and (assignment.valid_to is null or assignment.valid_to > now())
  )
  insert into public.inventory_count_lines(
    inventory_count_id,
    product_id,
    expected_quantity,
    expected_balance_updated_at
  )
  select
    v_count_id,
    eligible.product_id,
    coalesce(balance.quantity_on_hand, 0),
    balance.updated_at
  from eligible_products eligible
  left join public.inventory_balances balance
    on balance.company_id = p_company_id
   and balance.location_id = p_location_id
   and balance.product_id = eligible.product_id
  order by eligible.product_id;
  get diagnostics v_lines = row_count;

  select count(*)
  into v_zero_expected_lines
  from public.inventory_count_lines line
  where line.inventory_count_id = v_count_id
    and line.expected_balance_updated_at is null;

  update public.inventory_counts
  set line_count = v_lines
  where id = v_count_id;

  perform public.write_sales_audit(
    p_company_id,
    'inventory_count.opened',
    'inventory_counts',
    v_count_id,
    jsonb_build_object(
      'location_id', p_location_id,
      'line_count', v_lines,
      'zero_expected_line_count', v_zero_expected_lines,
      'client_request_id', v_request_id
    )
  );

  return jsonb_build_object(
    'inventory_count_id', v_count_id,
    'status', 'open',
    'line_count', v_lines,
    'zero_expected_line_count', v_zero_expected_lines,
    'idempotent', false
  );
exception
  when unique_violation then
    select id into v_count_id
    from public.inventory_counts
    where company_id = p_company_id
      and open_request_id = v_request_id;
    if v_count_id is not null then
      return jsonb_build_object(
        'inventory_count_id', v_count_id,
        'status', (select status from public.inventory_counts where id = v_count_id),
        'idempotent', true
      );
    end if;
    raise;
end;
$$;

revoke all on function public.open_inventory_count(uuid, uuid, uuid) from public, anon;
grant execute on function public.open_inventory_count(uuid, uuid, uuid) to authenticated;

commit;
