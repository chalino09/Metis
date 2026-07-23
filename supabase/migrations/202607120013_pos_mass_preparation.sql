-- Satrapy · POS mass preparation
-- Commercial assortment membership is durable. Readiness only controls whether
-- a member can be sold at the current moment.

create or replace function public.enforce_sales_assortment_activation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item_count integer;
  v_location_count integer;
begin
  if new.status <> 'active' then
    return new;
  end if;

  select count(*) into v_item_count
  from public.sales_assortment_items
  where assortment_id = new.id;

  if v_item_count = 0 then
    raise exception 'No se puede activar un surtido sin productos.';
  end if;

  select count(*) into v_location_count
  from public.location_sales_assortments assignment
  join public.locations location_data on location_data.id = assignment.location_id
  where assignment.assortment_id = new.id
    and assignment.valid_from <= now()
    and (assignment.valid_to is null or assignment.valid_to > now())
    and location_data.company_id = new.company_id
    and location_data.is_active
    and location_data.location_type = 'sucursal';

  if v_location_count = 0 then
    raise exception 'No se puede activar un surtido sin sucursales asignadas.';
  end if;

  return new;
end;
$$;

-- Suppress per-row assortment noise while a trusted mass operation is running.
-- The RPC writes one actor-visible summary audit event instead.
create or replace function public.audit_pos_preflight_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_entity_id uuid;
  v_action text;
