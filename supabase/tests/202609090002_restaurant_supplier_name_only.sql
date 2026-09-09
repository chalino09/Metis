begin;
do $test$
declare
  v_actor uuid; v_company uuid:=gen_random_uuid(); v_core uuid:=gen_random_uuid();
  v_supplier jsonb; v_id uuid; v_rejected boolean; v_field text;
begin
  select ur.user_id into v_actor from public.user_roles ur join public.roles r on r.id=ur.role_id where r.code='super_admin' limit 1;
  if v_actor is null then raise exception 'La prueba requiere Super Admin.';end if;
  insert into public.companies(id,legal_name,display_name,product_experience_code) values
    (v_company,'Prueba alta restaurante','Prueba alta restaurante','restaurant'),
    (v_core,'Prueba alta core','Prueba alta core','core');
  insert into public.user_roles(user_id,role_id,company_id)
    select v_actor,id,c from public.roles cross join unnest(array[v_company,v_core]) c where code='super_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_actor::text,true);
  v_supplier:=public.save_supplier_v2(p_company_id=>v_company,p_supplier_id=>null,p_display_name=>'Solo nombre',p_country_code=>'');
  v_id:=(v_supplier->>'id')::uuid;
  if not (v_supplier->>'is_active')::boolean or v_supplier->>'country_code'<>'MX' then raise exception 'No se guardó activo con solo nombre.';end if;
  foreach v_field in array array['legal_entity_type','legal_name','tax_id','tax_regime','fiscal_postal_code','email','phone','contact_name','address_line','payable_term_days'] loop
    if v_supplier->>v_field is not null then raise exception 'Se inventó un valor para %.',v_field;end if;
  end loop;
  if not exists(select 1 from public.audit_log where entity_id=v_id and action='supplier.created') then raise exception 'Falta auditoría de alta.';end if;
  v_supplier:=public.save_supplier_v2(p_company_id=>v_company,p_supplier_id=>v_id,p_display_name=>'Solo nombre editado',p_legal_entity_type=>'moral',p_expected_updated_at=>(v_supplier->>'updated_at')::timestamptz);
  if v_supplier->>'legal_name' is not null or v_supplier->>'display_name'<>'Solo nombre editado' then raise exception 'No se permite moral sin razón social.';end if;
  if not exists(select 1 from public.audit_log where entity_id=v_id and action='supplier.updated') then raise exception 'Falta auditoría de edición.';end if;
  v_supplier:=public.save_supplier_v3(p_company_id=>v_company,p_supplier_id=>null,p_display_name=>'Borrador solo nombre',p_is_active=>false);
  if (v_supplier->>'is_active')::boolean then raise exception 'El borrador se activó.';end if;
  v_rejected:=false;
  begin perform public.save_supplier_v2(p_company_id=>v_company,p_supplier_id=>null,p_display_name=>'   ');
  exception when others then v_rejected:=position('nombre comercial' in sqlerrm)>0;end;
  if not v_rejected then raise exception 'Se permitió nombre vacío.';end if;
  v_rejected:=false;
  begin perform public.save_supplier_v2(p_company_id=>v_core,p_supplier_id=>null,p_display_name=>'Core incompleto');
  exception when others then v_rejected:=position('tipo de persona' in sqlerrm)>0;end;
  if not v_rejected then raise exception 'Se relajó el alta en Core.';end if;
  v_rejected:=false;
  begin perform public.save_supplier_v2(p_company_id=>v_core,p_supplier_id=>null,p_display_name=>'Core sin contacto',p_legal_entity_type=>'physical',p_fiscal_postal_code=>'50000');
  exception when others then v_rejected:=position('correo electrónico o teléfono' in sqlerrm)>0;end;
  if not v_rejected then raise exception 'Se relajó el contacto obligatorio en Core.';end if;
  v_rejected:=false;
  begin perform public.save_supplier_v2(p_company_id=>v_company,p_supplier_id=>null,p_display_name=>'RFC inválido',p_tax_id=>'INVALIDO');
  exception when others then v_rejected:=position('RFC' in sqlerrm)>0;end;
  if not v_rejected then raise exception 'Se permitió RFC inválido.';end if;
  v_rejected:=false;
  begin perform public.save_supplier_v2(p_company_id=>v_company,p_supplier_id=>null,p_display_name=>'CP inválido',p_fiscal_postal_code=>'123');
  exception when others then v_rejected:=position('código postal' in sqlerrm)>0;end;
  if not v_rejected then raise exception 'Se permitió CP inválido.';end if;
  v_rejected:=false;
  begin perform public.save_supplier_v2(p_company_id=>v_company,p_supplier_id=>null,p_display_name=>'Correo inválido',p_email=>'invalido');
  exception when others then v_rejected:=position('correo electrónico' in sqlerrm)>0;end;
  if not v_rejected then raise exception 'Se permitió correo inválido.';end if;
  v_rejected:=false;
  begin perform public.save_supplier_v2(p_company_id=>v_company,p_supplier_id=>null,p_display_name=>'Teléfono inválido',p_phone=>'123');
  exception when others then v_rejected:=position('teléfono' in sqlerrm)>0;end;
  if not v_rejected then raise exception 'Se permitió teléfono inválido.';end if;
  v_rejected:=false;
  begin perform public.save_supplier_v2(p_company_id=>v_company,p_supplier_id=>null,p_display_name=>'Solo nombre editado');
  exception when others then v_rejected:=position('proveedor candidato' in sqlerrm)>0;end;
  if not v_rejected then raise exception 'Se permitió duplicar identidad.';end if;
  perform set_config('request.jwt.claim.sub','',true);
  v_rejected:=false;
  begin perform public.save_supplier_v2(p_company_id=>v_company,p_supplier_id=>null,p_display_name=>'Sin autorización');
  exception when others then v_rejected:=position('No autorizado' in sqlerrm)>0;end;
  if not v_rejected then raise exception 'Se permitió alta sin autorización.';end if;
  raise notice 'PASS: alta activa y borrador con solo nombre; edición; auditoría; rechazo de nombre vacío, duplicados, formatos inválidos y falta de autorización; Core conserva requisitos.';
end $test$;
rollback;
