create or replace function public.prepare_pos_operation(
  p_company_id uuid,
  p_code text,
  p_name text,
  p_location_ids uuid[],
  p_at timestamptz default now()
)
returns jsonb
language sql security definer set search_path = public
as $$
  select public.prepare_pos_pilot(p_company_id, p_code, p_name, p_location_ids, p_at);
$$;

create or replace function public.get_pos_readiness_blocker_summary(
  p_company_id uuid,
  p_assortment_id uuid,
  p_at timestamptz default now()
)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_pos_readiness') then
    raise exception 'No autorizado para consultar la preparación POS.';
  end if;
  if not exists (select 1 from public.sales_assortments where id = p_assortment_id and company_id = p_company_id) then
    raise exception 'Surtido no encontrado.';
  end if;

  with catalog as materialized (
    select p.id, p.is_inventory_tracked, readiness -> 'blockers' blockers
    from public.sales_assortment_items i
    join public.products p on p.id = i.product_id and p.company_id = p_company_id
    cross join lateral public.product_pos_readiness_detail(p_company_id, p.id, null, p_at) readiness
    where i.assortment_id = p_assortment_id
  ), blocker_counts as (
    select
      count(distinct id) filter (where code = 'missing_or_zero_price') price,
      count(distinct id) filter (where code in ('missing_tax_category','missing_current_tax_rate')) tax,
      count(distinct id) filter (where code = 'missing_sales_unit') unit,
      count(distinct id) filter (where code in ('inactive','not_sellable','commercial_review_required')) state
    from catalog cross join lateral jsonb_array_elements_text(blockers) blocker(code)
  ), inventory_count as (
    select count(*) count
    from catalog c
    join public.location_sales_assortments assignment on assignment.assortment_id = p_assortment_id and assignment.valid_to is null
    left join public.inventory_balances balance on balance.location_id = assignment.location_id and balance.product_id = c.id
    where c.is_inventory_tracked and coalesce(balance.quantity_on_hand, 0) <= 0
  )
  select jsonb_build_object(
    'price', coalesce(b.price, 0),
    'tax', coalesce(b.tax, 0),
    'unit', coalesce(b.unit, 0),
    'state', coalesce(b.state, 0),
    'inventory', coalesce(i.count, 0)
  ) into v_result from blocker_counts b cross join inventory_count i;
  return coalesce(v_result, jsonb_build_object('price',0,'tax',0,'unit',0,'state',0,'inventory',0));
end $$;

create or replace function public.bulk_assign_product_sales_unit(
  p_company_id uuid,
  p_product_ids uuid[],
  p_sales_unit_id uuid
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_requested integer; v_updated integer;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_products') then raise exception 'No autorizado.'; end if;
  v_requested := cardinality(p_product_ids);
  if coalesce(v_requested, 0) = 0 or v_requested <> (select count(distinct id) from unnest(p_product_ids) id) then raise exception 'La selección es vacía o contiene duplicados.'; end if;
  if not exists (select 1 from public.units_of_measure where id = p_sales_unit_id and company_id = p_company_id and is_active) then raise exception 'Unidad de venta inválida.'; end if;
  if v_requested <> (select count(*) from public.products where company_id = p_company_id and id = any(p_product_ids)) then raise exception 'La selección contiene productos inválidos.'; end if;
  update public.products set sales_unit_id = p_sales_unit_id, updated_at = now() where company_id = p_company_id and id = any(p_product_ids);
  get diagnostics v_updated = row_count;
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata) values(p_company_id,auth.uid(),'products.sales_unit_bulk_assigned','products',jsonb_build_object('count',v_updated,'product_ids',p_product_ids,'sales_unit_id',p_sales_unit_id));
  return jsonb_build_object('updated',v_updated);
end $$;

create or replace function public.bulk_assign_product_tax_category(
  p_company_id uuid,
  p_product_ids uuid[],
  p_tax_category_id uuid
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_requested integer; v_updated integer;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_products') then raise exception 'No autorizado.'; end if;
  v_requested := cardinality(p_product_ids);
  if coalesce(v_requested, 0) = 0 or v_requested <> (select count(distinct id) from unnest(p_product_ids) id) then raise exception 'La selección es vacía o contiene duplicados.'; end if;
  if not exists (select 1 from public.tax_categories where id = p_tax_category_id and company_id = p_company_id and is_active) then raise exception 'Categoría fiscal inválida.'; end if;
  if v_requested <> (select count(*) from public.products where company_id = p_company_id and id = any(p_product_ids)) then raise exception 'La selección contiene productos inválidos.'; end if;
  update public.products set tax_category_id = p_tax_category_id, updated_at = now() where company_id = p_company_id and id = any(p_product_ids);
  get diagnostics v_updated = row_count;
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata) values(p_company_id,auth.uid(),'products.tax_category_bulk_assigned','products',jsonb_build_object('count',v_updated,'product_ids',p_product_ids,'tax_category_id',p_tax_category_id));
  return jsonb_build_object('updated',v_updated);
end $$;

create or replace function public.bulk_mark_products_sellable(
  p_company_id uuid,
  p_product_ids uuid[]
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_requested integer; v_eligible integer; v_updated integer;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_products') then raise exception 'No autorizado.'; end if;
  v_requested := cardinality(p_product_ids);
  if coalesce(v_requested, 0) = 0 or v_requested <> (select count(distinct id) from unnest(p_product_ids) id) then raise exception 'La selección es vacía o contiene duplicados.'; end if;
  select count(*) into v_eligible from public.products where company_id = p_company_id and id = any(p_product_ids) and is_active and not commercial_review_required;
  if v_eligible <> v_requested then raise exception 'Solo pueden marcarse como vendibles productos activos y con clasificación resuelta. Corrige los inactivos o no clasificados individualmente.'; end if;
  update public.products set is_sellable = true, updated_at = now() where company_id = p_company_id and id = any(p_product_ids) and is_active and not commercial_review_required;
  get diagnostics v_updated = row_count;
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata) values(p_company_id,auth.uid(),'products.sellable_bulk_enabled','products',jsonb_build_object('count',v_updated,'product_ids',p_product_ids,'operational_consequence','Los productos podrán aparecer en POS cuando cumplan el resto del readiness.'));
  return jsonb_build_object('updated',v_updated);
end $$;

grant execute on function public.prepare_pos_operation(uuid,text,text,uuid[],timestamptz) to authenticated;
grant execute on function public.get_pos_readiness_blocker_summary(uuid,uuid,timestamptz) to authenticated;
grant execute on function public.bulk_assign_product_sales_unit(uuid,uuid[],uuid) to authenticated;
grant execute on function public.bulk_assign_product_tax_category(uuid,uuid[],uuid) to authenticated;
grant execute on function public.bulk_mark_products_sellable(uuid,uuid[]) to authenticated;
