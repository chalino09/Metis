begin;

do $test$
declare
  v_actor uuid;
  v_company uuid:='32000000-0000-4000-8000-000000000001';
  v_other uuid:='32000000-0000-4000-8000-000000000002';
  v_batch uuid;
  v_existing uuid;
  v_exception uuid;
  v_result jsonb;
  v_forbidden boolean:=false;
begin
  if to_regprocedure('public.promote_alpha_suppliers(uuid)') is null
    or to_regprocedure('public.search_suppliers(uuid,text,integer,integer,boolean,text)') is null
    or to_regprocedure('public.save_supplier(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,boolean,timestamptz)') is null then
    raise exception 'Faltan RPC del Módulo 3A.';
  end if;
  select ur.user_id into v_actor from public.user_roles ur join public.roles r on r.id=ur.role_id where r.code='super_admin' limit 1;
  if v_actor is null then raise exception 'La prueba requiere Super Admin.'; end if;
  insert into public.companies(id,legal_name,display_name) values(v_company,'Proveedores 3A','Proveedores 3A'),(v_other,'Otra empresa 3A','Otra empresa 3A');
  insert into public.user_roles(user_id,role_id,company_id) select v_actor,id,v_company from public.roles where code='super_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_actor::text,true);

  begin
    perform public.save_supplier(v_company,null,'Proveedor incompleto',null,null,null,null,null,'MX',null,null,null,null,null,null,null,null,null,null,true,null);
  exception when others then
    v_forbidden:=position('obligatorio' in sqlerrm)>0;
  end;
  if not v_forbidden then raise exception 'Se permitió activar un proveedor sin datos fiscales mínimos.'; end if;
  v_forbidden:=false;

  v_result:=public.save_supplier(v_company,null,'Borrador de proveedor',null,'physical',null,null,null,'MX',null,null,null,null,null,null,null,null,null,null,false,null);
  if (v_result->>'is_active')::boolean then raise exception 'El borrador no se guardó como inactivo.'; end if;

  v_result:=public.save_supplier(v_company,null,'Proveedor existente','Proveedor existente','moral','AAA010101AAA',null,'50000','MX',null,'proveedor@example.com','7222787751',null,null,null,null,null,null,null,true,null);
  v_existing:=(v_result->>'id')::uuid;
  if v_existing is null then raise exception 'No se creó el proveedor manual.'; end if;
  if v_result->>'code' not like 'SUP-%' or v_result->>'phone_e164'<>'+527222787751' then raise exception 'Código o teléfono canónico incorrecto: %',v_result; end if;

  insert into public.alpha_purchasing_import_batches(company_id,cutoff_date,content_sha256,status,records_received,imported_by,summary,completed_at)
  values(v_company,'2026-07-08','supplier-3a-test','staged',5,v_actor,'{"suppliers":5,"purchase_orders":84,"purchase_order_lines":731,"payable_documents":62,"supplier_payments":2220,"error_count":0,"warning_count":336}',now()) returning id into v_batch;
  insert into public.alpha_purchasing_import_suppliers(batch_id,external_code,display_name,tax_id,source_row_number,source_row_hash) values
    (v_batch,'A-1','Proveedor seguro uno','BBB010101BBB',1,'3a-1'),
    (v_batch,'A-2','Proveedor seguro dos','XAXX010101000',2,'3a-2'),
    (v_batch,'A-3','Nombre distinto','AAA010101AAA',3,'3a-3'),
    (v_batch,'A-4','Proveedor existente',null,4,'3a-4'),
    (v_batch,'MAN-1','Código distinto',null,5,'3a-5');

  v_result:=public.promote_alpha_suppliers(v_batch);
  if v_result->>'status'<>'completed_with_exceptions'
    or (v_result#>>'{summary,promoted}')::int<>3
    or (v_result#>>'{summary,pending_exceptions}')::int<>2 then raise exception 'La promoción masiva no separó altas y conflictos: %',v_result; end if;
  if (select count(*) from public.suppliers where company_id=v_company)<>5 then raise exception 'Se crearon proveedores fuera de los casos seguros.'; end if;
  if exists(select 1 from public.suppliers where company_id=v_company and code in('A-1','A-2','MAN-1')) then raise exception 'La clave fuente se filtró al código canónico.'; end if;
  if (select count(*) from public.alpha_purchasing_import_orders where batch_id=v_batch)<>0
    or (select count(*) from public.alpha_purchasing_import_payable_documents where batch_id=v_batch)<>0
    or (select count(*) from public.alpha_purchasing_import_payment_evidence where batch_id=v_batch)<>0 then raise exception '3A creó operaciones de etapas posteriores.'; end if;

  v_result:=public.promote_alpha_suppliers(v_batch);
  if v_result->>'status'<>'already_promoted' or (select count(*) from public.suppliers where company_id=v_company)<>5 then raise exception 'El reintento no fue idempotente.'; end if;

  select id into v_exception from public.supplier_import_exceptions where batch_id=v_batch and 'tax_id'=any(conflict_kinds) limit 1;
  v_result:=public.resolve_supplier_import_exception(v_exception,'link_existing',v_existing,'RFC confirmado contra expediente fiscal.');
  if v_result->>'status'<>'resolved' or (select promoted_supplier_id from public.alpha_purchasing_import_suppliers where id=(select staged_supplier_id from public.supplier_import_exceptions where id=v_exception))<>v_existing then raise exception 'No se vinculó la excepción.'; end if;
  v_result:=public.resolve_supplier_import_exception(v_exception,'link_existing',v_existing,'RFC confirmado contra expediente fiscal.');
  if v_result->>'status'<>'already_resolved' then raise exception 'La resolución no fue idempotente.'; end if;

  v_result:=public.search_suppliers(v_company,'proveedor',1,2,null,null);
  if (v_result#>>'{pagination,total}')::int<>4 or jsonb_array_length(v_result->'items')<>2 then raise exception 'La búsqueda/paginación server-side es incorrecta: %',v_result; end if;
  if not exists(select 1 from public.audit_log where company_id=v_company and action='alpha_suppliers.promoted' and entity_id=v_batch) then raise exception 'Falta auditoría de promoción.'; end if;

  perform set_config('request.jwt.claim.sub','32000000-0000-4000-8000-000000000099',true);
  begin perform public.search_suppliers(v_company,null,1,50,null,null); exception when others then v_forbidden:=position('No autorizado' in sqlerrm)>0; end;
  if not v_forbidden then raise exception 'Un usuario ajeno consultó proveedores.'; end if;
  v_forbidden:=false;
  begin perform public.promote_alpha_suppliers(v_batch); exception when others then v_forbidden:=position('No autorizado' in sqlerrm)>0; end;
  if not v_forbidden then raise exception 'Un usuario ajeno promovió proveedores.'; end if;
  if exists(select 1 from public.suppliers where company_id=v_other) then raise exception 'Falló el aislamiento entre empresas.'; end if;
  raise notice 'Módulo 3A: catálogo, promoción, conflictos, auditoría, permisos e aislamiento aprobados.';
end;
$test$;

rollback;
