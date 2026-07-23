-- Min/max replenishment policies: live calculation, idempotency and security.
begin;

do $installation$
begin
  if to_regclass('public.inventory_replenishment_policies') is null
    or to_regclass('public.inventory_replenishment_policy_batches') is null then
    raise exception 'Faltan las tablas de reabastecimiento.';
  end if;
  if to_regprocedure('public.configure_inventory_replenishment_policies(uuid,uuid,jsonb,uuid)') is null
    or to_regprocedure('public.configure_inventory_replenishment_policy_items(uuid,uuid,jsonb,uuid)') is null
    or to_regprocedure('public.search_inventory_replenishment_products(uuid,uuid,text,integer,integer)') is null
    or to_regprocedure('public.list_inventory_replenishment_suggestions(uuid,uuid,text,boolean,integer,integer)') is null then
    raise exception 'Faltan las RPCs de reabastecimiento.';
  end if;
  if has_table_privilege('authenticated', 'public.inventory_replenishment_policies', 'insert')
    or has_table_privilege('authenticated', 'public.inventory_replenishment_policy_batches', 'update') then
    raise exception 'authenticated no debe mutar directamente políticas de reabastecimiento.';
  end if;
  if has_function_privilege('anon', 'public.configure_inventory_replenishment_policies(uuid,uuid,jsonb,uuid)', 'execute') then
    raise exception 'anon no debe configurar reabastecimiento.';
  end if;
  if has_function_privilege('anon', 'public.configure_inventory_replenishment_policy_items(uuid,uuid,jsonb,uuid)', 'execute')
    or has_function_privilege('anon', 'public.search_inventory_replenishment_products(uuid,uuid,text,integer,integer)', 'execute') then
    raise exception 'anon no debe usar el constructor canónico de reabastecimiento.';
  end if;
  if not exists (select 1 from public.permissions where code = 'manage_inventory_replenishment') then
    raise exception 'Falta el permiso de gestión de reabastecimiento.';
  end if;
end;
$installation$;

create temporary table replenishment_context (
  company_id uuid,
  location_id uuid,
  other_location_id uuid,
  product_id uuid,
  manager_id uuid,
  viewer_id uuid
);

do $fixtures$
declare
  v_company uuid := '15160000-0000-4000-8000-000000000001';
  v_location uuid := '15160000-0000-4000-8000-000000000002';
  v_other_location uuid := '15160000-0000-4000-8000-000000000003';
  v_product uuid := '15160000-0000-4000-8000-000000000004';
  v_manager uuid := '15160000-0000-4000-8000-000000000005';
  v_viewer uuid := '15160000-0000-4000-8000-000000000006';
  v_user uuid;
begin
  foreach v_user in array array[v_manager, v_viewer] loop
    insert into auth.users(id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
      'replenishment-' || v_user || '@example.invalid', '', now(), '{"provider":"email","providers":["email"]}'::jsonb,
      '{}'::jsonb, now(), now());
  end loop;

  insert into public.companies(id, legal_name, display_name)
  values (v_company, 'Reabastecimiento temporal', 'Reabastecimiento temporal');
  insert into public.locations(id, company_id, external_code, name, location_type, classification_source)
  values
    (v_location, v_company, 'REP-01', 'Ubicación de reabastecimiento', 'almacen_central', 'manual_review'),
    (v_other_location, v_company, 'REP-02', 'Ubicación no autorizada', 'sucursal', 'manual_review');
  insert into public.products(id, company_id, alpha_sku, internal_sku, name, unit, product_type, is_inventory_tracked)
  values (v_product, v_company, 'ALPHA-REPLENISH-1', 'REPLENISH-1', 'Producto reabastecible', 'PZA', 'P. Terminado', true);
  insert into public.inventory_balances(company_id, location_id, product_id, quantity_on_hand)
  values (v_company, v_location, v_product, 8);

  insert into public.user_roles(user_id, role_id, company_id)
  select v_manager, id, v_company from public.roles where code = 'almacen'
  union all
  select v_viewer, id, v_company from public.roles where code = 'sucursal';
  insert into public.user_location_access(user_id, location_id)
  values (v_manager, v_location), (v_viewer, v_location);
  insert into replenishment_context values (v_company, v_location, v_other_location, v_product, v_manager, v_viewer);
