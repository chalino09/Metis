begin;

do $test$
declare
  v_company uuid := '82080000-0000-4000-8000-000000000001';
  v_actor uuid := '82080000-0000-4000-8000-000000000002';
  v_assortment uuid := '82080000-0000-4000-8000-000000000003';
  v_first uuid := '82080000-0000-4000-8000-000000000004';
  v_second uuid := '82080000-0000-4000-8000-000000000005';
  v_result jsonb;
begin
  insert into public.companies(id, legal_name, display_name)
  values(v_company, 'Surtido filtrado prueba', 'Surtido filtrado prueba');
  insert into auth.users(id, aud, role, email, encrypted_password)
  values(v_actor, 'authenticated', 'authenticated', 'filtered-assortment@example.com', '');
  insert into public.user_roles(user_id, role_id, company_id)
  select v_actor, id, v_company from public.roles where code = 'super_admin';
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', v_actor::text, true);

  insert into public.sales_assortments(id, company_id, code, name, status)
  values(v_assortment, v_company, 'SUR-FILTRO', 'Surtido filtrado', 'draft');
  insert into public.products(id, company_id, alpha_sku, name)
  values
    (v_first, v_company, 'CAF-001', 'Café molido'),
    (v_second, v_company, 'TE-001', 'Té verde');

  v_result := public.set_sales_assortment_membership_by_filter(v_company, v_assortment, 'café', 'excluded', true, 'Alta de temporada');
  if (v_result->>'matched')::integer <> 1 or (v_result->>'updated')::integer <> 1 then
    raise exception 'El filtro no agregó exactamente un producto: %', v_result;
  end if;
  if not exists(select 1 from public.sales_assortment_items where assortment_id = v_assortment and product_id = v_first) then
    raise exception 'El producto filtrado no quedó en el surtido.';
  end if;
  if exists(select 1 from public.sales_assortment_items where assortment_id = v_assortment and product_id = v_second) then
    raise exception 'La operación alteró un producto fuera del filtro.';
  end if;

  v_result := public.set_sales_assortment_membership_by_filter(v_company, v_assortment, 'café', 'included', false, 'Fin de temporada');
  if (v_result->>'updated')::integer <> 1 then raise exception 'No retiró el resultado filtrado.'; end if;
  if not exists(
    select 1 from public.audit_log
    where company_id = v_company
      and entity_id = v_assortment
      and metadata->>'reason' = 'Fin de temporada'
      and metadata->>'matched' = '1'
  ) then raise exception 'Falta la auditoría del cambio masivo.'; end if;
end;
$test$;

rollback;