begin
  if coalesce(current_setting('satrapy.bulk_assortment', true), 'off') = 'on'
    and tg_table_name in ('sales_assortments', 'sales_assortment_items', 'location_sales_assortments') then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  case tg_table_name
    when 'product_external_references' then
      if tg_op = 'DELETE' then
        v_company_id := old.company_id;
        v_entity_id := old.id;
      else
        v_company_id := new.company_id;
        v_entity_id := new.id;
      end if;
    when 'location_external_references' then
      if tg_op = 'DELETE' then
        v_company_id := old.company_id;
        v_entity_id := old.id;
      else
        v_company_id := new.company_id;
        v_entity_id := new.id;
      end if;
    when 'sales_assortments' then
      if tg_op = 'DELETE' then
        v_company_id := old.company_id;
        v_entity_id := old.id;
      else
        v_company_id := new.company_id;
        v_entity_id := new.id;
      end if;
    when 'sales_assortment_items' then
      select company_id into v_company_id from public.sales_assortments
      where id = case when tg_op = 'DELETE' then old.assortment_id else new.assortment_id end;
      v_entity_id := case when tg_op = 'DELETE' then old.product_id else new.product_id end;
    when 'location_sales_assortments' then
      select company_id into v_company_id from public.sales_assortments
      where id = case when tg_op = 'DELETE' then old.assortment_id else new.assortment_id end;
      v_entity_id := case when tg_op = 'DELETE' then old.id else new.id end;
    when 'tax_categories' then
      if tg_op = 'DELETE' then
        v_company_id := old.company_id;
        v_entity_id := old.id;
      else
        v_company_id := new.company_id;
        v_entity_id := new.id;
      end if;
    when 'tax_rates' then
      select company_id into v_company_id from public.tax_categories
      where id = case when tg_op = 'DELETE' then old.tax_category_id else new.tax_category_id end;
      v_entity_id := case when tg_op = 'DELETE' then old.id else new.id end;
  end case;

  v_action := case tg_op
    when 'INSERT' then tg_table_name || '.created'
    when 'DELETE' then tg_table_name || '.deleted'
    else tg_table_name || '.updated'
  end;

  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values (
    v_company_id,
    auth.uid(),
    v_action,
    tg_table_name,
    v_entity_id,
    jsonb_build_object('operation', tg_op)
  );

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create or replace function public.get_pos_catalog_readiness_summary(
  p_company_id uuid,
  p_assortment_id uuid default null,
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_total integer;
  v_ready integer;
  v_new_products integer;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_pos_readiness') then
    raise exception 'No autorizado para consultar la preparación POS.';
  end if;

  if p_assortment_id is not null and not exists (
    select 1 from public.sales_assortments
    where id = p_assortment_id and company_id = p_company_id
  ) then
    raise exception 'Surtido no encontrado.';
  end if;

  with catalog as materialized (
    select product.id, readiness
    from public.products product
    cross join lateral public.product_pos_readiness_detail(p_company_id, product.id, null, p_at) readiness
    where product.company_id = p_company_id
      and product.is_sellable
  )
  select
    count(*),
    count(*) filter (where coalesce((readiness ->> 'pos_ready')::boolean, false)),
    count(*) filter (
      where p_assortment_id is null
        or not exists (
          select 1 from public.sales_assortment_items item
          where item.assortment_id = p_assortment_id
            and item.product_id = catalog.id
        )
    )
  into v_total, v_ready, v_new_products
  from catalog;

  return jsonb_build_object(
    'total', coalesce(v_total, 0),
    'ready', coalesce(v_ready, 0),
    'pending', greatest(coalesce(v_total, 0) - coalesce(v_ready, 0), 0),
    'new_products', coalesce(v_new_products, 0)
  );
end;
$$;

create or replace function public.prepare_pos_pilot(
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
  v_assortment_id uuid;
  v_requested_locations integer;
  v_valid_locations integer;
  v_total integer;
  v_ready integer;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_assortments') then
    raise exception 'No autorizado para preparar surtidos.';
  end if;

  if nullif(trim(coalesce(p_code, '')), '') is null
    or nullif(trim(coalesce(p_name, '')), '') is null then
    raise exception 'Código y nombre son obligatorios.';
  end if;

  if coalesce(cardinality(p_location_ids), 0) = 0 then
    raise exception 'Selecciona al menos una sucursal.';
  end if;

  select count(distinct requested.location_id)
  into v_requested_locations
  from unnest(p_location_ids) requested(location_id)
  where requested.location_id is not null;

  if v_requested_locations <> cardinality(p_location_ids) then
    raise exception 'La selección contiene sucursales inválidas o duplicadas.';
  end if;

  select count(*) into v_valid_locations
  from public.locations location_data
  where location_data.id = any(p_location_ids)
    and location_data.company_id = p_company_id
    and location_data.is_active
    and location_data.location_type = 'sucursal';

  if v_valid_locations <> v_requested_locations then
    raise exception 'Todas las ubicaciones deben ser sucursales activas de la empresa.';
  end if;

  if not exists (
    select 1 from public.products
    where company_id = p_company_id and is_sellable
  ) then
    raise exception 'No hay productos vendibles para preparar el piloto.';
  end if;

  perform set_config('satrapy.bulk_assortment', 'on', true);

  insert into public.sales_assortments (company_id, code, name, status, created_by)
  values (p_company_id, trim(p_code), trim(p_name), 'draft', auth.uid())
  returning id into v_assortment_id;

  insert into public.sales_assortment_items (assortment_id, product_id, created_by)
  select v_assortment_id, product.id, auth.uid()
  from public.products product
  where product.company_id = p_company_id
    and product.is_sellable
  on conflict do nothing;

  insert into public.location_sales_assortments (location_id, assortment_id, valid_from, created_by)
  select location_data.id, v_assortment_id, p_at, auth.uid()
  from public.locations location_data
  where location_data.id = any(p_location_ids)
    and location_data.company_id = p_company_id
    and location_data.is_active
    and location_data.location_type = 'sucursal';

  with assortment_catalog as materialized (
    select product.id, readiness
    from public.sales_assortment_items item
    join public.products product on product.id = item.product_id
    cross join lateral public.product_pos_readiness_detail(p_company_id, product.id, null, p_at) readiness
    where item.assortment_id = v_assortment_id
  )
  select
    count(*),
    count(*) filter (where coalesce((readiness ->> 'pos_ready')::boolean, false))
  into v_total, v_ready
  from assortment_catalog;

  perform set_config('satrapy.bulk_assortment', 'off', true);

  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values (
    p_company_id,
    auth.uid(),
    'sales_assortment.prepared',
    'sales_assortments',
    v_assortment_id,
    jsonb_build_object(
      'products_processed', coalesce(v_total, 0),
      'ready', coalesce(v_ready, 0),
      'pending', greatest(coalesce(v_total, 0) - coalesce(v_ready, 0), 0),
      'locations_assigned', v_valid_locations,
      'location_ids', to_jsonb(p_location_ids)
    )
  );

  return jsonb_build_object(
    'assortment_id', v_assortment_id,
    'products_processed', coalesce(v_total, 0),
    'ready', coalesce(v_ready, 0),
    'pending', greatest(coalesce(v_total, 0) - coalesce(v_ready, 0), 0),
    'locations_assigned', v_valid_locations
  );
exception when others then
  perform set_config('satrapy.bulk_assortment', 'off', true);
  raise;
end;
$$;

create or replace function public.refresh_pos_assortment_catalog(
  p_company_id uuid,
  p_assortment_id uuid,
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_added integer;
  v_total integer;
  v_ready integer;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_assortments') then
    raise exception 'No autorizado para actualizar surtidos.';
  end if;

  perform 1
  from public.sales_assortments
  where id = p_assortment_id and company_id = p_company_id
  for update;
  if not found then raise exception 'Surtido no encontrado.'; end if;

  perform set_config('satrapy.bulk_assortment', 'on', true);

  insert into public.sales_assortment_items (assortment_id, product_id, created_by)
  select p_assortment_id, product.id, auth.uid()
  from public.products product
  where product.company_id = p_company_id
    and product.is_sellable
  on conflict do nothing;
  get diagnostics v_added = row_count;

  with assortment_catalog as materialized (
    select product.id, readiness
    from public.sales_assortment_items item
    join public.products product on product.id = item.product_id
    cross join lateral public.product_pos_readiness_detail(p_company_id, product.id, null, p_at) readiness
    where item.assortment_id = p_assortment_id
  )
  select
    count(*),
    count(*) filter (where coalesce((readiness ->> 'pos_ready')::boolean, false))
  into v_total, v_ready
  from assortment_catalog;

  perform set_config('satrapy.bulk_assortment', 'off', true);

  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values (
    p_company_id,
    auth.uid(),
    'sales_assortment.catalog_refreshed',
    'sales_assortments',
    p_assortment_id,
    jsonb_build_object(
      'products_added', coalesce(v_added, 0),
      'products_processed', coalesce(v_total, 0),
      'ready', coalesce(v_ready, 0),
      'pending', greatest(coalesce(v_total, 0) - coalesce(v_ready, 0), 0)
    )
  );

  return jsonb_build_object(
    'products_added', coalesce(v_added, 0),
    'products_processed', coalesce(v_total, 0),
    'ready', coalesce(v_ready, 0),
    'pending', greatest(coalesce(v_total, 0) - coalesce(v_ready, 0), 0)
  );
exception when others then
  perform set_config('satrapy.bulk_assortment', 'off', true);
  raise;
end;
$$;

create or replace function public.list_pos_assortment_readiness(
  p_company_id uuid,
  p_assortment_id uuid,
  p_query text default null,
  p_status text default null,
  p_page integer default 1,
  p_page_size integer default 50,
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 50), 1), 100);
  v_query text := lower(trim(coalesce(p_query, '')));
  v_status text := nullif(lower(trim(coalesce(p_status, ''))), 'all');
  v_total integer;
  v_ready integer;
  v_filtered_total integer;
  v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_pos_readiness') then
    raise exception 'No autorizado para consultar la preparación POS.';
  end if;

  if v_status is not null and v_status not in ('ready', 'pending') then
    raise exception 'Estado de preparación inválido.';
  end if;

  if not exists (
    select 1 from public.sales_assortments
    where id = p_assortment_id and company_id = p_company_id
  ) then
    raise exception 'Surtido no encontrado.';
  end if;

  with detailed as materialized (
    select product.id, readiness
    from public.sales_assortment_items item
    join public.products product on product.id = item.product_id
    cross join lateral public.product_pos_readiness_detail(p_company_id, product.id, null, p_at) readiness
    where item.assortment_id = p_assortment_id
      and product.company_id = p_company_id
  )
  select
    count(*),
    count(*) filter (where coalesce((readiness ->> 'pos_ready')::boolean, false))
  into v_total, v_ready
  from detailed;

  with detailed as materialized (
    select
      product.id,
      product.name,
      product.internal_sku,
      product.barcode,
      product.unit,
      readiness,
      coalesce(
        product.internal_sku,
        (
          select reference.external_code
          from public.product_external_references reference
          where reference.product_id = product.id
          order by reference.is_primary desc, reference.created_at asc
          limit 1
        )
      ) as display_code,
      coalesce((readiness ->> 'pos_ready')::boolean, false) as pos_ready
    from public.sales_assortment_items item
    join public.products product on product.id = item.product_id
    cross join lateral public.product_pos_readiness_detail(p_company_id, product.id, null, p_at) readiness
    where item.assortment_id = p_assortment_id
      and product.company_id = p_company_id
  ), filtered as materialized (
    select *
    from detailed
    where (v_status is null or (v_status = 'ready' and pos_ready) or (v_status = 'pending' and not pos_ready))
      and (
        v_query = ''
        or lower(name) like '%' || v_query || '%'
        or lower(coalesce(internal_sku, '')) like '%' || v_query || '%'
        or lower(coalesce(barcode, '')) = v_query
        or exists (
          select 1 from public.product_aliases alias
          where alias.product_id = detailed.id
            and lower(alias.normalized_value) like '%' || v_query || '%'
        )
        or exists (
          select 1 from public.product_external_references reference
          where reference.product_id = detailed.id
            and lower(reference.external_code) like '%' || v_query || '%'
        )
      )
  )
  select count(*) into v_filtered_total from filtered;

  with detailed as materialized (
    select
      product.id,
      product.name,
      product.internal_sku,
      product.barcode,
      product.unit,
      readiness,
      coalesce(
        product.internal_sku,
        (
          select reference.external_code
          from public.product_external_references reference
          where reference.product_id = product.id
          order by reference.is_primary desc, reference.created_at asc
          limit 1
        )
      ) as display_code,
      coalesce((readiness ->> 'pos_ready')::boolean, false) as pos_ready
    from public.sales_assortment_items item
    join public.products product on product.id = item.product_id
    cross join lateral public.product_pos_readiness_detail(p_company_id, product.id, null, p_at) readiness
    where item.assortment_id = p_assortment_id
      and product.company_id = p_company_id
  ), filtered as (
    select *
    from detailed
    where (v_status is null or (v_status = 'ready' and pos_ready) or (v_status = 'pending' and not pos_ready))
      and (
        v_query = ''
        or lower(name) like '%' || v_query || '%'
        or lower(coalesce(internal_sku, '')) like '%' || v_query || '%'
        or lower(coalesce(barcode, '')) = v_query
        or exists (
          select 1 from public.product_aliases alias
          where alias.product_id = detailed.id
            and lower(alias.normalized_value) like '%' || v_query || '%'
        )
        or exists (
          select 1 from public.product_external_references reference
          where reference.product_id = detailed.id
            and lower(reference.external_code) like '%' || v_query || '%'
        )
      )
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'product_id', paged.id,
    'code', paged.display_code,
    'name', paged.name,
    'unit', paged.unit,
    'pos_ready', paged.pos_ready,
    'blockers', paged.readiness -> 'blockers',
    'warnings', paged.readiness -> 'warnings',
    'price_amount', paged.readiness -> 'price_amount',
    'currency_code', paged.readiness -> 'currency_code'
  ) order by paged.pos_ready desc, paged.name), '[]'::jsonb)
  into v_items
  from (
    select * from filtered
    order by pos_ready desc, name
    limit v_size offset (v_page - 1) * v_size
  ) paged;

  return jsonb_build_object(
    'summary', jsonb_build_object(
      'total', coalesce(v_total, 0),
      'ready', coalesce(v_ready, 0),
      'pending', greatest(coalesce(v_total, 0) - coalesce(v_ready, 0), 0)
    ),
    'items', v_items,
    'filtered_total', coalesce(v_filtered_total, 0),
    'page', v_page,
    'page_size', v_size
  );
end;
$$;

revoke all on function public.get_pos_catalog_readiness_summary(uuid, uuid, timestamptz) from public;
revoke all on function public.prepare_pos_pilot(uuid, text, text, uuid[], timestamptz) from public;
revoke all on function public.refresh_pos_assortment_catalog(uuid, uuid, timestamptz) from public;
revoke all on function public.list_pos_assortment_readiness(uuid, uuid, text, text, integer, integer, timestamptz) from public;

grant execute on function public.get_pos_catalog_readiness_summary(uuid, uuid, timestamptz) to authenticated;
grant execute on function public.prepare_pos_pilot(uuid, text, text, uuid[], timestamptz) to authenticated;
grant execute on function public.refresh_pos_assortment_catalog(uuid, uuid, timestamptz) to authenticated;
grant execute on function public.list_pos_assortment_readiness(uuid, uuid, text, text, integer, integer, timestamptz) to authenticated;
