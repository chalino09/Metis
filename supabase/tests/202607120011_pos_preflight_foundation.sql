-- Satrapy · POS preflight foundation tests.
-- Run after migrations 202607120011 and 202607120012.
-- The fixtures use reserved UUIDs and the entire test is rolled back.
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
  perform set_config('app.pos_preflight_test_actor', v_actor_id::text, true);

  insert into public.companies (id, legal_name, display_name)
  values
    ('11000000-0000-4000-8000-000000000001', 'T011 POS temporal', 'T011 POS temporal'),
    ('11000000-0000-4000-8000-000000000002', 'T011 Otra empresa', 'T011 Otra empresa');

  insert into public.units_of_measure (id, company_id, code, name)
  values (
    '11000000-0000-4000-8000-000000000401',
    '11000000-0000-4000-8000-000000000001',
    'PZA',
    'Pieza'
  );

  insert into public.tax_categories (id, company_id, code, name)
  values (
    '11000000-0000-4000-8000-000000000501',
    '11000000-0000-4000-8000-000000000001',
    'IVA16',
    'IVA 16%'
  );

  insert into public.tax_rates (tax_category_id, jurisdiction_code, rate, valid_from, created_by)
  values (
    '11000000-0000-4000-8000-000000000501',
    'MX',
    .16,
    now() - interval '1 day',
    v_actor_id
  );

  -- Product that must be ready and sellable through the pilot assortment.
  insert into public.products (
    id, company_id, alpha_sku, name, unit, is_active, is_sellable,
    is_inventory_tracked, sales_unit_id, tax_category_id,
    commercial_review_required, product_type
  ) values (
    '11000000-0000-4000-8000-000000000101',
    '11000000-0000-4000-8000-000000000001',
    'T011-ALPHA-001',
    'Producto temporal POS',
    'PZA',
    true,
    true,
    true,
    '11000000-0000-4000-8000-000000000401',
    '11000000-0000-4000-8000-000000000501',
    false,
    'P. Terminado'
  );

  -- Product intentionally blocked only because its tax category is missing.
  insert into public.products (
    id, company_id, alpha_sku, name, unit, is_active, is_sellable,
    is_inventory_tracked, sales_unit_id, tax_category_id,
    commercial_review_required, product_type
  ) values (
    '11000000-0000-4000-8000-000000000102',
    '11000000-0000-4000-8000-000000000001',
    'T011-ALPHA-002',
    'Producto temporal sin impuesto',
    'PZA',
    true,
    true,
    true,
    '11000000-0000-4000-8000-000000000401',
    null,
    false,
    'P. Terminado'
  );

  insert into public.product_external_references (
    company_id, product_id, source_system, external_code, is_primary
  ) values
    (
      '11000000-0000-4000-8000-000000000001',
      '11000000-0000-4000-8000-000000000101',
      'alpha',
      'T011-ALPHA-001',
      true
    ),
    (
      '11000000-0000-4000-8000-000000000001',
      '11000000-0000-4000-8000-000000000101',
      'csv_satrapy',
      'T011-STD-001',
      true
    );

  begin
    insert into public.product_external_references (
      company_id, product_id, source_system, external_code
    ) values (
      '11000000-0000-4000-8000-000000000001',
      '11000000-0000-4000-8000-000000000101',
      'alpha',
      'T011-ALPHA-001'
    );
    raise exception 'La referencia externa duplicada no fue bloqueada.';
  exception when unique_violation then
    null;
  end;

  begin
    insert into public.product_external_references (
      company_id, product_id, source_system, external_code
    ) values (
      '11000000-0000-4000-8000-000000000002',
      '11000000-0000-4000-8000-000000000101',
      'alpha',
      'T011-OTRA'
    );
    raise exception 'Se aceptó una referencia de otra empresa.';
  exception when others then
    if sqlerrm not like '%misma empresa%' then
      raise;
    end if;
  end;

  insert into public.price_lists (
    id, company_id, external_code, name, currency_code,
    is_active, status, is_default
  ) values (
    '11000000-0000-4000-8000-000000000601',
    '11000000-0000-4000-8000-000000000001',
    'T011-LISTA',
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
      '11000000-0000-4000-8000-000000000101',
      '11000000-0000-4000-8000-000000000601',
      100,
      'MXN',
      now() - interval '1 day',
      v_actor_id
    ),
    (
      '11000000-0000-4000-8000-000000000102',
      '11000000-0000-4000-8000-000000000601',
      100,
      'MXN',
      now() - interval '1 day',
      v_actor_id
    );

  insert into public.locations (
    id, company_id, external_code, name, location_type, classification_source
  ) values (
    '11000000-0000-4000-8000-000000000201',
    '11000000-0000-4000-8000-000000000001',
    'T011-LOC',
    'Ubicacion temporal',
    'sucursal',
    'manual_review'
  );

  insert into public.location_external_references (
    company_id, location_id, source_system, external_code, is_primary
  ) values (
    '11000000-0000-4000-8000-000000000001',
    '11000000-0000-4000-8000-000000000201',
    'alpha',
    'T011-LOC',
    true
  );

  insert into public.sales_assortments (id, company_id, code, name, status)
  values (
    '11000000-0000-4000-8000-000000000301',
    '11000000-0000-4000-8000-000000000001',
    'T011-PILOTO',
    'Surtido temporal POS',
    'draft'
  );

  insert into public.sales_assortment_items (assortment_id, product_id)
  values (
    '11000000-0000-4000-8000-000000000301',
    '11000000-0000-4000-8000-000000000101'
  );

  insert into public.location_sales_assortments (location_id, assortment_id)
  values (
    '11000000-0000-4000-8000-000000000201',
    '11000000-0000-4000-8000-000000000301'
  );