end;
$fixtures$;

grant select on replenishment_context to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', manager_id::text, true) from replenishment_context;

do $configure_and_suggest$
declare
  v_context replenishment_context%rowtype;
  v_result jsonb;
  v_retry jsonb;
  v_suggestions jsonb;
  v_item jsonb;
  v_balance numeric;
  v_ledger_count integer;
begin
  select * into v_context from replenishment_context;
  v_result := public.configure_inventory_replenishment_policies(
    v_context.company_id,
    v_context.location_id,
    jsonb_build_array(jsonb_build_object('product_code', 'ALPHA-REPLENISH-1', 'minimum_quantity', 10, 'maximum_quantity', 25)),
    '15160000-0000-4000-8000-000000000010'
  );
  v_retry := public.configure_inventory_replenishment_policies(
    v_context.company_id,
    v_context.location_id,
    jsonb_build_array(jsonb_build_object('product_code', 'ALPHA-REPLENISH-1', 'minimum_quantity', 10, 'maximum_quantity', 25)),
    '15160000-0000-4000-8000-000000000010'
  );
  if (v_result ->> 'line_count')::integer <> 1 or coalesce((v_result ->> 'idempotent')::boolean, true)
    or not coalesce((v_retry ->> 'idempotent')::boolean, false) then
    raise exception 'La configuración no fue idempotente: %, %', v_result, v_retry;
  end if;

  v_suggestions := public.list_inventory_replenishment_suggestions(v_context.company_id, v_context.location_id, null, true, 1, 50);
  v_item := v_suggestions -> 'items' -> 0;
  if (v_suggestions ->> 'total')::integer <> 1
    or (v_item ->> 'quantity_on_hand')::numeric <> 8
    or (v_item ->> 'minimum_quantity')::numeric <> 10
    or (v_item ->> 'maximum_quantity')::numeric <> 25
    or (v_item ->> 'suggested_quantity')::numeric <> 17 then
    raise exception 'La sugerencia no usa el saldo vigente: %', v_suggestions;
  end if;
  select quantity_on_hand into v_balance from public.inventory_balances
  where location_id = v_context.location_id and product_id = v_context.product_id;
  select count(*) into v_ledger_count from public.inventory_ledger
  where company_id = v_context.company_id and product_id = v_context.product_id;
  if v_balance <> 8 or v_ledger_count <> 0 then
    raise exception 'Configurar políticas no debe mover inventario ni generar ledger: saldo %, ledger %.', v_balance, v_ledger_count;
  end if;
end;
$configure_and_suggest$;

do $canonical_bulk_builder$
declare
  v_context replenishment_context%rowtype;
  v_search jsonb;
  v_result jsonb;
  v_retry jsonb;
  v_policy public.inventory_replenishment_policies%rowtype;
  v_audit jsonb;
begin
  select * into v_context from replenishment_context;
  v_search := public.search_inventory_replenishment_products(
    v_context.company_id, v_context.location_id, 'REPLENISH-1', 1, 50
  );
  if (v_search ->> 'total')::integer <> 1
    or v_search -> 'items' -> 0 ->> 'product_id' <> v_context.product_id::text
    or v_search -> 'items' -> 0 ->> 'product_code' <> 'REPLENISH-1'
    or (v_search -> 'items' -> 0 ->> 'quantity_on_hand')::numeric <> 8 then
    raise exception 'El selector canónico no devolvió producto, código y saldo esperados: %', v_search;
  end if;

  v_result := public.configure_inventory_replenishment_policy_items(
    v_context.company_id,
    v_context.location_id,
    jsonb_build_array(jsonb_build_object(
      'product_id', v_context.product_id,
      'minimum_quantity', 11,
      'maximum_quantity', 30
    )),
    '15160000-0000-4000-8000-000000000013'
  );
  v_retry := public.configure_inventory_replenishment_policy_items(
    v_context.company_id,
    v_context.location_id,
    jsonb_build_array(jsonb_build_object(
      'product_id', v_context.product_id,
      'minimum_quantity', 11,
      'maximum_quantity', 30
    )),
    '15160000-0000-4000-8000-000000000013'
  );
  if coalesce((v_result ->> 'idempotent')::boolean, true)
    or not coalesce((v_retry ->> 'idempotent')::boolean, false) then
    raise exception 'El constructor canónico no fue idempotente: %, %', v_result, v_retry;
  end if;

  select * into v_policy
  from public.inventory_replenishment_policies
  where location_id = v_context.location_id and product_id = v_context.product_id;
  if v_policy.minimum_quantity <> 11 or v_policy.maximum_quantity <> 30 then
    raise exception 'El constructor canónico no actualizó la política: %', to_jsonb(v_policy);
  end if;

  select metadata into v_audit
  from public.audit_log
  where entity_id = (v_result ->> 'batch_id')::uuid;
  if v_audit -> 'changes' -> 0 ->> 'product_id' <> v_context.product_id::text
    or (v_audit -> 'changes' -> 0 ->> 'previous_minimum_quantity')::numeric <> 10
    or (v_audit -> 'changes' -> 0 ->> 'minimum_quantity')::numeric <> 11 then
    raise exception 'La auditoría canónica no conservó antes y después: %', v_audit;
  end if;
