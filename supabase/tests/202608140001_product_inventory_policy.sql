begin;

do $test$
declare
  v_company uuid := '81400000-0000-4000-8000-000000000001';
  v_actor uuid := '81400000-0000-4000-8000-000000000002';
  v_unit uuid := '81400000-0000-4000-8000-000000000003';
  v_tax uuid := '81400000-0000-4000-8000-000000000004';
  v_list uuid := '81400000-0000-4000-8000-000000000005';
  v_unclassified uuid := '81400000-0000-4000-8000-000000000006';
  v_saved jsonb;
begin
  insert into public.companies(id, legal_name, display_name, default_price_policy)
  values(v_company, 'Política inventario prueba', 'Política inventario prueba', 'specific_list');
  insert into auth.users(id, aud, role, email, encrypted_password)
  values(v_actor, 'authenticated', 'authenticated', 'inventory-policy@example.com', '');
  insert into public.user_roles(user_id, role_id, company_id)
  select v_actor, id, v_company from public.roles where code = 'super_admin';
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', v_actor::text, true);

  insert into public.units_of_measure(id, company_id, code, name) values(v_unit, v_company, 'PZA', 'Pieza');
  insert into public.tax_categories(id, company_id, code, name) values(v_tax, v_company, 'IVA16', 'IVA 16%');
  insert into public.tax_rates(tax_category_id, jurisdiction_code, rate, valid_from, created_by)
  values(v_tax, 'MX', 0.16, now() - interval '1 day', v_actor);
  insert into public.price_lists(id, company_id, external_code, name, currency_code, is_active, status)
  values(v_list, v_company, 'LISTA-PRUEBA', 'Lista prueba', 'MXN', true, 'active');
  update public.companies set default_price_list_id = v_list where id = v_company;

  insert into public.products(
    id, company_id, internal_sku, alpha_sku, name, unit, inventory_policy,
    is_inventory_tracked, is_active, is_sellable, commercial_review_required,
    sales_unit_id, tax_category_id
  ) values(
    v_unclassified, v_company, 'AMB-001', null, 'Mercancía importada ambigua', 'PZA', 'unclassified',
    false, true, true, false, v_unit, v_tax
  );
  insert into public.product_prices(product_id, price_list_id, amount, currency_code, valid_from)
  values(v_unclassified, v_list, 100, 'MXN', now() - interval '1 day');

  if not (public.product_pos_readiness_detail(v_company, v_unclassified, v_list) -> 'blockers' @> '["inventory_setup_required"]'::jsonb) then
    raise exception 'La mercancía sin política resuelta quedó vendible en POS.';
  end if;

  update public.products set inventory_policy = 'tracked' where id = v_unclassified;
  if not exists(select 1 from public.products where id = v_unclassified and is_inventory_tracked and inventory_policy = 'tracked') then
    raise exception 'La mercancía no sincronizó su control de existencias.';
  end if;

  update public.products set inventory_policy = 'not_required' where id = v_unclassified;
  if exists(select 1 from public.products where id = v_unclassified and is_inventory_tracked) then
    raise exception 'El servicio conserva control de existencias.';
  end if;

  if public.alpha_product_inventory_policy('P. TERMINADO') <> 'tracked'
    or public.alpha_product_inventory_policy('SERVICIOS') <> 'not_required'
    or public.alpha_product_inventory_policy('1') <> 'unclassified' then
    raise exception 'La frontera Alpha clasificó valores ambiguos de forma insegura.';
  end if;

  v_saved := public.save_product(
    v_company, null, 'SERV-001', 'Servicio manual', null, 'SERV', null,
    'not_required', true, true, v_tax, 'Alta de servicio', null,
    '81400000-0000-4000-8000-000000000007'
  );
  if v_saved ->> 'inventory_policy' <> 'not_required' or coalesce((v_saved ->> 'is_inventory_tracked')::boolean, true) then
    raise exception 'El alta manual no guardó la política explícita de servicio.';
  end if;
end;
$test$;

rollback;
