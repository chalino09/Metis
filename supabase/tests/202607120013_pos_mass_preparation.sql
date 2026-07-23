-- Satrapy · POS mass preparation tests.
-- Run after migration 202607120013. All fixtures are rolled back.
begin;

do $fixtures$
declare
  v_actor_id uuid;
begin
  select user_role.user_id into v_actor_id
  from public.user_roles user_role
  join public.roles role_data on role_data.id = user_role.role_id
  where role_data.code = 'super_admin'
  limit 1;

  if v_actor_id is null then
    raise exception 'Las pruebas POS requieren un Super Admin existente.';
  end if;
  perform set_config('app.pos_mass_test_actor', v_actor_id::text, true);

  insert into public.companies (id, legal_name, display_name)
  values
    ('13000000-0000-4000-8000-000000000001', 'Empresa temporal POS', 'Empresa temporal POS'),
    ('13000000-0000-4000-8000-000000000002', 'Otra empresa temporal', 'Otra empresa temporal');

  insert into public.units_of_measure (id, company_id, code, name)
  values (
    '13000000-0000-4000-8000-000000000401',
    '13000000-0000-4000-8000-000000000001',
    'PZA',
    'Pieza'
  );

  insert into public.tax_categories (id, company_id, code, name)
  values (
    '13000000-0000-4000-8000-000000000501',
    '13000000-0000-4000-8000-000000000001',
    'IVA16',
    'IVA 16%'
  );

  insert into public.tax_rates (tax_category_id, jurisdiction_code, rate, valid_from, created_by)
  values (
    '13000000-0000-4000-8000-000000000501',
    'MX',
    .16,
    now() - interval '1 day',
    v_actor_id
  );

  insert into public.products (
    id, company_id, alpha_sku, name, unit, is_active, is_sellable,
    is_inventory_tracked, sales_unit_id, tax_category_id,
    commercial_review_required, product_type
  ) values
    (
      '13000000-0000-4000-8000-000000000101',
      '13000000-0000-4000-8000-000000000001',
      'T013-READY',
      'Producto listo temporal',
      'PZA', true, true, true,
      '13000000-0000-4000-8000-000000000401',
      '13000000-0000-4000-8000-000000000501',
      false,
      'P. Terminado'
    ),
    (
      '13000000-0000-4000-8000-000000000102',
      '13000000-0000-4000-8000-000000000001',
      'T013-PENDING',
      'Producto pendiente temporal',
      'PZA', true, true, true,
      '13000000-0000-4000-8000-000000000401',
      null,
      false,
      'P. Terminado'
    );

  insert into public.product_external_references (
    company_id, product_id, source_system, external_code, is_primary
  ) values
    (
      '13000000-0000-4000-8000-000000000001',
      '13000000-0000-4000-8000-000000000101',
      'csv_satrapy',
      'T013-STD-READY',
      true
    ),
    (
      '13000000-0000-4000-8000-000000000001',
      '13000000-0000-4000-8000-000000000102',
      'csv_satrapy',
      'T013-STD-PENDING',
      true
    );

  insert into public.price_lists (
    id, company_id, external_code, name, currency_code, is_active, status, is_default
  ) values (
    '13000000-0000-4000-8000-000000000601',
    '13000000-0000-4000-8000-000000000001',
    'T013-LISTA',
    'Lista temporal',
    'MXN',
    true,
    'active',
    true
  );

  insert into public.product_prices (
    product_id, price_list_id, amount, currency_code, valid_from, created_by
  ) values
    (
      '13000000-0000-4000-8000-000000000101',
      '13000000-0000-4000-8000-000000000601',
      100,
      'MXN',
      now() - interval '1 day',
      v_actor_id
    ),
    (
      '13000000-0000-4000-8000-000000000102',
      '13000000-0000-4000-8000-000000000601',
      100,
      'MXN',
      now() - interval '1 day',
      v_actor_id
    );

  insert into public.locations (
    id, company_id, external_code, name, location_type, classification_source
  ) values
    (
      '13000000-0000-4000-8000-000000000201',
      '13000000-0000-4000-8000-000000000001',
      'T013-SUC-1',
      'Sucursal temporal uno',
      'sucursal',
      'manual_review'
    ),
    (
      '13000000-0000-4000-8000-000000000202',
      '13000000-0000-4000-8000-000000000001',
      'T013-SUC-2',
      'Sucursal temporal dos',
      'sucursal',
      'manual_review'
    ),
    (
      '13000000-0000-4000-8000-000000000203',
      '13000000-0000-4000-8000-000000000001',
      'T013-ALM',
      'Almacen temporal',
      'almacen_operativo',
      'manual_review'
    ),
    (
      '13000000-0000-4000-8000-000000000204',
      '13000000-0000-4000-8000-000000000002',
      'T013-OTRA',
      'Sucursal de otra empresa',
      'sucursal',
      'manual_review'
    );
