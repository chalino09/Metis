begin;
do $r_op_product$
declare
  v_company_id uuid:='d5000000-0000-4000-8000-000000000001';
  admin_user uuid:='d5000000-0000-4000-8000-000000000002';
  operator_user uuid:='d5000000-0000-4000-8000-000000000003';
  product_id uuid;
  imported_id uuid;
  result jsonb;
  replay jsonb;
  stamp timestamptz;
  blocked boolean:=false;
begin
  insert into public.companies(id,legal_name,display_name)
  values(v_company_id,'Empresa R-OP','Empresa R-OP');
  insert into auth.users(id,aud,role,email,encrypted_password) values
    (admin_user,'authenticated','authenticated','admin-r-op@example.com',''),
    (operator_user,'authenticated','authenticated','operator-r-op@example.com','');
  insert into public.user_roles(user_id,role_id,company_id)
  select admin_user,id,v_company_id from public.roles where code='direccion_admin'
  union all
  select operator_user,id,v_company_id from public.roles where code='sucursal';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',admin_user::text,true);

  result:=public.save_product(
    v_company_id,null,' prod-001 ','Producto manual',' 750100000001 ',
    'pieza','General',true,false,true,'Alta inicial',null,
    'd5000000-0000-4000-8000-000000000010'
  );
  product_id:=(result->>'id')::uuid;
  if result->>'internal_sku'<>'PROD-001' or result->>'alpha_sku' is not null
    or coalesce((result->>'idempotent')::boolean,true) then
    raise exception 'La creación manual no separó la identidad canónica: %',result;
  end if;
  if not exists(select 1 from public.units_of_measure unit_data
    where unit_data.company_id=v_company_id and unit_data.code='pieza') then
    raise exception 'La unidad canónica no se vinculó.';
  end if;

  replay:=public.save_product(
    v_company_id,null,'PROD-001','Producto manual','750100000001',
    'pieza','General',true,false,true,'Alta inicial',null,
    'd5000000-0000-4000-8000-000000000010'
  );
  if not coalesce((replay->>'idempotent')::boolean,false)
    or (replay->>'id')::uuid<>product_id then
    raise exception 'La creación idempotente generó otro producto.';
  end if;

  select updated_at into stamp from public.products where id=product_id;
  result:=public.save_product(
    v_company_id,product_id,'PROD-001','Producto manual corregido',null,
    'pieza','General',true,false,false,'Desactivación administrativa',stamp,
    'd5000000-0000-4000-8000-000000000011'
  );
  if (result->>'is_active')::boolean or result->>'name'<>'Producto manual corregido' then
    raise exception 'La edición o desactivación canónica falló: %',result;
  end if;

  begin
    perform public.save_product(
      v_company_id,product_id,'PROD-001','Edición atrasada',null,
      'pieza','General',true,false,true,'Prueba de concurrencia',stamp,
      'd5000000-0000-4000-8000-000000000012'
    );
  exception when others then blocked:=position('cambió mientras' in lower(sqlerrm))>0;end;
  if not blocked then raise exception 'Una edición atrasada sobrescribió el producto.';end if;
  blocked:=false;

  -- Compatibilidad de frontera: un importador anterior puede seguir enviando
  -- alpha_sku, pero el registro obtiene siempre identidad canónica.
  insert into public.products(company_id,alpha_sku,name,unit,product_type)
  values(v_company_id,'ALPHA-77','Producto importado','pieza','P. Terminado')
  returning id into imported_id;
  if (select internal_sku from public.products where id=imported_id)<>'ALPHA-77' then
    raise exception 'La frontera de importación no generó el código canónico.';
  end if;

  begin
    perform public.save_product(
      v_company_id,null,'PROD-001','Código duplicado',null,null,null,
      false,false,true,'Prueba duplicado',null,
      'd5000000-0000-4000-8000-000000000013'
    );
  exception when others then blocked:=position('código canónico' in lower(sqlerrm))>0;end;
  if not blocked then raise exception 'Se admitió un código canónico duplicado.';end if;
  blocked:=false;

  perform set_config('request.jwt.claim.sub',operator_user::text,true);
  begin
    perform public.save_product(
      v_company_id,null,'PROD-002','Producto no autorizado',null,null,null,
      false,false,true,'Intento no autorizado',null,
      'd5000000-0000-4000-8000-000000000014'
    );
  exception when others then blocked:=position('no autorizado' in lower(sqlerrm))>0;end;
  if not blocked then raise exception 'Un operador sin permiso administró productos.';end if;

  if (select count(*) from public.audit_log audit
    where audit.company_id=v_company_id and audit.action='product.admin_saved')<>2 then
    raise exception 'La auditoría administrativa no conserva exactamente alta y edición.';
  end if;
  if not exists(select 1 from public.audit_log audit
    where audit.company_id=v_company_id and audit.action='product.admin_saved'
      and audit.metadata->>'origin'='manual' and audit.metadata->>'reason'='Alta inicial') then
    raise exception 'La auditoría no distingue origen y motivo.';
  end if;
  raise notice 'R-OP producto: identidad canónica, compatibilidad de importación, idempotencia, concurrencia, permisos y auditoría aprobados.';
end;$r_op_product$;
rollback;
