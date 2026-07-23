begin;
do $r_op_tax$
declare
  v_company_id uuid:='d7000000-0000-4000-8000-000000000001';
  v_admin uuid:='d7000000-0000-4000-8000-000000000002';
  v_category jsonb; v_product jsonb; v_rate_count integer;
begin
  insert into public.companies(id,legal_name,display_name) values(v_company_id,'Fiscal R-OP','Fiscal R-OP');
  insert into auth.users(id,aud,role,email,encrypted_password) values(v_admin,'authenticated','authenticated','tax-r-op@example.com','');
  insert into public.user_roles(user_id,role_id,company_id) select v_admin,id,v_company_id from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_admin::text,true);

  v_category:=public.save_tax_category(v_company_id,'iva16','IVA 16%',0.16,'Alta fiscal','d7000000-0000-4000-8000-000000000010');
  if v_category->>'code'<>'IVA16' or (v_category->>'rate')::numeric<>0.16 then raise exception 'La categoría fiscal canónica no se creó: %',v_category; end if;
  v_product:=public.save_product(v_company_id,null,'FISC-001','Producto fiscal',null,'PZA',null,true,true,true,(v_category->>'id')::uuid,'Alta con impuesto',null,'d7000000-0000-4000-8000-000000000011');
  if (v_product->>'tax_category_id')::uuid<>(v_category->>'id')::uuid then raise exception 'El producto no usa la categoría fiscal canónica.'; end if;
  perform public.save_tax_category(v_company_id,'IVA16','IVA general',0.08,'Cambio de tasa','d7000000-0000-4000-8000-000000000012');
  select count(*) into v_rate_count from public.tax_rates where tax_category_id=(v_category->>'id')::uuid;
  if v_rate_count<>2 or not exists(select 1 from public.tax_rates where tax_category_id=(v_category->>'id')::uuid and rate=0.08 and valid_to is null) then raise exception 'El cambio de tasa no conservó su historial.'; end if;
  if not exists(select 1 from public.audit_log where company_id=v_company_id and action='tax_category.admin_saved') then raise exception 'Falta auditoría fiscal.'; end if;
  raise notice 'R-OP fiscal: categoría manual, tasa vigente versionada y producto canónico aprobados.';
end $r_op_tax$;
rollback;