end;
$fixtures$;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config(
  'request.jwt.claim.sub',
  current_setting('app.pos_mass_test_actor', true),
  true
);

do $initial_assertions$
declare
  v_result jsonb;
  v_list jsonb;
  v_search jsonb;
  v_assortment_id uuid;
  v_count integer;
begin
  v_result := public.prepare_pos_pilot(
    '13000000-0000-4000-8000-000000000001',
    'T013-PILOTO',
    'Piloto temporal',
    array[
      '13000000-0000-4000-8000-000000000201'::uuid,
      '13000000-0000-4000-8000-000000000202'::uuid
    ]
  );

  v_assortment_id := (v_result ->> 'assortment_id')::uuid;
  if (v_result ->> 'products_processed')::integer <> 2
    or (v_result ->> 'ready')::integer <> 1
    or (v_result ->> 'pending')::integer <> 1
    or (v_result ->> 'locations_assigned')::integer <> 2 then
    raise exception 'La preparación masiva devolvió un resumen incorrecto: %', v_result;
  end if;

  select count(*) into v_count
  from public.sales_assortment_items
  where assortment_id = v_assortment_id;
  if v_count <> 2 then
    raise exception 'El surtido no conservó productos listos y pendientes.';
  end if;

  update public.sales_assortments
  set status = 'active'
  where id = v_assortment_id;

  v_list := public.list_pos_assortment_readiness(
    '13000000-0000-4000-8000-000000000001',
    v_assortment_id,
    null,
    null,
    1,
    50
  );
  if (v_list -> 'summary' ->> 'ready')::integer <> 1
    or (v_list -> 'summary' ->> 'pending')::integer <> 1 then
    raise exception 'La lista no separó listo y pendiente: %', v_list;
  end if;

  v_search := public.search_pos_products(
    '13000000-0000-4000-8000-000000000001',
    '13000000-0000-4000-8000-000000000201',
    'T013-STD-READY'
  );
  if (v_search ->> 'total')::integer <> 1 then
    raise exception 'El POS no encontró el producto listo: %', v_search;
  end if;

  v_search := public.search_pos_products(
    '13000000-0000-4000-8000-000000000001',
    '13000000-0000-4000-8000-000000000201',
    'T013-STD-PENDING'
  );
  if (v_search ->> 'total')::integer <> 0 then
    raise exception 'El POS mostró un producto pendiente: %', v_search;
  end if;

  begin
    perform public.prepare_pos_pilot(
      '13000000-0000-4000-8000-000000000001',
      'T013-INVALIDO',
      'Piloto inválido',
      array['13000000-0000-4000-8000-000000000204'::uuid]
    );
    raise exception 'Se aceptó una sucursal de otra empresa.';
  exception when others then
    if sqlerrm not like '%sucursales activas de la empresa%' then raise; end if;
  end;

  if exists (
    select 1 from public.sales_assortments
    where company_id = '13000000-0000-4000-8000-000000000001'
      and code = 'T013-INVALIDO'
  ) then
    raise exception 'La preparación inválida dejó datos parciales.';
  end if;

  if not exists (
    select 1 from public.audit_log
    where company_id = '13000000-0000-4000-8000-000000000001'
      and entity_id = v_assortment_id
      and action = 'sales_assortment.prepared'
      and actor_id = auth.uid()
  ) then
    raise exception 'La preparación masiva no quedó auditada con actor.';
  end if;
