-- Satrapy · Administración comercial de surtidos
-- La pertenencia al surtido es una decisión comercial independiente de readiness.

create or replace function public.list_sales_assortment_membership(
  p_company_id uuid,
  p_assortment_id uuid,
  p_query text default null,
  p_membership text default null,
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
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 50), 1), 100);
  v_query text := lower(trim(coalesce(p_query, '')));
  v_total integer;
  v_member_count integer;
  v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_assortments') then
    raise exception 'No autorizado para configurar surtidos.';
  end if;

  if p_membership is not null and p_membership not in ('included', 'excluded') then
    raise exception 'Filtro de pertenencia inválido.';
  end if;

  perform 1 from public.sales_assortments
  where id = p_assortment_id and company_id = p_company_id;
  if not found then raise exception 'Surtido no encontrado.'; end if;

  select count(*) into v_member_count
  from public.sales_assortment_items
  where assortment_id = p_assortment_id;

  with products_with_membership as (
    select
      product.id,
      product.name,
      coalesce(product.internal_sku, (
        select reference.external_code
        from public.product_external_references reference
        where reference.product_id = product.id
        order by reference.is_primary desc, reference.created_at asc
        limit 1
      )) as code,
      exists (
        select 1 from public.sales_assortment_items item
        where item.assortment_id = p_assortment_id and item.product_id = product.id
      ) as included
    from public.products product
    where product.company_id = p_company_id
      and (
        v_query = ''
        or lower(product.name) like '%' || v_query || '%'
        or lower(coalesce(product.internal_sku, '')) like '%' || v_query || '%'
        or lower(coalesce(product.barcode, '')) = v_query
        or exists (
          select 1 from public.product_external_references reference
          where reference.product_id = product.id
            and lower(reference.external_code) like '%' || v_query || '%'
        )
      )
  ), filtered as (
    select * from products_with_membership
    where p_membership is null
      or (p_membership = 'included' and included)
      or (p_membership = 'excluded' and not included)
  )
  select count(*) into v_total from filtered;

  with products_with_membership as (
    select
      product.id,
      product.name,
      coalesce(product.internal_sku, (
        select reference.external_code
        from public.product_external_references reference
        where reference.product_id = product.id
        order by reference.is_primary desc, reference.created_at asc
        limit 1
      )) as code,
      exists (
        select 1 from public.sales_assortment_items item
        where item.assortment_id = p_assortment_id and item.product_id = product.id
      ) as included
    from public.products product
    where product.company_id = p_company_id
      and (
        v_query = ''
        or lower(product.name) like '%' || v_query || '%'
        or lower(coalesce(product.internal_sku, '')) like '%' || v_query || '%'
        or lower(coalesce(product.barcode, '')) = v_query
        or exists (
          select 1 from public.product_external_references reference
          where reference.product_id = product.id
            and lower(reference.external_code) like '%' || v_query || '%'
        )
      )
  ), filtered as (
    select * from products_with_membership
    where p_membership is null
      or (p_membership = 'included' and included)
      or (p_membership = 'excluded' and not included)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'product_id', id,
    'code', code,
    'name', name,
    'included', included
  ) order by name), '[]'::jsonb)
  into v_items
  from (
    select * from filtered
    order by name
    limit v_size offset (v_page - 1) * v_size
  ) paged;

  return jsonb_build_object(
    'items', v_items,
    'total', coalesce(v_total, 0),
    'member_count', coalesce(v_member_count, 0),
    'page', v_page,
    'page_size', v_size
  );
end;
$$;

create or replace function public.set_sales_assortment_membership(
  p_company_id uuid,
  p_assortment_id uuid,
  p_product_ids uuid[],
  p_included boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_requested integer;
  v_valid integer;
  v_updated integer;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_assortments') then
    raise exception 'No autorizado para configurar surtidos.';
  end if;

  perform 1 from public.sales_assortments
  where id = p_assortment_id and company_id = p_company_id
  for update;
  if not found then raise exception 'Surtido no encontrado.'; end if;

  select count(distinct product_id) into v_requested
  from unnest(coalesce(p_product_ids, '{}'::uuid[])) requested(product_id)
  where product_id is not null;
  if v_requested = 0 then raise exception 'Selecciona al menos un producto.'; end if;

  select count(*) into v_valid
  from public.products product
  where product.company_id = p_company_id
    and product.id = any(p_product_ids);
  if v_valid <> v_requested then raise exception 'La selección contiene productos inválidos.'; end if;

  perform set_config('satrapy.bulk_assortment', 'on', true);

  if p_included then
    insert into public.sales_assortment_items (assortment_id, product_id, created_by)
    select p_assortment_id, product.id, auth.uid()
    from public.products product
    where product.company_id = p_company_id and product.id = any(p_product_ids)
    on conflict do nothing;
    get diagnostics v_updated = row_count;
  else
    delete from public.sales_assortment_items item
    where item.assortment_id = p_assortment_id
      and item.product_id = any(p_product_ids);
    get diagnostics v_updated = row_count;
  end if;

  perform set_config('satrapy.bulk_assortment', 'off', true);

  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values (
    p_company_id,
    auth.uid(),
    case when p_included then 'sales_assortment.members_added' else 'sales_assortment.members_removed' end,
    'sales_assortments',
    p_assortment_id,
    jsonb_build_object('requested', v_requested, 'updated', v_updated, 'product_ids', to_jsonb(p_product_ids))
  );

  return jsonb_build_object('updated', coalesce(v_updated, 0), 'included', p_included);
exception when others then
  perform set_config('satrapy.bulk_assortment', 'off', true);
  raise;
end;
$$;

revoke all on function public.list_sales_assortment_membership(uuid, uuid, text, text, integer, integer) from public;
revoke all on function public.set_sales_assortment_membership(uuid, uuid, uuid[], boolean) from public;
grant execute on function public.list_sales_assortment_membership(uuid, uuid, text, text, integer, integer) to authenticated;
grant execute on function public.set_sales_assortment_membership(uuid, uuid, uuid[], boolean) to authenticated;
