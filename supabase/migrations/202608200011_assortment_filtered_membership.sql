-- Satrapy · Cambios masivos de surtido por filtro
-- La operación modifica pertenencia comercial; no toca readiness, precios ni inventario.

create or replace function public.set_sales_assortment_membership_by_filter(
  p_company_id uuid,
  p_assortment_id uuid,
  p_query text default null,
  p_membership text default null,
  p_included boolean default true,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_query text := lower(trim(coalesce(p_query, '')));
  v_reason text := trim(coalesce(p_reason, ''));
  v_matched integer := 0;
  v_updated integer := 0;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_assortments') then
    raise exception 'No autorizado para configurar surtidos.';
  end if;

  if p_membership is not null and p_membership not in ('included', 'excluded') then
    raise exception 'Filtro de pertenencia inválido.';
  end if;
  if v_reason = '' then raise exception 'El motivo es obligatorio.'; end if;

  perform 1 from public.sales_assortments
  where id = p_assortment_id and company_id = p_company_id
  for update;
  if not found then raise exception 'Surtido no encontrado.'; end if;

  create temporary table if not exists assortment_filtered_products(product_id uuid primary key) on commit drop;
  truncate table assortment_filtered_products;
  insert into assortment_filtered_products(product_id)
  select product.id
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
    and (
      p_membership is null
      or (p_membership = 'included' and exists (
        select 1 from public.sales_assortment_items item
        where item.assortment_id = p_assortment_id and item.product_id = product.id
      ))
      or (p_membership = 'excluded' and not exists (
        select 1 from public.sales_assortment_items item
        where item.assortment_id = p_assortment_id and item.product_id = product.id
      ))
    );
  get diagnostics v_matched = row_count;
  if v_matched = 0 then raise exception 'No hay productos para el filtro actual.'; end if;

  perform set_config('satrapy.bulk_assortment', 'on', true);
  if p_included then
    insert into public.sales_assortment_items(assortment_id, product_id, created_by)
    select p_assortment_id, product_id, auth.uid()
    from assortment_filtered_products
    on conflict do nothing;
    get diagnostics v_updated = row_count;
  else
    delete from public.sales_assortment_items item
    using assortment_filtered_products filtered
    where item.assortment_id = p_assortment_id
      and item.product_id = filtered.product_id;
    get diagnostics v_updated = row_count;
  end if;
  perform set_config('satrapy.bulk_assortment', 'off', true);

  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values (
    p_company_id,
    auth.uid(),
    case when p_included then 'sales_assortment.filtered_members_added' else 'sales_assortment.filtered_members_removed' end,
    'sales_assortments',
    p_assortment_id,
    jsonb_build_object(
      'query', nullif(v_query, ''),
      'membership_filter', p_membership,
      'matched', v_matched,
      'updated', v_updated,
      'reason', v_reason
    )
  );

  return jsonb_build_object('matched', v_matched, 'updated', v_updated, 'included', p_included);
exception when others then
  perform set_config('satrapy.bulk_assortment', 'off', true);
  raise;
end;
$$;

revoke all on function public.set_sales_assortment_membership_by_filter(uuid, uuid, text, text, boolean, text) from public;
grant execute on function public.set_sales_assortment_membership_by_filter(uuid, uuid, text, text, boolean, text) to authenticated;
