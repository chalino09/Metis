-- Satrapy · Flujo canónico de comercialización por surtido.
-- Alpha permanece exclusivamente en la frontera de importación. Estas
-- operaciones trabajan con los UUID canónicos de productos, surtidos y
-- sucursales, y no modifican existencias.

begin;

create or replace function public.get_sales_assortment_admin_context(
  p_company_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_assortments jsonb;
  v_locations jsonb;
  v_catalog_total integer;
  v_outside_total integer;
begin
  if auth.uid() is null
    or not public.has_company_permission(p_company_id, 'manage_assortments') then
    raise exception 'No autorizado para configurar surtidos.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', assortment.id,
    'code', assortment.code,
    'name', assortment.name,
    'status', assortment.status,
    'location_ids', coalesce((
      select jsonb_agg(assignment.location_id order by location.name)
      from public.location_sales_assortments assignment
      join public.locations location on location.id = assignment.location_id
      where assignment.assortment_id = assortment.id
        and assignment.valid_from <= now()
        and (assignment.valid_to is null or assignment.valid_to > now())
    ), '[]'::jsonb)
  ) order by assortment.name), '[]'::jsonb)
  into v_assortments
  from public.sales_assortments assortment
  where assortment.company_id = p_company_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', location.id,
    'external_code', location.external_code,
    'name', location.name
  ) order by location.name), '[]'::jsonb)
  into v_locations
  from public.locations location
  where location.company_id = p_company_id
    and location.is_active
    and location.location_type = 'sucursal';

  select count(*)
  into v_catalog_total
  from public.products product
  where product.company_id = p_company_id
    and product.is_sellable;

  select count(*)
  into v_outside_total
  from public.products product
  where product.company_id = p_company_id
    and product.is_sellable
    and not exists (
      select 1
      from public.sales_assortment_items item
      join public.sales_assortments assortment on assortment.id = item.assortment_id
      where item.product_id = product.id
        and assortment.company_id = p_company_id
        and assortment.status in ('draft', 'active')
    );

  return jsonb_build_object(
    'assortments', v_assortments,
    'locations', v_locations,
    'catalog_total', coalesce(v_catalog_total, 0),
    'outside_assortment_total', coalesce(v_outside_total, 0)
  );
end;
$$;

create or replace function public.get_product_sales_assortment_context(
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
  v_assortments jsonb;
  v_included_count integer;
  v_offered_location_count integer;
  v_readiness jsonb;
begin
  if auth.uid() is null
    or not public.has_company_permission(p_company_id, 'manage_assortments') then
    raise exception 'No autorizado para configurar surtidos.';
  end if;

  select *
  into v_product
  from public.products product
  where product.id = p_product_id
    and product.company_id = p_company_id;
  if not found then
    raise exception 'Producto no encontrado.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', assortment.id,
    'code', assortment.code,
    'name', assortment.name,
    'status', assortment.status,
    'included', exists (
      select 1
      from public.sales_assortment_items item
      where item.assortment_id = assortment.id
        and item.product_id = p_product_id
    ),
    'locations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', location.id,
        'code', location.external_code,
        'name', location.name
      ) order by location.name)
      from public.location_sales_assortments assignment
      join public.locations location on location.id = assignment.location_id
      where assignment.assortment_id = assortment.id
        and assignment.valid_from <= now()
        and (assignment.valid_to is null or assignment.valid_to > now())
    ), '[]'::jsonb)
  ) order by
    case assortment.status when 'active' then 1 when 'draft' then 2 else 3 end,
    assortment.name), '[]'::jsonb)
  into v_assortments
  from public.sales_assortments assortment
  where assortment.company_id = p_company_id;

  select count(*)
  into v_included_count
  from public.sales_assortment_items item
  join public.sales_assortments assortment on assortment.id = item.assortment_id
  where item.product_id = p_product_id
    and assortment.company_id = p_company_id
    and assortment.status in ('draft', 'active');

  select count(distinct assignment.location_id)
  into v_offered_location_count
  from public.sales_assortment_items item
  join public.sales_assortments assortment on assortment.id = item.assortment_id
  join public.location_sales_assortments assignment
    on assignment.assortment_id = assortment.id
  where item.product_id = p_product_id
    and assortment.company_id = p_company_id
    and assortment.status = 'active'
    and assignment.valid_from <= now()
    and (assignment.valid_to is null or assignment.valid_to > now());

  v_readiness := public.product_pos_readiness_detail(
    p_company_id,
    p_product_id,
    null,
    now()
  );

  return jsonb_build_object(
    'product', jsonb_build_object(
      'id', v_product.id,
      'code', v_product.internal_sku,
      'name', v_product.name,
      'is_sellable', v_product.is_sellable
    ),
    'assortments', v_assortments,
    'included_assortment_count', coalesce(v_included_count, 0),
    'offered_location_count', coalesce(v_offered_location_count, 0),
    'commercial_readiness', v_readiness
  );
