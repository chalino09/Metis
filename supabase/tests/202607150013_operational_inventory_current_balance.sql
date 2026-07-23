-- Current inventory must come from inventory_balances; snapshots are reference only.
begin;

create temporary table inventory_current_context (
  company_id uuid,
  allowed_location_id uuid,
  denied_location_id uuid,
  user_id uuid
);

do $fixtures$
declare
  v_company uuid := '15130000-0000-4000-8000-000000000001';
  v_allowed_location uuid := '15130000-0000-4000-8000-000000000002';
  v_denied_location uuid := '15130000-0000-4000-8000-000000000003';
  v_product uuid := '15130000-0000-4000-8000-000000000004';
  v_snapshot uuid := '15130000-0000-4000-8000-000000000005';
  v_user uuid := '15130000-0000-4000-8000-000000000006';
  v_actor uuid;
begin
  select assignment.user_id into v_actor
  from public.user_roles assignment
  join public.roles role_data on role_data.id = assignment.role_id
  where role_data.code = 'super_admin'
  limit 1;
  if v_actor is null then raise exception 'La prueba requiere un Super Admin existente.'; end if;

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    'inventory-current@example.invalid', '', now(), '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb, now(), now());

  insert into public.companies(id, legal_name, display_name)
  values (v_company, 'Inventario vigente temporal', 'Inventario vigente temporal');
  insert into public.locations(id, company_id, external_code, name, location_type, classification_source)
  values
    (v_allowed_location, v_company, 'INV-A', 'Ubicación permitida', 'sucursal', 'manual_review'),
    (v_denied_location, v_company, 'INV-B', 'Ubicación no permitida', 'sucursal', 'manual_review');
  insert into public.products(id, company_id, alpha_sku, internal_sku, name, unit, is_inventory_tracked)
  values (v_product, v_company, 'ALPHA-INV-1', 'INV-1', 'Producto inventario vigente', 'PZA', true);

  insert into public.inventory_snapshots(id, company_id, source_file_name, snapshot_date, status, created_by)
  values (v_snapshot, v_company, 'snapshot-reference.xlsx', date '2026-07-07', 'completed', v_actor);
  insert into public.inventory_snapshot_items(id, snapshot_id, product_id, location_id, quantity, unit,
    physical_quantity, available_quantity, source_file_name, source_alpha_sku)
  values
    ('15130000-0000-4000-8000-000000000007', v_snapshot, v_product, v_allowed_location, 5, 'PZA', 5, 5, 'snapshot-reference.xlsx', 'ALPHA-INV-1'),
    ('15130000-0000-4000-8000-000000000008', v_snapshot, v_product, v_denied_location, 9, 'PZA', 9, 9, 'snapshot-reference.xlsx', 'ALPHA-INV-1');

  insert into public.inventory_balances(company_id, location_id, product_id, quantity_on_hand)
  values (v_company, v_allowed_location, v_product, 3), (v_company, v_denied_location, v_product, 9);
  insert into public.inventory_ledger(company_id, location_id, product_id, quantity_delta, balance_after, movement_type, actor_id)
  values (v_company, v_allowed_location, v_product, -2, 3, 'controlled_adjustment', v_actor);

  insert into public.user_roles(user_id, role_id, company_id)
  select v_user, id, v_company from public.roles where code = 'sucursal';
  insert into public.user_location_access(user_id, location_id) values (v_user, v_allowed_location);
  insert into inventory_current_context values (v_company, v_allowed_location, v_denied_location, v_user);
end;
$fixtures$;

grant select on inventory_current_context to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', user_id::text, true) from inventory_current_context;

do $assertions$
declare
  v_company uuid;
  v_allowed_location uuid;
  v_denied_location uuid;
  v_result jsonb;
  v_item jsonb;
  v_denied boolean := false;
begin
  if not exists (select 1 from public.permissions where code = 'view_inventory') then
    raise exception 'Falta el permiso view_inventory.';
  end if;
  if to_regprocedure('public.search_inventory_balances(uuid,uuid,text,integer,integer)') is null then
    raise exception 'Falta la RPC search_inventory_balances.';
  end if;
  if to_regprocedure('public.search_inventory_balances_operational(uuid,uuid,text,integer,integer)') is null
    or to_regprocedure('public.get_inventory_snapshot_reference(uuid,uuid,uuid)') is null then
    raise exception 'Faltan las RPCs rápidas de existencia y referencia.';
  end if;
  if has_function_privilege('anon', 'public.search_inventory_balances(uuid,uuid,text,integer,integer)', 'execute') then
    raise exception 'anon no debe ejecutar search_inventory_balances.';
  end if;

  select company_id, allowed_location_id, denied_location_id
  into v_company, v_allowed_location, v_denied_location
  from inventory_current_context;

  v_result := public.search_inventory_balances_operational(v_company, null, 'INV-1', 1, 50);
  if (v_result ->> 'total')::integer <> 1 then
    raise exception 'La RPC no respetó búsqueda o alcance por ubicación: %', v_result;
  end if;
  v_item := v_result -> 'items' -> 0;
  if (v_item ->> 'quantity_on_hand')::numeric <> 3
    or v_item ->> 'last_movement_type' <> 'controlled_adjustment'
    or not (v_item ->> 'has_snapshot_reference')::boolean
    or v_item -> 'snapshot_quantity' <> 'null'::jsonb then
    raise exception 'La lista operativa mezcló o perdió información: %', v_item;
  end if;

  v_result := public.get_inventory_snapshot_reference(v_company, v_allowed_location, '15130000-0000-4000-8000-000000000004');
  if not (v_result ->> 'available')::boolean
    or (v_result ->> 'snapshot_quantity')::numeric <> 5
    or (v_result ->> 'difference_from_snapshot')::numeric <> -2
    or v_result ->> 'snapshot_source_file' <> 'snapshot-reference.xlsx' then
    raise exception 'La referencia bajo demanda es incorrecta: %', v_result;
  end if;

  begin
    perform public.search_inventory_balances_operational(v_company, v_denied_location, null, 1, 50);
  exception when others then
    v_denied := true;
  end;
  if not v_denied then raise exception 'La RPC permitió consultar una ubicación no asignada.'; end if;
end;
$assertions$;

reset role;
rollback;