end;
$canonical_bulk_builder$;

reset role;
update public.inventory_balances
set quantity_on_hand = 12, updated_at = now()
where location_id = '15160000-0000-4000-8000-000000000002'
  and product_id = '15160000-0000-4000-8000-000000000004';

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', manager_id::text, true) from replenishment_context;

do $live_balance_and_invalid_policy$
declare
  v_context replenishment_context%rowtype;
  v_below jsonb;
  v_all jsonb;
  v_item jsonb;
  v_blocked boolean := false;
begin
  select * into v_context from replenishment_context;
  v_below := public.list_inventory_replenishment_suggestions(v_context.company_id, v_context.location_id, null, true, 1, 50);
  v_all := public.list_inventory_replenishment_suggestions(v_context.company_id, v_context.location_id, null, false, 1, 50);
  v_item := v_all -> 'items' -> 0;
  if (v_below ->> 'total')::integer <> 0
    or (v_all ->> 'total')::integer <> 1
    or coalesce((v_item ->> 'is_below_minimum')::boolean, true)
    or (v_item ->> 'suggested_quantity')::numeric <> 0 then
    raise exception 'La sugerencia no se recalculó sobre el saldo actual: %, %', v_below, v_all;
  end if;
  begin
    perform public.configure_inventory_replenishment_policies(
      v_context.company_id,
      v_context.location_id,
      jsonb_build_array(jsonb_build_object('product_code', 'ALPHA-REPLENISH-1', 'minimum_quantity', 20, 'maximum_quantity', 10)),
      '15160000-0000-4000-8000-000000000011'
    );
  exception when others then v_blocked := true;
  end;
  if not v_blocked then raise exception 'Se aceptó un máximo menor al mínimo.'; end if;
end;
$live_balance_and_invalid_policy$;

select set_config('request.jwt.claim.sub', viewer_id::text, true) from replenishment_context;

do $viewer_security$
declare
  v_context replenishment_context%rowtype;
  v_visible jsonb;
  v_blocked boolean := false;
begin
  select * into v_context from replenishment_context;
  v_visible := public.list_inventory_replenishment_suggestions(v_context.company_id, v_context.location_id, null, false, 1, 50);
  if (v_visible ->> 'total')::integer <> 1 then
    raise exception 'El usuario con consulta de inventario no pudo ver sus sugerencias.';
  end if;
  begin
    perform public.configure_inventory_replenishment_policies(
      v_context.company_id,
      v_context.location_id,
      jsonb_build_array(jsonb_build_object('product_code', 'ALPHA-REPLENISH-1', 'minimum_quantity', 10, 'maximum_quantity', 30)),
      '15160000-0000-4000-8000-000000000012'
    );
  exception when others then v_blocked := true;
  end;
  if not v_blocked then raise exception 'Un usuario solo de consulta pudo configurar políticas.'; end if;
end;
$viewer_security$;

reset role;

do $audit_assertion$
declare
  v_count integer;
begin
  select count(*) into v_count
  from public.audit_log
  where company_id = '15160000-0000-4000-8000-000000000001'
    and action = 'inventory_replenishment.policies_configured';
  if v_count <> 2 then
    raise exception 'Las configuraciones no quedaron auditadas exactamente una vez cada una: %.', v_count;
  end if;
end;
$audit_assertion$;

rollback;