end;
$$;

create or replace function public.set_product_sales_assortments(
  p_company_id uuid,
  p_product_id uuid,
  p_assortment_ids uuid[],
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_requested integer;
  v_valid integer;
  v_added integer := 0;
  v_removed integer := 0;
  v_product_name text;
begin
  if auth.uid() is null
    or not public.has_company_permission(p_company_id, 'manage_assortments') then
    raise exception 'No autorizado para configurar surtidos.';
  end if;
  if nullif(trim(p_reason), '') is null then
    raise exception 'El motivo es obligatorio.';
  end if;

  select product.name
  into v_product_name
  from public.products product
  where product.id = p_product_id
    and product.company_id = p_company_id
  for update;
  if not found then
    raise exception 'Producto no encontrado.';
  end if;

  select count(distinct assortment_id)
  into v_requested
  from unnest(coalesce(p_assortment_ids, '{}'::uuid[])) requested(assortment_id)
  where assortment_id is not null;

  select count(*)
  into v_valid
  from public.sales_assortments assortment
  where assortment.company_id = p_company_id
    and assortment.id = any(coalesce(p_assortment_ids, '{}'::uuid[]));
  if v_valid <> v_requested then
    raise exception 'La selección contiene surtidos inválidos.';
  end if;

  insert into public.sales_assortment_items(assortment_id, product_id, created_by)
  select assortment.id, p_product_id, auth.uid()
  from public.sales_assortments assortment
  where assortment.company_id = p_company_id
    and assortment.id = any(coalesce(p_assortment_ids, '{}'::uuid[]))
    and not exists (
      select 1
      from public.sales_assortment_items current_item
      where current_item.assortment_id = assortment.id
        and current_item.product_id = p_product_id
    );
  get diagnostics v_added = row_count;

  delete from public.sales_assortment_items item
  using public.sales_assortments assortment
  where assortment.id = item.assortment_id
    and assortment.company_id = p_company_id
    and item.product_id = p_product_id
    and not (item.assortment_id = any(coalesce(p_assortment_ids, '{}'::uuid[])));
  get diagnostics v_removed = row_count;

  insert into public.audit_log(
    company_id, actor_id, action, entity_type, entity_id, metadata
  )
  values (
    p_company_id,
    auth.uid(),
    'product.assortments_set',
    'product',
    p_product_id,
    jsonb_build_object(
      'reason', trim(p_reason),
      'product_name', v_product_name,
      'assortment_ids', to_jsonb(coalesce(p_assortment_ids, '{}'::uuid[])),
      'added', v_added,
      'removed', v_removed
    )
  );

  return jsonb_build_object(
    'product_id', p_product_id,
    'assortments', v_requested,
    'added', v_added,
    'removed', v_removed
  );
end;
$$;

create or replace function public.set_sales_assortment_locations(
  p_company_id uuid,
  p_assortment_id uuid,
  p_location_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_assortment public.sales_assortments%rowtype;
  v_requested integer;
  v_valid integer;
  v_added integer := 0;
  v_removed integer := 0;
  v_now timestamptz := clock_timestamp();
begin
  if auth.uid() is null
    or not public.has_company_permission(p_company_id, 'manage_assortments') then
    raise exception 'No autorizado para configurar surtidos.';
  end if;

  select *
  into v_assortment
  from public.sales_assortments assortment
  where assortment.id = p_assortment_id
    and assortment.company_id = p_company_id
  for update;
  if not found then
    raise exception 'Surtido no encontrado.';
  end if;

  select count(distinct location_id)
  into v_requested
  from unnest(coalesce(p_location_ids, '{}'::uuid[])) requested(location_id)
  where location_id is not null;

  select count(*)
  into v_valid
  from public.locations location
  where location.company_id = p_company_id
    and location.id = any(coalesce(p_location_ids, '{}'::uuid[]))
    and location.is_active
    and location.location_type = 'sucursal';
  if v_valid <> v_requested then
    raise exception 'La selección contiene sucursales inválidas.';
  end if;
  if v_assortment.status = 'active' and v_requested = 0 then
    raise exception 'Un surtido activo debe conservar al menos una sucursal.';
  end if;

  update public.location_sales_assortments assignment
  set valid_to = greatest(v_now, assignment.valid_from + interval '1 microsecond')
  where assignment.assortment_id = p_assortment_id
    and assignment.valid_to is null
    and not (assignment.location_id = any(coalesce(p_location_ids, '{}'::uuid[])));
  get diagnostics v_removed = row_count;

  insert into public.location_sales_assortments(
    assortment_id, location_id, valid_from, created_by
  )
  select p_assortment_id, location.id, v_now, auth.uid()
  from public.locations location
  where location.company_id = p_company_id
    and location.id = any(coalesce(p_location_ids, '{}'::uuid[]))
    and not exists (
      select 1
      from public.location_sales_assortments assignment
      where assignment.assortment_id = p_assortment_id
        and assignment.location_id = location.id
        and assignment.valid_to is null
    );
  get diagnostics v_added = row_count;

  insert into public.audit_log(
    company_id, actor_id, action, entity_type, entity_id, metadata
  )
  values (
    p_company_id,
    auth.uid(),
    'sales_assortment.locations_set',
    'sales_assortment',
    p_assortment_id,
    jsonb_build_object(
      'location_ids', to_jsonb(coalesce(p_location_ids, '{}'::uuid[])),
      'added', v_added,
      'removed', v_removed
    )
  );

  return jsonb_build_object(
    'locations', v_requested,
    'added', v_added,
    'removed', v_removed
  );
end;
$$;

create or replace function public.set_sales_assortment_status(
  p_company_id uuid,
  p_assortment_id uuid,
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_assortment public.sales_assortments%rowtype;
begin
  if auth.uid() is null
    or not public.has_company_permission(p_company_id, 'manage_assortments') then
    raise exception 'No autorizado para configurar surtidos.';
  end if;
  if p_status is null or p_status not in ('draft', 'active', 'inactive') then
    raise exception 'Estado de surtido inválido.';
  end if;

  select *
  into v_assortment
  from public.sales_assortments assortment
  where assortment.id = p_assortment_id
    and assortment.company_id = p_company_id
  for update;
  if not found then
    raise exception 'Surtido no encontrado.';
  end if;

  if p_status = 'active' and not exists (
    select 1
    from public.location_sales_assortments assignment
    where assignment.assortment_id = p_assortment_id
      and assignment.valid_from <= now()
      and (assignment.valid_to is null or assignment.valid_to > now())
  ) then
    raise exception 'Asigna al menos una sucursal antes de activar el surtido.';
  end if;

  update public.sales_assortments
  set status = p_status
  where id = p_assortment_id;

  return jsonb_build_object('id', p_assortment_id, 'status', p_status);
end;
$$;

-- El diagnóstico POS debe explicar también una exclusión comercial. La búsqueda
-- vendible sigue limitada al surtido activo; esta función sólo hace visible la
-- causa y nunca permite agregar el producto al carrito.
create or replace function public.search_pos_blocked_products(
  p_company_id uuid,
  p_location_id uuid,
  p_customer_id uuid default null,
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 30,
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 30), 1), 100);
  v_query text := lower(trim(regexp_replace(coalesce(p_query, ''), '\s+', ' ', 'g')));
  v_total integer;
  v_items jsonb;
  v_price_list_id uuid;
  v_currency_code text;
begin
  perform public.assert_pos_access(p_company_id, p_location_id, 'use_pos');
  if v_query = '' then
    return jsonb_build_object('items', '[]'::jsonb, 'total', 0, 'page', 1, 'page_size', v_size);
  end if;
  if p_customer_id is not null and not exists (
    select 1
    from public.customers customer
    where customer.id = p_customer_id
      and customer.company_id = p_company_id
      and customer.is_active
  ) then
    raise exception 'Cliente no encontrado o inactivo.';
  end if;

  select coalesce(customer.price_list_id, location.default_price_list_id, company.default_price_list_id)
  into v_price_list_id
  from public.companies company
  join public.locations location
    on location.id = p_location_id
    and location.company_id = company.id
  left join public.customers customer on customer.id = p_customer_id
  where company.id = p_company_id;

  select price_list.currency_code
  into v_currency_code
  from public.price_lists price_list
  where price_list.id = v_price_list_id
    and price_list.company_id = p_company_id
    and price_list.is_active
    and price_list.status = 'active';

  with matching as materialized (
    select product.*
    from public.products product
    where product.company_id = p_company_id
      and not exists (
        select 1
        from regexp_split_to_table(v_query, '\s+') token
        where token <> ''
          and not (
            lower(product.name) like '%' || token || '%'
            or lower(coalesce(product.internal_sku, '')) like '%' || token || '%'
            or lower(coalesce(product.barcode, '')) = token
            or exists (
              select 1
              from public.product_aliases alias
              where alias.product_id = product.id
                and alias.normalized_value like '%' || token || '%'
            )
            or exists (
              select 1
              from public.product_external_references reference
              where reference.product_id = product.id
                and lower(reference.external_code) like '%' || token || '%'
            )
          )
      )
  ), detailed as materialized (
    select
      product.id,
      product.name,
      product.internal_sku,
      product.barcode,
      product.unit,
      product.is_inventory_tracked,
      coalesce(balance.quantity_on_hand, 0) as quantity_on_hand,
      price.amount as price_amount,
      array_remove(array[
        case when not exists (
          select 1
          from public.location_sales_assortments assignment
          join public.sales_assortments assortment on assortment.id = assignment.assortment_id
          join public.sales_assortment_items item
            on item.assortment_id = assortment.id
            and item.product_id = product.id
          where assignment.location_id = p_location_id
            and assignment.valid_from <= p_at
            and (assignment.valid_to is null or assignment.valid_to > p_at)
            and assortment.company_id = p_company_id
            and assortment.status = 'active'
            and (assortment.valid_from is null or assortment.valid_from <= p_at)
            and (assortment.valid_to is null or assortment.valid_to > p_at)
        ) then 'outside_assortment' end,
        case when not product.is_active then 'inactive' end,
        case when not product.is_sellable then 'not_sellable' end,
        case when product.commercial_review_required then 'commercial_review_required' end,
        case when product.sales_unit_id is null then 'missing_sales_unit' end,
        case when product.tax_category_id is null then 'missing_tax_category' end,
        case when product.tax_category_id is not null and not exists (
          select 1
          from public.tax_rates tax_rate
          where tax_rate.tax_category_id = product.tax_category_id
            and tax_rate.valid_from <= p_at
            and (tax_rate.valid_to is null or tax_rate.valid_to > p_at)
        ) then 'missing_current_tax_rate' end,
        case when coalesce(price.amount, 0) <= 0 then 'missing_or_zero_price' end,
        case when product.is_inventory_tracked
          and coalesce(balance.quantity_on_hand, 0) <= 0 then 'out_of_stock' end
      ]::text[], null) as blockers
    from matching product
    left join public.inventory_balances balance
      on balance.location_id = p_location_id
      and balance.product_id = product.id
    left join lateral (
      select product_price.amount
      from public.product_prices product_price
      where product_price.product_id = product.id
        and product_price.price_list_id = v_price_list_id
        and product_price.currency_code = v_currency_code
        and product_price.valid_from <= p_at
        and (product_price.valid_to is null or product_price.valid_to > p_at)
      order by product_price.valid_from desc
      limit 1
    ) price on true
  ), blocked as materialized (
    select *
    from detailed
    where cardinality(blockers) > 0
  ), paged as (
    select *
    from blocked
    order by name, id
    limit v_size offset (v_page - 1) * v_size
  )
  select
    (select count(*) from blocked),
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'product_id', product.id,
        'code', coalesce(product.internal_sku, product.barcode),
        'name', product.name,
        'unit', product.unit,
        'inventory_tracked', product.is_inventory_tracked,
        'quantity_on_hand', product.quantity_on_hand,
        'price_amount', product.price_amount,
        'currency_code', v_currency_code,
        'blockers', to_jsonb(product.blockers)
      ) order by product.name, product.id)
      from paged product
    ), '[]'::jsonb)
  into v_total, v_items;

  return jsonb_build_object(
    'items', v_items,
    'total', coalesce(v_total, 0),
    'page', v_page,
    'page_size', v_size
  );