end;
$initial_assertions$;

reset role;

-- Simulate a ready product losing a current requirement as the database owner.
update public.products
set tax_category_id = null
where id = '13000000-0000-4000-8000-000000000101';

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config(
  'request.jwt.claim.sub',
  current_setting('app.pos_mass_test_actor', true),
  true
);

do $lost_readiness_assertions$
declare
  v_assortment_id uuid;
  v_validation jsonb;
begin
  select id into v_assortment_id
  from public.sales_assortments
  where company_id = '13000000-0000-4000-8000-000000000001'
    and code = 'T013-PILOTO';

  if not exists (
    select 1 from public.sales_assortment_items
    where assortment_id = v_assortment_id
      and product_id = '13000000-0000-4000-8000-000000000101'
  ) then
    raise exception 'El producto perdió su membresía comercial al perder readiness.';
  end if;

  v_validation := public.validate_pos_product_for_location(
    '13000000-0000-4000-8000-000000000001',
    '13000000-0000-4000-8000-000000000201',
    '13000000-0000-4000-8000-000000000101'
  );
  if coalesce((v_validation ->> 'in_active_assortment')::boolean, false) is not true
    or coalesce((v_validation ->> 'allowed')::boolean, true) is not false then
    raise exception 'Readiness no bloqueó la venta conservando el surtido: %', v_validation;
  end if;
end;
$lost_readiness_assertions$;

reset role;

-- Restore readiness and add a newly imported sellable product.
update public.products
set tax_category_id = '13000000-0000-4000-8000-000000000501'
where id = '13000000-0000-4000-8000-000000000101';

insert into public.products (
  id, company_id, alpha_sku, name, unit, is_active, is_sellable,
  is_inventory_tracked, sales_unit_id, tax_category_id,
  commercial_review_required, product_type
) values (
  '13000000-0000-4000-8000-000000000103',
  '13000000-0000-4000-8000-000000000001',
  'T013-NEW',
  'Producto nuevo temporal',
  'PZA', true, true, true,
  '13000000-0000-4000-8000-000000000401',
  '13000000-0000-4000-8000-000000000501',
  false,
  'P. Terminado'
);

insert into public.product_prices (
  product_id, price_list_id, amount, currency_code, valid_from
) values (
  '13000000-0000-4000-8000-000000000103',
  '13000000-0000-4000-8000-000000000601',
  120,
  'MXN',
  now() - interval '1 day'
);

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config(
  'request.jwt.claim.sub',
  current_setting('app.pos_mass_test_actor', true),
  true
);

do $refresh_assertions$
declare
  v_assortment_id uuid;
  v_result jsonb;
  v_search jsonb;
begin
  select id into v_assortment_id
  from public.sales_assortments
  where company_id = '13000000-0000-4000-8000-000000000001'
    and code = 'T013-PILOTO';

  v_result := public.refresh_pos_assortment_catalog(
    '13000000-0000-4000-8000-000000000001',
    v_assortment_id
  );
  if (v_result ->> 'products_added')::integer <> 1 then
    raise exception 'Actualizar catálogo no agregó solo el producto nuevo: %', v_result;
  end if;

  v_search := public.search_pos_products(
    '13000000-0000-4000-8000-000000000001',
    '13000000-0000-4000-8000-000000000201',
    'T013-STD-READY'
  );
  if (v_search ->> 'total')::integer <> 1 then
    raise exception 'El producto no volvió automáticamente al POS al recuperar readiness: %', v_search;
  end if;

  if not exists (
    select 1 from public.audit_log
    where company_id = '13000000-0000-4000-8000-000000000001'
      and entity_id = v_assortment_id
      and action = 'sales_assortment.catalog_refreshed'
      and actor_id = auth.uid()
  ) then
    raise exception 'Actualizar catálogo no quedó auditado con actor.';
  end if;
end;
$refresh_assertions$;

reset role;
rollback;
