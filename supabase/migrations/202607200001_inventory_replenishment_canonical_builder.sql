-- Satrapy · Canonical, bulk policy builder for inventory replenishment.
-- This migration only reads the catalog/current balances and writes replenishment
-- policies, their batch record and audit evidence. It never creates inventory,
-- purchasing, receipt or cost movements.

create or replace function public.search_inventory_replenishment_products(
  p_company_id uuid,
  p_location_id uuid,
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_query text := lower(trim(coalesce(p_query, '')));
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 50), 1), 100);
  v_total bigint;
  v_items jsonb;
begin
  perform public.assert_inventory_replenishment_management_access(p_company_id, p_location_id);

  select count(*) into v_total
  from public.products product
  where product.company_id = p_company_id
    and product.is_active
    and product.is_inventory_tracked
    and (
      v_query = ''
      or lower(product.name) like '%' || v_query || '%'
      or lower(coalesce(product.internal_sku, '')) like '%' || v_query || '%'
      or lower(product.alpha_sku) like '%' || v_query || '%'
      or lower(coalesce(product.barcode, '')) = v_query
      or lower(coalesce(product.product_group, '')) like '%' || v_query || '%'
    );

  select coalesce(jsonb_agg(to_jsonb(item) order by item.search_rank, item.product_name, item.product_id), '[]'::jsonb)
  into v_items
  from (
    select
      product.id as product_id,
      coalesce(product.internal_sku, product.alpha_sku) as product_code,
      product.name as product_name,
      product.unit,
      product.product_group,
      coalesce(balance.quantity_on_hand, 0) as quantity_on_hand,
      policy.minimum_quantity,
      policy.maximum_quantity,
      policy.id is not null as has_policy,
      case
        when lower(coalesce(product.internal_sku, '')) = v_query
          or lower(product.alpha_sku) = v_query
          or lower(coalesce(product.barcode, '')) = v_query then 0
        when lower(coalesce(product.internal_sku, '')) like v_query || '%'
          or lower(product.alpha_sku) like v_query || '%' then 1
        when lower(product.name) like v_query || '%' then 2
        else 3
      end as search_rank
    from public.products product
    left join public.inventory_balances balance
      on balance.company_id = p_company_id
      and balance.location_id = p_location_id
      and balance.product_id = product.id
    left join public.inventory_replenishment_policies policy
      on policy.company_id = p_company_id
      and policy.location_id = p_location_id
      and policy.product_id = product.id
    where product.company_id = p_company_id
      and product.is_active
      and product.is_inventory_tracked
      and (
        v_query = ''
        or lower(product.name) like '%' || v_query || '%'
        or lower(coalesce(product.internal_sku, '')) like '%' || v_query || '%'
        or lower(product.alpha_sku) like '%' || v_query || '%'
        or lower(coalesce(product.barcode, '')) = v_query
        or lower(coalesce(product.product_group, '')) like '%' || v_query || '%'
      )
    order by search_rank, product.name, product.id
    offset (v_page - 1) * v_size limit v_size
  ) item;

  return jsonb_build_object('total', v_total, 'page', v_page, 'page_size', v_size, 'items', v_items);
end;
$$;