end;
$$;

create or replace function public.confirm_product_import_with_assortments(
  p_import_batch_id uuid,
  p_assortment_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch public.import_batches%rowtype;
  v_result jsonb;
  v_requested integer;
  v_valid integer;
  v_assorted integer := 0;
begin
  select *
  into v_batch
  from public.import_batches batch
  where batch.id = p_import_batch_id
  for update;
  if not found
    or v_batch.import_type <> 'products'
    or auth.uid() is null
    or not public.has_company_permission(v_batch.company_id, 'import_data') then
    raise exception 'No autorizado para confirmar este catálogo.';
  end if;

  select count(distinct assortment_id)
  into v_requested
  from unnest(coalesce(p_assortment_ids, '{}'::uuid[])) requested(assortment_id)
  where assortment_id is not null;

  if v_requested > 0
    and not public.has_company_permission(v_batch.company_id, 'manage_assortments') then
    raise exception 'No autorizado para asignar el catálogo a surtidos.';
  end if;

  select count(*)
  into v_valid
  from public.sales_assortments assortment
  where assortment.company_id = v_batch.company_id
    and assortment.id = any(coalesce(p_assortment_ids, '{}'::uuid[]));
  if v_valid <> v_requested then
    raise exception 'La selección contiene surtidos inválidos.';
  end if;

  v_result := public.confirm_staged_import(p_import_batch_id);
  if coalesce(v_result ->> 'status', '') <> 'completed' then
    return v_result;
  end if;

  if v_requested > 0 then
    with imported_products as (
      select distinct product.id
      from public.import_staging_rows staged
      join public.product_external_references reference
        on reference.company_id = v_batch.company_id
        and reference.source_system = 'alpha'
        and reference.external_code = staged.normalized_data ->> 'alphaSku'
      join public.products product
        on product.id = reference.product_id
        and product.company_id = v_batch.company_id
      where staged.import_batch_id = p_import_batch_id
        and staged.detected_type = 'products'
        and coalesce((staged.normalized_data ->> 'rejected')::boolean, false) = false
    )
    insert into public.sales_assortment_items(assortment_id, product_id, created_by)
    select assortment.id, product.id, auth.uid()
    from public.sales_assortments assortment
    cross join imported_products product
    where assortment.company_id = v_batch.company_id
      and assortment.id = any(p_assortment_ids)
    on conflict do nothing;
    get diagnostics v_assorted = row_count;
  end if;

  insert into public.audit_log(
    company_id, actor_id, action, entity_type, entity_id, metadata
  )
  values (
    v_batch.company_id,
    auth.uid(),
    'product_import.assortments_applied',
    'import_batch',
    p_import_batch_id,
    jsonb_build_object(
      'assortment_ids', to_jsonb(coalesce(p_assortment_ids, '{}'::uuid[])),
      'memberships_added', v_assorted,
      'outside_assortment_selected', v_requested = 0
    )
  );

  return v_result || jsonb_build_object(
    'assortments', v_requested,
    'memberships_added', v_assorted
  );
end;
$$;

revoke all on function public.get_sales_assortment_admin_context(uuid) from public;
revoke all on function public.get_product_sales_assortment_context(uuid, uuid) from public;
revoke all on function public.set_product_sales_assortments(uuid, uuid, uuid[], text) from public;
revoke all on function public.set_sales_assortment_locations(uuid, uuid, uuid[]) from public;
revoke all on function public.set_sales_assortment_status(uuid, uuid, text) from public;
revoke all on function public.search_pos_blocked_products(uuid, uuid, uuid, text, integer, integer, timestamptz) from public;
revoke all on function public.confirm_product_import_with_assortments(uuid, uuid[]) from public;

grant execute on function public.get_sales_assortment_admin_context(uuid) to authenticated;
grant execute on function public.get_product_sales_assortment_context(uuid, uuid) to authenticated;
grant execute on function public.set_product_sales_assortments(uuid, uuid, uuid[], text) to authenticated;
grant execute on function public.set_sales_assortment_locations(uuid, uuid, uuid[]) to authenticated;
grant execute on function public.set_sales_assortment_status(uuid, uuid, text) to authenticated;
grant execute on function public.search_pos_blocked_products(uuid, uuid, uuid, text, integer, integer, timestamptz) to authenticated;
grant execute on function public.confirm_product_import_with_assortments(uuid, uuid[]) to authenticated;

commit;
