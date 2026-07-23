-- Alpha RFC identity repair regression. Run after migration 202607130023.
begin;

do $fixture$
declare
  v_actor uuid;
  v_company uuid:='23000000-0000-4000-8000-000000000023';
  v_batch uuid:='23000000-0000-4000-8000-000000000024';
  v_generic_winner uuid:='23000000-0000-4000-8000-000000000025';
  v_real_winner uuid:='23000000-0000-4000-8000-000000000026';
  v_preview jsonb;
  v_result jsonb;
begin
  if to_regprocedure('public.preview_alpha_customer_identity_repair(uuid)') is null
    or to_regprocedure('public.apply_alpha_customer_identity_repair(uuid)') is null then
    raise exception 'Faltan las RPC de reparación de identidad Alpha.';
  end if;

  select ur.user_id into v_actor
  from public.user_roles ur
  join public.roles r on r.id=ur.role_id
  where r.code='super_admin'
  limit 1;
  if v_actor is null then raise exception 'La prueba requiere un Super Admin existente.'; end if;

  insert into public.companies(id,legal_name,display_name)
  values(v_company,'Empresa prueba identidad','Empresa prueba identidad');
  insert into public.user_roles(user_id,role_id,company_id)
  select v_actor,id,v_company from public.roles where code='super_admin'
  on conflict do nothing;
  insert into public.alpha_customer_migration_batches(id,company_id,cutoff_date,content_sha256,status,imported_by,summary)
  values(v_batch,v_company,'2026-07-08','identity-repair-fixture','completed_with_discrepancies',v_actor,'{"blocked_customers":3}'::jsonb);

  insert into public.customers(id,company_id,code,display_name,tax_id,credit_enabled,credit_limit,credit_term_days,created_by,alpha_external_code,alpha_source_row_hash,migration_status)
  values
    (v_generic_winner,v_company,'G-001','Cliente Genérico Uno','XAXX010101000',false,0,0,v_actor,'G-001','hash-g-001','promoted'),
    (v_real_winner,v_company,'R-001','Empresa Fiscal SA','AAA010101AAA',false,0,0,v_actor,'R-001','hash-r-001','promoted');

  insert into public.alpha_customer_migration_customers(id,batch_id,external_code,display_name,tax_id,source_row_hash,status,promoted_customer_id)
  values
    ('23000000-0000-4000-8000-000000000031',v_batch,'G-001','Cliente Genérico Uno','XAXX010101000','hash-g-001','promoted',v_generic_winner),
    ('23000000-0000-4000-8000-000000000032',v_batch,'G-002','Cliente Genérico Dos','XAXX010101000','hash-g-002','discrepancy',null),
    ('23000000-0000-4000-8000-000000000033',v_batch,'R-001','Empresa Fiscal SA','AAA010101AAA','hash-r-001','promoted',v_real_winner),
    ('23000000-0000-4000-8000-000000000034',v_batch,'R-002','Empresa Fiscal, S.A.','AAA010101AAA','hash-r-002','discrepancy',null),
    ('23000000-0000-4000-8000-000000000035',v_batch,'R-003','Otra razón social','AAA010101AAA','hash-r-003','discrepancy',null);
  insert into public.alpha_customer_migration_differences(batch_id,customer_external_code,severity,difference_code,message)
  values
    (v_batch,'G-002','error','PROMOTION_FAILED','duplicate key value violates unique constraint "customers_company_tax_id_key"'),
    (v_batch,'R-002','error','PROMOTION_FAILED','duplicate key value violates unique constraint "customers_company_tax_id_key"'),
    (v_batch,'R-003','error','PROMOTION_FAILED','duplicate key value violates unique constraint "customers_company_tax_id_key"');

  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_actor::text,true);
  v_preview:=public.preview_alpha_customer_identity_repair(v_batch);
  if (v_preview->>'canonicalize_existing_generic_tax_ids')::int<>1
    or (v_preview->>'promote_without_tax_id')::int<>1
    or (v_preview->>'link_to_promoted_customer')::int<>1
    or (v_preview->>'ambiguous_customers')::int<>1 then
    raise exception 'El preview de reparación no clasificó correctamente los RFC.';
  end if;
  v_result:=public.apply_alpha_customer_identity_repair(v_batch);
  if v_result->>'status'<>'completed' or (v_result->>'promoted_customers')::int<>4 or (v_result->>'blocked_customers')::int<>1 then
    raise exception 'La aplicación de la reparación no produjo los conteos esperados.';
  end if;
  if exists(select 1 from public.customers where id=v_generic_winner and (tax_id is not null or credit_enabled or credit_limit<>0 or credit_term_days<>0)) then
    raise exception 'El RFC genérico ya promovido no se canonicó a NULL y contado.';
  end if;
  if not exists(select 1 from public.customers where company_id=v_company and code='G-002' and tax_id is null and not credit_enabled and credit_limit=0 and credit_term_days=0) then
    raise exception 'El cliente de RFC genérico bloqueado no se promovió de contado.';
  end if;
  if not exists(select 1 from public.alpha_customer_migration_customers where batch_id=v_batch and external_code='R-002' and status='promoted' and promoted_customer_id=v_real_winner) then
    raise exception 'El RFC real con identidad coincidente no se vinculó al cliente promovido.';
  end if;
  if not exists(select 1 from public.alpha_customer_migration_customers where batch_id=v_batch and external_code='R-003' and status='discrepancy') then
    raise exception 'La identidad ambigua no permaneció bloqueada.';
  end if;
  if (select count(*) from public.alpha_customer_migration_differences where batch_id=v_batch and severity='error')<>1 then
    raise exception 'Los errores recuperados debían conservarse como advertencias auditables.';
  end if;
end;
$fixture$;

rollback;