end;
$fixtures$;

-- All security-sensitive assertions run in one authenticated-role phase.
-- There are no temporary tables and no role switching between assertions.
set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config(
  'request.jwt.claim.sub',
  current_setting('app.pos_preflight_test_actor', true),
  true
);

do $assertions$
declare
  v_readiness jsonb;
  v_blocked_readiness jsonb;
  v_validation jsonb;
  v_search jsonb;
  v_audit_count integer;
begin
  v_readiness := public.product_pos_readiness_detail(
    '11000000-0000-4000-8000-000000000001',
    '11000000-0000-4000-8000-000000000101'
  );

  if coalesce((v_readiness ->> 'pos_ready')::boolean, false) is not true then
    raise exception 'El producto configurado no quedo listo para POS: %', v_readiness;
  end if;

  update public.sales_assortments
  set status = 'active'
  where id = '11000000-0000-4000-8000-000000000301';

  v_validation := public.validate_pos_product_for_location(
    '11000000-0000-4000-8000-000000000001',
    '11000000-0000-4000-8000-000000000201',
    '11000000-0000-4000-8000-000000000101'
  );

  if coalesce((v_validation ->> 'allowed')::boolean, false) is not true then
    raise exception 'El producto no fue autorizado para su surtido y ubicacion: %', v_validation;
  end if;

  v_search := public.search_pos_products(
    '11000000-0000-4000-8000-000000000001',
    '11000000-0000-4000-8000-000000000201',
    'T011-STD-001'
  );

  if coalesce((v_search ->> 'total')::integer, 0) <> 1 then
    raise exception 'La busqueda POS no encontro la referencia externa estandar: %', v_search;
  end if;

  select count(*) into v_audit_count
  from public.audit_log
  where company_id = '11000000-0000-4000-8000-000000000001'
    and entity_type in (
      'sales_assortments',
      'sales_assortment_items',
      'location_sales_assortments'
    );

  if v_audit_count < 3 then
    raise exception 'No se registraron los cambios de surtido en auditoria.';
  end if;

  v_blocked_readiness := public.product_pos_readiness_detail(
    '11000000-0000-4000-8000-000000000001',
    '11000000-0000-4000-8000-000000000102'
  );

  if coalesce((v_blocked_readiness ->> 'pos_ready')::boolean, true) is not false
     or not coalesce(
       (v_blocked_readiness -> 'blockers') @> '["missing_tax_category"]'::jsonb,
       false
     ) then
    raise exception 'El producto sin impuesto no quedo bloqueado correctamente: %', v_blocked_readiness;
  end if;
end;
$assertions$;

reset role;
rollback;
