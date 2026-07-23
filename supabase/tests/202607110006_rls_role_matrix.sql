-- Satrapy · Task 2.5 real RLS execution matrix.
-- Temporary auth identities and fixtures are always rolled back.
begin;

create temporary table t25_context (
  company_id uuid, batch_id uuid, direccion_id uuid, sucursal_id uuid,
  ingeniero_id uuid, almacen_id uuid, pos_id uuid
);

do $fixtures$
declare
  v_company uuid := gen_random_uuid();
  v_location_a uuid;
  v_location_b uuid;
  v_product uuid;
  v_snapshot uuid;
  v_batch uuid;
  v_actor uuid;
  v_direccion uuid := gen_random_uuid();
  v_sucursal uuid := gen_random_uuid();
  v_ingeniero uuid := gen_random_uuid();
  v_almacen uuid := gen_random_uuid();
  v_pos uuid := gen_random_uuid();
  v_user uuid;
begin
  select ur.user_id into v_actor from public.user_roles ur
  join public.roles role_data on role_data.id = ur.role_id
  where role_data.code = 'super_admin' limit 1;
  if v_actor is null then raise exception 'La matriz RLS requiere un Super Admin existente.'; end if;

  foreach v_user in array array[v_direccion, v_sucursal, v_ingeniero, v_almacen, v_pos] loop
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
      't25-' || v_user || '@example.invalid', '', now(), '{"provider":"email","providers":["email"]}'::jsonb,
      '{}'::jsonb, now(), now());
  end loop;

  insert into public.companies (id, legal_name, display_name)
  values (v_company, 'T25 RLS temporal', 'T25 RLS temporal');
  insert into public.locations (company_id, external_code, name, location_type, classification_source)
  values (v_company, 'T25-LA', 'Sucursal temporal', 'sucursal', 'manual_review') returning id into v_location_a;
  insert into public.locations (company_id, external_code, name, location_type, classification_source)
  values (v_company, 'T25-LB', 'Campo temporal', 'campo', 'manual_review') returning id into v_location_b;
  insert into public.products (company_id, alpha_sku, name, unit)
  values (v_company, 'T25-RLS', 'Producto RLS temporal', 'PZA') returning id into v_product;

  insert into public.import_batches (company_id, import_type, source, file_sha256, status, records_received,
    imported_by, snapshot_date, valid_rows, last_activity_at)
  values (v_company, 'inventory', 'manual_upload', encode(gen_random_bytes(32), 'hex'), 'staged', 1,
    v_actor, date '2026-07-07', 1, now()) returning id into v_batch;
  insert into public.import_files (import_batch_id, original_name, file_type, file_sha256, row_count)
  select v_batch, 'reexic2_t25_rls.XLS', 'xls', file_sha256, 1 from public.import_batches where id = v_batch;
  insert into public.import_staging_rows (import_batch_id, row_number, source_file, detected_type, raw_data,
    normalized_data, validation_status)
  values (v_batch, 9, 'reexic2_t25_rls.XLS', 'inventory', '{"cells":["T25-RLS"]}',
    '{"alphaSku":"T25-RLS","quantity":1,"locationCode":"T25-LA","locationType":"sucursal"}', 'valid');

  insert into public.inventory_snapshots (company_id, import_batch_id, source_file_name, snapshot_date, status, created_by)
  values (v_company, null, 'reexic2_t25_rls.XLS', date '2026-07-07', 'completed', v_actor) returning id into v_snapshot;
  insert into public.inventory_snapshot_items (snapshot_id, product_id, location_id, quantity, unit,
    physical_quantity, available_quantity, import_batch_id, source_file_name, source_alpha_sku)
  values
    (v_snapshot, v_product, v_location_a, 3, 'PZA', 3, 3, null, 'reexic2_t25_rls.XLS', 'T25-RLS'),
    (v_snapshot, v_product, v_location_b, 4, 'PZA', 4, 0, null, 'reexic2_t25_rls.XLS', 'T25-RLS');

  insert into public.user_roles (user_id, role_id, company_id)
  select v_direccion, id, v_company from public.roles where code = 'direccion_admin'
  union all select v_sucursal, id, v_company from public.roles where code = 'sucursal'
  union all select v_ingeniero, id, v_company from public.roles where code = 'ingeniero_campo'
  union all select v_almacen, id, v_company from public.roles where code = 'almacen'
  union all select v_pos, id, v_company from public.roles where code = 'punto_venta';
  insert into public.user_location_access (user_id, location_id)
  values (v_sucursal, v_location_a), (v_ingeniero, v_location_b), (v_pos, v_location_a);

  insert into t25_context values (v_company, v_batch, v_direccion, v_sucursal, v_ingeniero, v_almacen, v_pos);
