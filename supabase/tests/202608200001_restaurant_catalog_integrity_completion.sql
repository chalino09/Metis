begin;

do $$
declare
  c uuid := '82000001-0000-4000-8000-000000000001';
  u uuid := '82000001-0000-4000-8000-000000000002';
  ingredient uuid;
  bottle uuid;
  dish uuid := '82000001-0000-4000-8000-000000000003';
  recipe uuid := '82000001-0000-4000-8000-000000000004';
  version uuid := '82000001-0000-4000-8000-000000000005';
  saved jsonb;
  context jsonb;
  issues jsonb;
begin
  insert into public.companies(id, legal_name, display_name, product_experience_code)
  values(c, 'Integridad Restaurante', 'Integridad Restaurante', 'restaurant');
  insert into auth.users(id, aud, role, email, encrypted_password)
  values(u, 'authenticated', 'authenticated', 'restaurant-integrity@example.invalid', '');
  insert into public.user_roles(user_id, role_id, company_id)
  select u, id, c from public.roles where code = 'direccion_admin';
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', u::text, true);

  saved := public.save_restaurant_catalog_item(
    c, null, 'ING-KG', 'Insumo kilogramo', null, 'g', 'Prueba', 'ingredient', false, true, null,
    'KG', 1000, false, 'Prueba de conversión', null, '82000001-0000-4000-8000-000000000006'
  );
  ingredient := (saved ->> 'id')::uuid;
  if (public.get_product_purchase_unit(c, ingredient) ->> 'base_units_per_purchase_unit')::numeric <> 1000 then
    raise exception 'No se guardó 1 kg = 1,000 g.';
  end if;
  if public.restaurant_purchase_configuration_error('KG', 'g', 1) is null then
    raise exception 'Aceptó una conversión métrica incorrecta.';
  end if;

  saved := public.save_restaurant_catalog_item(
    c, null, 'ING-BOT', 'Insumo botella', null, 'ml', 'Prueba', 'ingredient', false, true, null,
    'BOTELLA', 750, false, 'Prueba de contenido explícito', null, '82000001-0000-4000-8000-000000000007'
  );
  bottle := (saved ->> 'id')::uuid;
  if (public.get_product_purchase_unit(c, bottle) ->> 'presentation_content_confirmed_at') is null then
    raise exception 'No quedó auditada la confirmación de contenido de la botella.';
  end if;
  update public.product_purchase_units
  set base_units_per_purchase_unit = 1, presentation_content_confirmed_at = null
  where product_id = bottle;
  issues := public.list_restaurant_catalog_integrity_issues(c, 1, 50);
  if not exists(select 1 from jsonb_array_elements(issues -> 'items') item where item ->> 'id' = bottle::text) then
    raise exception 'La revisión no detectó la botella heredada sin contenido confirmado: %', issues;
  end if;

  insert into public.products(id, company_id, internal_sku, name, unit, is_inventory_tracked, is_active)
  values(dish, c, 'DISH-CTX', 'Platillo de contexto', 'piece', false, true);
  insert into public.product_culinary_roles(company_id, product_id, role, assigned_by, reason)
  values(c, dish, 'dish', u, 'Prueba de receta activa');
  insert into public.culinary_recipes(id, company_id, product_id, recipe_kind)
  values(recipe, c, dish, 'dish');
  insert into public.culinary_recipe_versions(id, recipe_id, version_number, status, yield_quantity, yield_unit_code, portion_count, waste_percent, valid_from, activated_at, activated_by)
  values(version, recipe, 1, 'active', 1, 'piece', 1, 0, now(), now(), u);
  insert into public.culinary_recipe_components(recipe_version_id, component_product_id, entered_quantity, entered_unit_code, normalized_quantity, base_unit_code)
  values(version, ingredient, 25, 'g', 25, 'g');

  context := public.get_restaurant_ingredient_archive_context(c, ingredient);
  if jsonb_array_length(context -> 'active_recipes') <> 1 then
    raise exception 'El archivo no expuso la receta activa que bloquea el insumo: %', context;
  end if;
  context := public.get_culinary_recipe_context(c, dish);
  if jsonb_array_length(context -> 'active' -> 'components') <> 1 then
    raise exception 'La receta activa no expuso sus componentes para corregirla: %', context;
  end if;
end $$;

rollback;