create or replace function public.configure_inventory_replenishment_policy_items(
  p_company_id uuid,
  p_location_id uuid,
  p_lines jsonb,
  p_client_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request_id uuid := coalesce(p_client_request_id, gen_random_uuid());
  v_batch_id uuid;
  v_received integer;
  v_distinct integer;
  v_changes jsonb;
begin
  perform public.assert_inventory_replenishment_management_access(p_company_id, p_location_id);
  if jsonb_typeof(coalesce(p_lines, 'null'::jsonb)) <> 'array' then
    raise exception 'Las políticas deben enviarse como una lista.';
  end if;

  select id into v_batch_id
  from public.inventory_replenishment_policy_batches
  where company_id = p_company_id and client_request_id = v_request_id;
  if found then
    return jsonb_build_object(
      'batch_id', v_batch_id,
      'line_count', (select line_count from public.inventory_replenishment_policy_batches where id = v_batch_id),
      'idempotent', true
    );
  end if;

  select count(*), count(distinct input.product_id)
  into v_received, v_distinct
  from jsonb_to_recordset(p_lines) input(
    product_id uuid,
    minimum_quantity numeric,
    maximum_quantity numeric
  );
  if v_received < 1 or v_received > 500 or v_received <> v_distinct then
    raise exception 'Configura entre 1 y 500 productos distintos por lote.';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_lines) input(
      product_id uuid,
      minimum_quantity numeric,
      maximum_quantity numeric
    )
    left join public.products product
      on product.id = input.product_id
      and product.company_id = p_company_id
      and product.is_active
      and product.is_inventory_tracked
    where input.product_id is null
      or input.minimum_quantity is null
      or input.minimum_quantity <= 0
      or input.maximum_quantity is null
      or input.maximum_quantity < input.minimum_quantity
      or product.id is null
  ) then
    raise exception 'El lote contiene productos o mínimos/máximos no válidos.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'product_id', input.product_id,
    'previous_minimum_quantity', policy.minimum_quantity,
    'previous_maximum_quantity', policy.maximum_quantity,
    'minimum_quantity', input.minimum_quantity,
    'maximum_quantity', input.maximum_quantity
  ) order by input.product_id), '[]'::jsonb)
  into v_changes
  from jsonb_to_recordset(p_lines) input(
    product_id uuid,
    minimum_quantity numeric,
    maximum_quantity numeric
  )
  left join public.inventory_replenishment_policies policy
    on policy.company_id = p_company_id
    and policy.location_id = p_location_id
    and policy.product_id = input.product_id;

  insert into public.inventory_replenishment_policy_batches(
    company_id, location_id, client_request_id, line_count, configured_by
  ) values (
    p_company_id, p_location_id, v_request_id, v_received, auth.uid()
  ) returning id into v_batch_id;

  insert into public.inventory_replenishment_policies(
    company_id, location_id, product_id, minimum_quantity, maximum_quantity, created_by, updated_by
  )
  select p_company_id, p_location_id, input.product_id,
    input.minimum_quantity, input.maximum_quantity, auth.uid(), auth.uid()
  from jsonb_to_recordset(p_lines) input(
    product_id uuid,
    minimum_quantity numeric,
    maximum_quantity numeric
  )
  on conflict (location_id, product_id) do update
    set minimum_quantity = excluded.minimum_quantity,
        maximum_quantity = excluded.maximum_quantity,
        updated_by = auth.uid(),
        updated_at = now();

  perform public.write_sales_audit(
    p_company_id,
    'inventory_replenishment.policies_configured',
    'inventory_replenishment_policy_batch',
    v_batch_id,
    jsonb_build_object(
      'location_id', p_location_id,
      'line_count', v_received,
      'client_request_id', v_request_id,
      'changes', v_changes
    )
  );

  return jsonb_build_object('batch_id', v_batch_id, 'line_count', v_received, 'idempotent', false);
exception when unique_violation then
  select id into v_batch_id
  from public.inventory_replenishment_policy_batches
  where company_id = p_company_id and client_request_id = v_request_id;
  if v_batch_id is not null then
    return jsonb_build_object(
      'batch_id', v_batch_id,
      'line_count', (select line_count from public.inventory_replenishment_policy_batches where id = v_batch_id),
      'idempotent', true
    );
  end if;
  raise;
end;
$$;

revoke all on function public.search_inventory_replenishment_products(uuid,uuid,text,integer,integer) from public, anon;
revoke all on function public.configure_inventory_replenishment_policy_items(uuid,uuid,jsonb,uuid) from public, anon;
grant execute on function public.search_inventory_replenishment_products(uuid,uuid,text,integer,integer) to authenticated;
grant execute on function public.configure_inventory_replenishment_policy_items(uuid,uuid,jsonb,uuid) to authenticated;