end;
$fixtures$;
grant select on t25_context to authenticated;

create or replace function public.t25_assert_rls(
  p_user_id uuid, p_company_id uuid, p_batch_id uuid, p_expected_inventory integer,
  p_can_import boolean, p_role_name text, p_cost_must_be_hidden boolean default false
) returns void
language plpgsql
security invoker
set search_path = public
as $test$
declare
  v_inventory integer;
  v_products integer;
  v_batches integer;
  v_rpc_denied boolean := false;
  v_cost_denied boolean := false;
begin
  if auth.uid() <> p_user_id then raise exception '%: JWT de prueba incorrecto.', p_role_name; end if;
  select count(*) into v_products from public.products where company_id = p_company_id;
  select count(*) into v_inventory from public.inventory_snapshot_items;
  select count(*) into v_batches from public.import_batches where id = p_batch_id;
  if v_products <> 1 then raise exception '%: no puede ver Productos de su empresa.', p_role_name; end if;
  if v_inventory <> p_expected_inventory then
    raise exception '%: RLS devolvió % items; se esperaban %.', p_role_name, v_inventory, p_expected_inventory;
  end if;
  if v_batches <> (case when p_can_import then 1 else 0 end) then
    raise exception '%: acceso incorrecto a import_batches.', p_role_name;
  end if;
  begin
    perform public.get_import_staging_preview(p_batch_id, 1, 50, null, null);
  exception when others then v_rpc_denied := true;
  end;
  if p_can_import = v_rpc_denied then raise exception '%: permiso RPC de staging incorrecto.', p_role_name; end if;
  if p_cost_must_be_hidden then
    begin
      execute 'select average_cost from public.inventory_snapshot_items limit 1';
    exception when insufficient_privilege then v_cost_denied := true;
    end;
    if not v_cost_denied then raise exception '%: pudo consultar costos sensibles.', p_role_name; end if;
  end if;
end;
$test$;
grant execute on function public.t25_assert_rls(uuid, uuid, uuid, integer, boolean, text, boolean) to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);

select set_config('request.jwt.claim.sub', direccion_id::text, true) from t25_context;
select public.t25_assert_rls(direccion_id, company_id, batch_id, 2, true, 'Dirección/Admin', false) from t25_context;
select set_config('request.jwt.claim.sub', sucursal_id::text, true) from t25_context;
select public.t25_assert_rls(sucursal_id, company_id, batch_id, 1, false, 'Sucursal', false) from t25_context;
select set_config('request.jwt.claim.sub', ingeniero_id::text, true) from t25_context;
select public.t25_assert_rls(ingeniero_id, company_id, batch_id, 1, false, 'Ingeniero de Campo', false) from t25_context;
select set_config('request.jwt.claim.sub', almacen_id::text, true) from t25_context;
select public.t25_assert_rls(almacen_id, company_id, batch_id, 2, false, 'Almacén', false) from t25_context;
select set_config('request.jwt.claim.sub', pos_id::text, true) from t25_context;
select public.t25_assert_rls(pos_id, company_id, batch_id, 1, false, 'Punto de Venta', true) from t25_context;

reset role;
rollback;
